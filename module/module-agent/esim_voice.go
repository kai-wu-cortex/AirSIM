package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	sgp22 "github.com/damonto/euicc-go/v2"
)

const (
	agentDataDirectory = "/data/djonehub"
	notesFilePath      = agentDataDirectory + "/esim-notes.json"
	voiceRuntimePath   = agentDataDirectory + "/voice-runtime"
)

type esimNote struct {
	Label string `json:"label,omitempty"`
	Phone string `json:"phone,omitempty"`
	Tags  string `json:"tags,omitempty"`
}

// 常见消费级 eUICC 的 ISD-R AID；eSTK Max 的 SE0/SE1 必须优先扫描并分别保留。
var euiccAIDs = []string{
	"A06573746B6D65FFFF4953442D522030",
	"A06573746B6D65FFFF4953442D522031",
	"A0000005591010FFFFFFFF8900000100",
	"A0000005591010000000008900000300",
	"A000000559101000000000890000000300",
}

func (a *agent) detectEUICC() (bool, string) {
	for _, aid := range euiccAIDs {
		response, err := a.at.command(`AT+CCHO="`+aid+`"`, 5*time.Second)
		if err != nil {
			continue
		}
		channel := parseLogicalChannel(response)
		if channel <= 0 {
			continue
		}
		_, _ = a.at.command(fmt.Sprintf("AT+CCHC=%d", channel), 3*time.Second)
		return true, aid
	}
	return false, ""
}

func parseLogicalChannel(response string) int {
	match := regexp.MustCompile(`\+CCHO:\s*(\d+)`).FindStringSubmatch(response)
	if len(match) == 2 {
		value, _ := strconv.Atoi(match[1])
		return value
	}
	for _, line := range strings.Split(response, "\n") {
		line = strings.TrimSpace(line)
		if value, err := strconv.Atoi(line); err == nil {
			return value
		}
	}
	return 0
}

func (a *agent) esimOverview(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.esimMu.Lock()
	defer a.esimMu.Unlock()
	overview, err := a.readESIMOverview()
	if err != nil {
		message := err.Error()
		if isPhysicalSIMESIMProbeError(err) {
			message = "当前卡片为实体卡，非 eSIM 卡片"
		}
		writeJSON(response, http.StatusOK, map[string]any{
			"card_type": "physical_sim", "message": message,
			"profiles": []any{},
		})
		return
	}
	writeJSON(response, http.StatusOK, overview)
}

// 实体 SIM 无法打开 GSMA eUICC 管理 AID，这属于卡片类型结果而不是服务故障。
func isPhysicalSIMESIMProbeError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "未发现任何 euicc") &&
		strings.Contains(message, "at 指令失败") &&
		strings.Contains(message, "error")
}

func (a *agent) esimHealth(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	status := a.modem
	a.mu.RUnlock()
	registered := status.RegistrationText == "已注册" || status.RegistrationText == "漫游注册"
	writeJSON(response, http.StatusOK, map[string]any{
		"ok": status.SIMInserted && registered, "module_iccid": status.ICCID,
		"registration": status.RegistrationText, "registered": registered,
		"signal_dbm": status.SignalDBM, "network_mode": status.NetworkMode,
	})
}

func (a *agent) esimNotes(response http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		notes, err := loadESIMNotes()
		if err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(response, http.StatusOK, map[string]any{"notes": notes})
	case http.MethodPost, http.MethodPut:
		var body struct {
			ICCID string `json:"iccid"`
			Label string `json:"label"`
			Phone string `json:"phone"`
			Tags  string `json:"tags"`
		}
		if !decodeJSON(response, request, &body) {
			return
		}
		body.ICCID = strings.TrimSpace(body.ICCID)
		if body.ICCID == "" || len(body.ICCID) > 32 || !digitsPattern.MatchString(body.ICCID) {
			writeError(response, http.StatusBadRequest, "ICCID 格式无效")
			return
		}
		notes, err := loadESIMNotes()
		if err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		notes[body.ICCID] = esimNote{Label: strings.TrimSpace(body.Label), Phone: strings.TrimSpace(body.Phone), Tags: strings.TrimSpace(body.Tags)}
		if err := saveESIMNotes(notes); err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(response, http.StatusOK, map[string]string{"message": "备注已保存"})
	default:
		requireMethod(response, request, http.MethodGet, http.MethodPost, http.MethodPut)
	}
}

func loadESIMNotes() (map[string]esimNote, error) {
	notes := map[string]esimNote{}
	data, err := os.ReadFile(notesFilePath)
	if os.IsNotExist(err) {
		return notes, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取 eSIM 备注失败: %w", err)
	}
	if err := json.Unmarshal(data, &notes); err != nil {
		return nil, fmt.Errorf("解析 eSIM 备注失败: %w", err)
	}
	return notes, nil
}

func saveESIMNotes(notes map[string]esimNote) error {
	if err := os.MkdirAll(agentDataDirectory, 0o700); err != nil {
		return fmt.Errorf("创建数据目录失败: %w", err)
	}
	data, err := json.MarshalIndent(notes, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(agentDataDirectory, ".esim-notes-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, notesFilePath)
}

func (a *agent) esimPhonebookProbe(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	storage, storageErr := a.at.command("AT+CPBS=?", 5*time.Second)
	selected, selectedErr := a.at.command(`AT+CPBS="SM"`, 5*time.Second)
	read, readErr := a.at.command("AT+CPBR=?", 5*time.Second)
	write, writeErr := a.at.command("AT+CPBW=?", 5*time.Second)
	writeJSON(response, http.StatusOK, map[string]any{
		"storage_supported": storageErr == nil, "storage_selected": selectedErr == nil,
		"read_supported": readErr == nil, "write_supported": writeErr == nil,
		"storage_status": strings.TrimSpace(storage + "\n" + selected),
		"responses":      map[string]string{"read": read, "write": write},
	})
}

func (a *agent) esimSwitch(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		ICCID string `json:"iccid"`
		AID   string `json:"aid"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if !digitsPattern.MatchString(strings.TrimSpace(body.ICCID)) {
		writeError(response, http.StatusBadRequest, "ICCID 格式无效")
		return
	}
	a.esimMu.Lock()
	defer a.esimMu.Unlock()
	targetAID, profile, err := a.resolveProfileTarget(body.ICCID, body.AID)
	if err != nil {
		writeError(response, http.StatusNotFound, err.Error())
		return
	}
	if profile.ProfileState == sgp22.ProfileEnabled {
		writeJSON(response, http.StatusOK, map[string]any{
			"switch_accepted": true, "phase": "done", "target_iccid": body.ICCID,
			"recovery_pending": false, "module_reboot_requested": false,
		})
		return
	}
	iccid, _ := sgp22.NewICCID(strings.TrimSpace(body.ICCID))
	client, err := a.newLPAClient(targetAID)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	enableErr := client.EnableProfile(iccid, false)
	closeErr := client.Close()
	if enableErr != nil {
		writeError(response, http.StatusBadGateway, "启用 Profile 失败: "+enableErr.Error())
		return
	}
	if closeErr != nil {
		writeError(response, http.StatusBadGateway, "关闭 eUICC 通道失败: "+closeErr.Error())
		return
	}
	// 先返回 HTTP 结果，再重启基带；否则 iPad 会把预期的 USB 断开误报成切换失败。
	go func() {
		time.Sleep(500 * time.Millisecond)
		_, _ = a.at.command("AT+CFUN=1,1", 3*time.Second)
	}()
	writeJSON(response, http.StatusOK, map[string]any{
		"switch_accepted": true, "phase": "card_reset_settling", "target_iccid": body.ICCID,
		"recovery_pending": true, "module_reboot_requested": true, "reconnect_wait_seconds": 15,
	})
}

func (a *agent) esimProfile(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPatch, http.MethodDelete) {
		return
	}
	var body struct {
		ICCID string `json:"iccid"`
		AID   string `json:"aid"`
		Name  string `json:"name"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if !digitsPattern.MatchString(strings.TrimSpace(body.ICCID)) {
		writeError(response, http.StatusBadRequest, "ICCID 格式无效")
		return
	}
	a.esimMu.Lock()
	defer a.esimMu.Unlock()
	targetAID, profile, err := a.resolveProfileTarget(body.ICCID, body.AID)
	if err != nil {
		writeError(response, http.StatusNotFound, err.Error())
		return
	}
	iccid, _ := sgp22.NewICCID(strings.TrimSpace(body.ICCID))
	client, err := a.newLPAClient(targetAID)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	defer client.Close()
	switch request.Method {
	case http.MethodPatch:
		name := strings.TrimSpace(body.Name)
		if name == "" || len([]byte(name)) > 64 {
			writeError(response, http.StatusBadRequest, "Profile 名称必须为 1 到 64 字节")
			return
		}
		if err := client.SetNickname(iccid, name); err != nil {
			writeError(response, http.StatusBadGateway, "修改 Profile 名称失败: "+err.Error())
			return
		}
		writeJSON(response, http.StatusOK, map[string]string{"message": "Profile 名称已修改"})
	case http.MethodDelete:
		if profile.ProfileState == sgp22.ProfileEnabled {
			writeError(response, http.StatusConflict, "正在使用的 Profile 不能删除，请先切换到其他 Profile")
			return
		}
		if err := client.DeleteProfile(iccid); err != nil {
			writeError(response, http.StatusBadGateway, "删除 Profile 失败: "+err.Error())
			return
		}
		writeJSON(response, http.StatusOK, map[string]string{"message": "Profile 已删除"})
	}
}

func (a *agent) esimDownload(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		SMDP             string `json:"smdp"`
		MatchingID       string `json:"matching_id"`
		ConfirmationCode string `json:"confirmation_code"`
		IMEI             string `json:"imei"`
		AID              string `json:"aid"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if strings.TrimSpace(body.SMDP) == "" {
		writeError(response, http.StatusBadRequest, "SMDP 地址不能为空")
		return
	}
	a.unsupported(response, "eSIM 下载需要模块内完整 LPA 和 TLS 事务，当前代理尚未接入")
}

func (a *agent) moduleSetup(response http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodGet {
		result, err := a.at.command("AT", 3*time.Second)
		ready := err == nil && strings.Contains(result, "OK")
		summary := "模块代理需要初始化"
		if ready {
			summary = "模块代理已就绪"
		}
		writeJSON(response, http.StatusOK, map[string]any{
			"state": map[bool]string{true: "ready", false: "error"}[ready], "summary": summary,
			"detail": errorText(err), "can_initialize": !ready, "requires_confirmation": !ready,
		})
		return
	}
	if request.Method != http.MethodPost {
		requireMethod(response, request, http.MethodGet, http.MethodPost)
		return
	}
	var body struct {
		Confirm bool `json:"confirm"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if !body.Confirm {
		writeError(response, http.StatusBadRequest, "必须明确确认初始化")
		return
	}
	commands := []string{"ATE0", "AT+CMEE=2", "AT+CLIP=1", "AT+CMGF=1"}
	for _, command := range commands {
		if _, err := a.at.command(command, 5*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, fmt.Sprintf("初始化 %s 失败: %v", command, err))
			return
		}
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"state": "ready", "summary": "模块代理初始化完成", "detail": "AT、来电显示和短信文本模式已配置",
		"can_initialize": false, "requires_confirmation": false,
	})
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func (a *agent) voiceStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	writeJSON(response, http.StatusOK, a.currentVoiceStatus())
}

func (a *agent) currentVoiceStatus() map[string]any {
	runtimeInstalled, validationError := validateVoiceRuntime()
	a.voice.mu.Lock()
	routeReady := a.voice.ready
	lastError := a.voice.lastError
	a.voice.mu.Unlock()
	detail := "模块语音运行时未安装"
	if runtimeInstalled {
		detail = "模块语音运行时已安装；通话建立后由模块内 helper 启动 ECM 网络 PCM"
	} else if validationError != nil {
		detail = validationError.Error()
	}
	return map[string]any{
		"ready": routeReady || runtimeInstalled, "runtime_installed": runtimeInstalled,
		"runtime_source": "moluncn/mavo@0443dfd", "runtime_detail": detail, "last_error": lastError,
	}
}

func (a *agent) voiceProvision(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Confirm bool `json:"confirm"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if !body.Confirm {
		writeError(response, http.StatusBadRequest, "必须明确确认安装语音运行时")
		return
	}
	if installed, _ := validateVoiceRuntime(); installed {
		writeJSON(response, http.StatusOK, a.currentVoiceStatus())
		return
	}
	writeError(response, http.StatusConflict, "代理包不包含受限语音运行时，请在首次部署时由 Mac 安装用户本机缓存")
}
