package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/damonto/euicc-go/lpa"
	sgp22 "github.com/damonto/euicc-go/v2"
)

var cglaResponsePattern = regexp.MustCompile(`\+CGLA:\s*\d+\s*,\s*"?([0-9A-Fa-f]+)"?`)

// moduleLPAChannel 把 euicc-go 的 SmartCardChannel 接口桥接到模块本机 SMD AT 端口。
// AT 端口自身负责全局串行化；这里的锁只保护单个逻辑通道的生命周期。
type moduleLPAChannel struct {
	at      *atPort
	channel byte
	mu      sync.Mutex
}

func (c *moduleLPAChannel) Connect() error { return nil }

func (c *moduleLPAChannel) Disconnect() error { return nil }

func (c *moduleLPAChannel) OpenLogicalChannel(aid []byte) (byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	aidHex := strings.ToUpper(hex.EncodeToString(aid))
	result, err := c.at.command(fmt.Sprintf(`AT+CCHO="%s"`, aidHex), 8*time.Second)
	if err != nil {
		return 0, fmt.Errorf("打开 eUICC logical channel 失败 (AID=%s): %w", aidHex, err)
	}
	channel := parseLogicalChannel(result)
	if channel <= 0 || channel > 19 {
		return 0, fmt.Errorf("解析 CCHO 响应失败: %s", result)
	}
	c.channel = byte(channel)
	return c.channel, nil
}

func (c *moduleLPAChannel) Transmit(command []byte) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.channel == 0 {
		return nil, errors.New("eUICC logical channel 尚未打开")
	}
	commandHex := strings.ToUpper(hex.EncodeToString(command))
	result, err := c.at.command(
		fmt.Sprintf(`AT+CGLA=%d,%d,"%s"`, c.channel, len(commandHex), commandHex),
		20*time.Second,
	)
	if err != nil {
		return nil, fmt.Errorf("APDU 透传失败: %w", err)
	}
	match := cglaResponsePattern.FindStringSubmatch(result)
	if len(match) != 2 {
		return nil, fmt.Errorf("解析 CGLA 响应失败: %s", result)
	}
	response, err := hex.DecodeString(match[1])
	if err != nil {
		return nil, fmt.Errorf("解析 APDU 响应 hex 失败: %w", err)
	}
	return response, nil
}

func (c *moduleLPAChannel) CloseLogicalChannel(channel byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if channel == 0 {
		return nil
	}
	_, err := c.at.command(fmt.Sprintf("AT+CCHC=%d", channel), 8*time.Second)
	if c.channel == channel {
		c.channel = 0
	}
	if err != nil {
		return fmt.Errorf("关闭 eUICC logical channel %d 失败: %w", channel, err)
	}
	return nil
}

type moduleEUICCInfo struct {
	AID       string `json:"aid"`
	EID       string `json:"eid"`
	SpecGuess string `json:"spec_guess,omitempty"`
	InfoError string `json:"info_error,omitempty"`
}

type moduleESIMChipInfo struct {
	EIDs []moduleEUICCInfo `json:"eids"`
}

type moduleESIMProfile struct {
	ICCID               string `json:"iccid"`
	Name                string `json:"name"`
	ServiceProviderName string `json:"service_provider_name"`
	State               int    `json:"state"`
	StateText           string `json:"state_text"`
	ClassText           string `json:"class_text,omitempty"`
}

type moduleESIMProfileGroup struct {
	EID      string              `json:"eid"`
	AIDHex   string              `json:"aid_hex"`
	Profiles []moduleESIMProfile `json:"profiles"`
}

type moduleESIMOverview struct {
	CardType string                   `json:"card_type"`
	Message  string                   `json:"message,omitempty"`
	ChipInfo moduleESIMChipInfo       `json:"chip_info"`
	Profiles []moduleESIMProfileGroup `json:"profiles"`
}

func (a *agent) newLPAClient(aidHex string) (*lpa.Client, error) {
	aid, err := hex.DecodeString(aidHex)
	if err != nil {
		return nil, fmt.Errorf("AID hex 无效 %q: %w", aidHex, err)
	}
	return lpa.New(&lpa.Options{
		Channel: &moduleLPAChannel{at: a.at},
		AID:     aid,
		MSS:     254,
	})
}

// safeListProfiles 隔离第三方 BER-TLV 解码器对非标准 Profile 数据的 panic。
func safeListProfiles(client *lpa.Client, filter any) (profiles []*sgp22.ProfileInfo, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("解析 Profile 数据失败: %v", recovered)
		}
	}()
	return client.ListProfile(filter, nil)
}

func profilePayload(profile *sgp22.ProfileInfo) moduleESIMProfile {
	name := strings.TrimSpace(profile.ProfileNickname)
	if name == "" {
		name = strings.TrimSpace(profile.ProfileName)
	}
	stateText := "已禁用"
	if profile.ProfileState == sgp22.ProfileEnabled {
		stateText = "已启用"
	}
	return moduleESIMProfile{
		ICCID:               profile.ICCID.String(),
		Name:                name,
		ServiceProviderName: profile.ServiceProviderName,
		State:               int(profile.ProfileState),
		StateText:           stateText,
		ClassText:           profile.ProfileClass.String(),
	}
}

// readESIMOverview 逐个扫描 ISD-R AID，并按 EID 去重；eSTK Max 的 SE0/SE1 会保留为两个分组。
func (a *agent) readESIMOverview() (moduleESIMOverview, error) {
	overview := moduleESIMOverview{
		CardType: "esim",
		Message:  "已通过模块本机 LPA 读取 eUICC Profile",
		ChipInfo: moduleESIMChipInfo{EIDs: []moduleEUICCInfo{}},
		Profiles: []moduleESIMProfileGroup{},
	}
	seenEIDs := make(map[string]bool)
	var lastError error

	for index, aidHex := range euiccAIDs {
		// eSTK Max 的 SE0/SE1 都要探测；命中任意一个后不再打开可能映射到重复芯片的通用 AID。
		if index >= 2 && len(overview.ChipInfo.EIDs) > 0 {
			break
		}
		log.Printf("eSIM 探针: 打开 AID=%s", aidHex)
		client, err := a.newLPAClient(aidHex)
		if err != nil {
			log.Printf("eSIM 探针: 打开失败 AID=%s err=%v", aidHex, err)
			lastError = err
			continue
		}
		log.Printf("eSIM 探针: 读取 EID AID=%s", aidHex)
		eidBytes, eidErr := client.EID()
		if eidErr != nil {
			log.Printf("eSIM 探针: EID 失败 AID=%s err=%v", aidHex, eidErr)
			lastError = eidErr
			_ = client.Close()
			continue
		}
		eid := strings.ToUpper(hex.EncodeToString(eidBytes))
		log.Printf("eSIM 探针: EID 成功 AID=%s EID=%s", aidHex, eid)
		if seenEIDs[eid] {
			_ = client.Close()
			continue
		}
		seenEIDs[eid] = true

		info := moduleEUICCInfo{AID: aidHex, EID: eid, SpecGuess: "sgp22_compatible"}
		group := moduleESIMProfileGroup{EID: eid, AIDHex: aidHex, Profiles: []moduleESIMProfile{}}
		log.Printf("eSIM 探针: 读取 Profile AID=%s", aidHex)
		profiles, profileErr := safeListProfiles(client, nil)
		if profileErr != nil {
			log.Printf("eSIM 探针: Profile 失败 AID=%s err=%v", aidHex, profileErr)
			info.InfoError = profileErr.Error()
			lastError = profileErr
		} else {
			log.Printf("eSIM 探针: Profile 成功 AID=%s count=%d", aidHex, len(profiles))
			for _, profile := range profiles {
				if profile != nil {
					group.Profiles = append(group.Profiles, profilePayload(profile))
				}
			}
		}
		_ = client.Close()
		overview.ChipInfo.EIDs = append(overview.ChipInfo.EIDs, info)
		overview.Profiles = append(overview.Profiles, group)
	}

	if len(overview.ChipInfo.EIDs) == 0 {
		if lastError == nil {
			lastError = errors.New("所有候选 AID 均未开放 logical channel")
		}
		return moduleESIMOverview{}, fmt.Errorf("未发现任何 eUICC: %w", lastError)
	}
	return overview, nil
}

func normalizeKnownEUICCAID(value string) (string, error) {
	normalized := strings.ToUpper(strings.TrimSpace(value))
	if normalized == "" {
		return "", nil
	}
	for _, candidate := range euiccAIDs {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", fmt.Errorf("AID 不在已验证的 eUICC 列表中: %s", normalized)
}

// resolveProfileTarget 同时验证 ICCID 与 AID 的归属，防止跨 eUICC 误操作同名参数。
func (a *agent) resolveProfileTarget(iccidText string, requestedAID string) (string, *sgp22.ProfileInfo, error) {
	iccid, err := sgp22.NewICCID(strings.TrimSpace(iccidText))
	if err != nil {
		return "", nil, fmt.Errorf("ICCID 格式无效: %w", err)
	}
	aid, err := normalizeKnownEUICCAID(requestedAID)
	if err != nil {
		return "", nil, err
	}
	candidates := euiccAIDs
	if aid != "" {
		candidates = []string{aid}
	}
	var lastError error
	for _, candidate := range candidates {
		client, openErr := a.newLPAClient(candidate)
		if openErr != nil {
			lastError = openErr
			continue
		}
		profiles, listErr := safeListProfiles(client, iccid)
		_ = client.Close()
		if listErr != nil {
			lastError = listErr
			continue
		}
		for _, profile := range profiles {
			if profile != nil && strings.EqualFold(profile.ICCID.String(), iccid.String()) {
				return candidate, profile, nil
			}
		}
	}
	if lastError != nil {
		return "", nil, fmt.Errorf("查找 Profile %s 失败: %w", iccidText, lastError)
	}
	return "", nil, fmt.Errorf("未找到 Profile %s", iccidText)
}
