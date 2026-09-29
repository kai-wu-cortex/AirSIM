package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// pushRegistration is written by the paired iPhone over the private USB link.
// APNs provider credentials never live on the phone or the module; the HTTPS
// relay is the only component that owns the Apple .p8 key.
type pushRegistration struct {
	CloudEnabled                 *bool    `json:"cloud_enabled,omitempty"`
	DeviceID                     string   `json:"device_id"`
	DeviceSecret                 string   `json:"device_secret"`
	VoIPToken                    string   `json:"voip_token,omitempty"`
	AlertToken                   string   `json:"alert_token,omitempty"`
	WatchVoIPToken               string   `json:"watch_voip_token,omitempty"`
	WatchBundleID                string   `json:"watch_bundle_id,omitempty"`
	LiveActivityPushToStartToken string   `json:"live_activity_push_to_start_token,omitempty"`
	BundleID                     string   `json:"bundle_id"`
	Environment                  string   `json:"environment"`
	RelayURL                     string   `json:"relay_url"`
	MediaTransport               string   `json:"media_transport,omitempty"`
	AppMediaCapabilities         []string `json:"app_media_capabilities,omitempty"`
	AgentMediaCapabilities       []string `json:"agent_media_capabilities,omitempty"`
	ForceLegacyPCM               bool     `json:"force_legacy_pcm,omitempty"`
}

type pushStatus struct {
	CloudEnabled     bool   `json:"cloud_enabled"`
	Configured       bool   `json:"configured"`
	CallPushReady    bool   `json:"call_push_ready"`
	MessagePushReady bool   `json:"message_push_ready"`
	DeviceID         string `json:"device_id,omitempty"`
	Environment      string `json:"environment,omitempty"`
	RelayURL         string `json:"relay_url,omitempty"`
	LastError        string `json:"last_error,omitempty"`
	LastCallID       string `json:"last_call_id,omitempty"`
	LastSMSID        string `json:"last_sms_id,omitempty"`
	WANInterface     string `json:"wan_interface,omitempty"`
}

type incomingPushEvent struct {
	Event          string `json:"event"`
	DeviceID       string `json:"device_id"`
	DeviceSecret   string `json:"device_secret"`
	CallID         string `json:"call_id"`
	CallUUID       string `json:"call_uuid"`
	Generation     uint64 `json:"generation"`
	CallSecret     string `json:"call_secret"`
	Number         string `json:"number,omitempty"`
	CallerName     string `json:"caller_name,omitempty"`
	IssuedAt       string `json:"issued_at"`
	ExpiresAt      string `json:"expires_at"`
	MediaTransport string `json:"media_transport,omitempty"`
}

type incomingSMSPushEvent struct {
	Event        string `json:"event"`
	DeviceID     string `json:"device_id"`
	DeviceSecret string `json:"device_secret"`
	DeliveryID   string `json:"delivery_id"`
	Sender       string `json:"sender"`
	Content      string `json:"content"`
	Code         string `json:"code,omitempty"`
	Timestamp    string `json:"timestamp"`
}

type callOwnerPushEvent struct {
	Event        string `json:"event"`
	DeviceID     string `json:"device_id"`
	DeviceSecret string `json:"device_secret"`
	CallID       string `json:"call_id"`
	CallUUID     string `json:"call_uuid"`
	Generation   uint64 `json:"generation"`
	Owner        string `json:"owner"`
	Phase        string `json:"phase"`
}

type callStatePushEvent struct {
	Event        string `json:"event"`
	DeviceID     string `json:"device_id"`
	DeviceSecret string `json:"device_secret"`
	CallID       string `json:"call_id"`
	CallUUID     string `json:"call_uuid"`
	Generation   uint64 `json:"generation"`
	Phase        string `json:"phase"`
	Source       string `json:"source"`
	Timestamp    string `json:"timestamp"`
	TraceID      string `json:"trace_id,omitempty"`
}

type agentHeartbeatSnapshot struct {
	ATOK                 bool
	CellularState        string
	CellularRegistration string
	CellularRecovery     string
	ECMCarrier           string
	SignalDBM            *int
}

type agentHeartbeatEvent struct {
	Event                string `json:"event"`
	DeviceID             string `json:"device_id"`
	DeviceSecret         string `json:"device_secret"`
	AgentVersion         string `json:"agent_version"`
	ATOK                 bool   `json:"at_ok"`
	CellularState        string `json:"cellular_state"`
	CellularRegistration string `json:"cellular_registration,omitempty"`
	CellularRecovery     string `json:"cellular_recovery,omitempty"`
	ECMCarrier           string `json:"ecm_carrier,omitempty"`
	SignalDBM            *int   `json:"signal_dbm,omitempty"`
}

type pushManager struct {
	mu             sync.Mutex
	configPath     string
	config         pushRegistration
	client         *http.Client
	lastError      string
	lastCallID     string
	lastUUID       string
	lastSecret     string
	lastGeneration uint64
	lastSMSID      string

	callDelivered   bool
	callInFlight    bool
	smsDelivered    map[string]bool
	smsInFlight     map[string]bool
	smsOrder        []string
	onCallDelivered func(cloudCallDescriptor)
}

var pushTokenPattern = regexp.MustCompile(`^[0-9a-fA-F]{16,512}$`)

// QDC507 固件经常把 resolv.conf 留空，并把 Go 系统解析器指向不可用的
// [::1]:53。模块实机上 1.1.1.1/8.8.8.8 的 IPv4 DNS 可达性更稳定；阿里
// DNS 保留为中国大陆网络的第三兜底。
var pushDNSServers = []string{"1.1.1.1:53", "8.8.8.8:53", "223.5.5.5:53"}

func newPushManager(configPath string) *pushManager {
	manager := &pushManager{
		configPath:   configPath,
		client:       newPushHTTPClient(),
		smsDelivered: map[string]bool{},
		smsInFlight:  map[string]bool{},
	}
	data, err := os.ReadFile(configPath)
	if err == nil {
		if decodeErr := json.Unmarshal(data, &manager.config); decodeErr != nil {
			backup, backupErr := os.ReadFile(configPath + ".last-good")
			if backupErr == nil && json.Unmarshal(backup, &manager.config) == nil {
				_ = writePushConfigAtomically(configPath, backup)
			} else {
				manager.lastError = "读取推送配置失败: " + decodeErr.Error()
			}
		}
	} else if !os.IsNotExist(err) {
		manager.lastError = "读取推送配置失败: " + err.Error()
	}
	return manager
}

// newPushHTTPClient keeps the module's local APIs independent from DNS, while
// giving the public HTTPS relay a fallback when vendor resolv.conf points at an
// unavailable loopback resolver (observed as [::1]:53 on QDC507 firmware).
func newPushHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	baseDialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	configurePushDialer(baseDialer)
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return dialPushAddress(ctx, baseDialer, network, address)
	}
	// 蜂窝链路实测 RTT 会短时达到 1.4 秒并伴随丢包。心跳复用 keep-alive 后
	// 不会每 30 秒重新握手；首次连接则给 DNS/TCP/TLS 足够恢复窗口。
	transport.TLSHandshakeTimeout = 15 * time.Second
	transport.ResponseHeaderTimeout = 15 * time.Second
	transport.IdleConnTimeout = 90 * time.Second
	return &http.Client{Timeout: 30 * time.Second, Transport: transport}
}

func dialPushAddress(ctx context.Context, baseDialer *net.Dialer, network, address string) (net.Conn, error) {
	host, port, splitErr := net.SplitHostPort(address)
	if splitErr != nil || net.ParseIP(host) != nil {
		return baseDialer.DialContext(ctx, network, address)
	}

	addresses, fallbackErr := lookupPushIPv4(ctx, host)
	for _, resolved := range addresses {
		connection, dialErr := baseDialer.DialContext(
			ctx, network, net.JoinHostPort(resolved.String(), port),
		)
		if dialErr == nil {
			return connection, nil
		}
		fallbackErr = dialErr
	}

	// 公网 DNS 被网络侧拦截时再尝试系统解析器；在 QDC507 的空 resolv.conf
	// 场景中，自定义 IPv4 DNS 会先成功，避免被 ::1 和不可达 AAAA 记录拖慢。
	connection, systemErr := baseDialer.DialContext(ctx, network, address)
	if systemErr == nil {
		return connection, nil
	}
	if fallbackErr != nil {
		return nil, fmt.Errorf("公网 IPv4 DNS/连接失败: %v；系统 DNS 也失败: %w", fallbackErr, systemErr)
	}
	return nil, systemErr
}

func lookupPushIPv4(ctx context.Context, host string) ([]net.IP, error) {
	var fallbackErr error
	for _, dnsServer := range pushDNSServers {
		server := dnsServer
		resolverDialer := &net.Dialer{Timeout: 4 * time.Second}
		configurePushDialer(resolverDialer)
		resolver := &net.Resolver{
			PreferGo: true,
			Dial: func(resolveContext context.Context, _, _ string) (net.Conn, error) {
				return resolverDialer.DialContext(resolveContext, "udp4", server)
			},
		}
		resolveContext, cancel := context.WithTimeout(ctx, 5*time.Second)
		addresses, resolveErr := resolver.LookupIPAddr(resolveContext, host)
		cancel()
		if resolveErr != nil {
			fallbackErr = resolveErr
			continue
		}
		ipv4 := pushIPv4Addresses(addresses)
		if len(ipv4) > 0 {
			return ipv4, nil
		}
		fallbackErr = errors.New("DNS 只返回模块当前不可达的 IPv6 地址")
	}
	if fallbackErr != nil {
		return nil, fallbackErr
	}
	return nil, errors.New("公网 DNS 没有返回 IPv4 地址")
}

func pushIPv4Addresses(addresses []net.IPAddr) []net.IP {
	result := make([]net.IP, 0, len(addresses))
	for _, address := range addresses {
		if ipv4 := address.IP.To4(); ipv4 != nil {
			result = append(result, ipv4)
		}
	}
	return result
}

func validOptionalPushToken(token string) bool {
	return token == "" || (len(token)%2 == 0 && pushTokenPattern.MatchString(token))
}

func validatePushRegistration(registration pushRegistration) error {
	registration.DeviceID = strings.TrimSpace(registration.DeviceID)
	registration.BundleID = strings.TrimSpace(registration.BundleID)
	registration.RelayURL = strings.TrimSpace(registration.RelayURL)
	if registration.DeviceID == "" || len(registration.DeviceID) > 128 {
		return errors.New("device_id 无效")
	}
	if len(registration.DeviceSecret) < 16 || len(registration.DeviceSecret) > 512 {
		return errors.New("device_secret 无效")
	}
	if registration.VoIPToken == "" && registration.AlertToken == "" && registration.WatchVoIPToken == "" && registration.LiveActivityPushToStartToken == "" {
		return errors.New("至少需要一个 APNs token")
	}
	if !validOptionalPushToken(registration.VoIPToken) {
		return errors.New("voip_token 无效")
	}
	if !validOptionalPushToken(registration.AlertToken) {
		return errors.New("alert_token 无效")
	}
	if !validOptionalPushToken(registration.WatchVoIPToken) {
		return errors.New("watch_voip_token 无效")
	}
	if !validOptionalPushToken(registration.LiveActivityPushToStartToken) {
		return errors.New("live_activity_push_to_start_token 无效")
	}
	if registration.BundleID == "" || len(registration.BundleID) > 255 {
		return errors.New("bundle_id 无效")
	}
	if registration.WatchVoIPToken != "" && registration.WatchBundleID != registration.BundleID+".watchkitapp" {
		return errors.New("watch_bundle_id 与主应用不匹配")
	}
	if registration.Environment != "sandbox" && registration.Environment != "production" {
		return errors.New("environment 必须是 sandbox 或 production")
	}
	if registration.RelayURL != "" {
		relay, err := url.Parse(registration.RelayURL)
		if err != nil || relay.Scheme != "https" || relay.Host == "" || relay.User != nil {
			return errors.New("relay_url 必须是无凭据的 HTTPS 地址")
		}
	}
	return nil
}

func (p *pushManager) store(registration pushRegistration) error {
	registration.DeviceID = strings.TrimSpace(registration.DeviceID)
	registration.BundleID = strings.TrimSpace(registration.BundleID)
	registration.RelayURL = strings.TrimRight(strings.TrimSpace(registration.RelayURL), "/")
	registration.VoIPToken = strings.ToLower(registration.VoIPToken)
	registration.AlertToken = strings.ToLower(registration.AlertToken)
	registration.WatchVoIPToken = strings.ToLower(registration.WatchVoIPToken)
	registration.LiveActivityPushToStartToken = strings.ToLower(registration.LiveActivityPushToStartToken)
	if err := validatePushRegistration(registration); err != nil {
		return err
	}
	data, err := json.MarshalIndent(registration, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.configPath), 0o700); err != nil {
		return err
	}
	if err := writePushConfigAtomically(p.configPath+".last-good", data); err != nil {
		return err
	}
	if err := writePushConfigAtomically(p.configPath, data); err != nil {
		return err
	}
	p.mu.Lock()
	p.config = registration
	p.lastError = ""
	p.mu.Unlock()
	return nil
}

func writePushConfigAtomically(path string, data []byte) error {
	return writePushConfigAtomicallyWithDurability(
		path,
		data,
		syncPushConfigFile,
		syncPushConfigDirectory,
	)
}

func writePushConfigAtomicallyWithDurability(
	path string,
	data []byte,
	syncFile func(string) error,
	syncDirectory func(string) error,
) error {
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	if syncFile != nil {
		if err := syncFile(temporary); err != nil {
			_ = os.Remove(temporary)
			return err
		}
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	if syncDirectory != nil {
		if err := syncDirectory(filepath.Dir(path)); err != nil {
			return err
		}
	}
	return nil
}

func syncPushConfigFile(path string) error {
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func syncPushConfigDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func (p *pushManager) cloudEnabledLocked() bool {
	return p.config.CloudEnabled == nil || *p.config.CloudEnabled
}

func (p *pushManager) setCloudEnabled(enabled bool) error {
	p.mu.Lock()
	registration := p.config
	p.mu.Unlock()
	registration.CloudEnabled = &enabled
	return p.store(registration)
}

func (p *pushManager) status() pushStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	cloudEnabled := p.cloudEnabledLocked()
	baseReady := cloudEnabled && p.config.DeviceID != "" && p.config.RelayURL != ""
	return pushStatus{
		CloudEnabled:     cloudEnabled,
		Configured:       baseReady && (p.config.VoIPToken != "" || p.config.AlertToken != "" || p.config.WatchVoIPToken != ""),
		CallPushReady:    baseReady && (p.config.VoIPToken != "" || p.config.WatchVoIPToken != ""),
		MessagePushReady: baseReady && p.config.AlertToken != "",
		DeviceID:         p.config.DeviceID,
		Environment:      p.config.Environment,
		RelayURL:         p.config.RelayURL,
		LastError:        p.lastError,
		LastCallID:       p.lastCallID,
		LastSMSID:        p.lastSMSID,
		WANInterface:     detectPushWANInterface(),
	}
}

func (p *pushManager) sendRegistration() error {
	p.mu.Lock()
	registration := p.config
	client := p.client
	p.mu.Unlock()
	if registration.CloudEnabled != nil && !*registration.CloudEnabled {
		return nil
	}
	if registration.RelayURL == "" {
		return errors.New("尚未配置公网推送中继")
	}
	// This Agent build intentionally advertises only the transport it can
	// actually execute. Relay rollout therefore cannot select WebRTC early.
	registration.AgentMediaCapabilities = []string{cloudMediaTransportLegacyPCM}
	registration.MediaTransport = resolveCloudMediaTransport(
		registration.MediaTransport,
		registration.AgentMediaCapabilities,
		registration.ForceLegacyPCM,
	)
	return p.postJSON(client, registration.RelayURL+"/v1/devices/register", registration)
}

func (p *pushManager) sendIncoming(call callRecord, now time.Time) (bool, error) {
	if call.Direction != "incoming" || (call.State != "incoming" && call.State != "waiting") {
		return false, nil
	}
	p.mu.Lock()
	registration := p.config
	if !p.cloudEnabledLocked() || registration.RelayURL == "" || (registration.VoIPToken == "" && registration.WatchVoIPToken == "") {
		p.mu.Unlock()
		return false, nil
	}
	var uuid, secret string
	var generation uint64
	if p.lastCallID == call.ID {
		if p.callDelivered || p.callInFlight {
			p.mu.Unlock()
			return false, nil
		}
		uuid = p.lastUUID
		secret = p.lastSecret
		generation = p.lastGeneration
	} else {
		var err error
		uuid, err = randomUUID()
		if err != nil {
			p.mu.Unlock()
			return false, err
		}
		secret, err = randomCallSecret()
		if err != nil {
			p.mu.Unlock()
			return false, err
		}
		p.lastCallID = call.ID
		p.lastUUID = uuid
		p.lastSecret = secret
		p.lastGeneration++
		if p.lastGeneration == 0 {
			p.lastGeneration = 1
		}
		generation = p.lastGeneration
		p.callDelivered = false
	}
	p.callInFlight = true
	client := p.client
	onDelivered := p.onCallDelivered
	p.mu.Unlock()

	payload := incomingPushEvent{
		Event: "incoming_call", DeviceID: registration.DeviceID,
		DeviceSecret: registration.DeviceSecret, CallID: call.ID, CallUUID: uuid,
		Generation: generation, CallSecret: secret,
		Number: call.Number, IssuedAt: now.UTC().Format(time.RFC3339Nano),
		ExpiresAt: now.Add(45 * time.Second).UTC().Format(time.RFC3339Nano),
		MediaTransport: resolveCloudMediaTransport(
			registration.MediaTransport,
			[]string{cloudMediaTransportLegacyPCM},
			registration.ForceLegacyPCM,
		),
	}
	if err := p.postJSON(client, registration.RelayURL+"/v1/events/call", payload); err != nil {
		p.mu.Lock()
		if p.lastCallID == call.ID {
			p.callInFlight = false
		}
		p.lastError = err.Error()
		p.mu.Unlock()
		return false, err
	}
	p.mu.Lock()
	if p.lastCallID == call.ID {
		p.callInFlight = false
		p.callDelivered = true
	}
	p.lastError = ""
	p.mu.Unlock()
	if onDelivered != nil {
		go onDelivered(cloudCallDescriptor{
			CallID: call.ID, CallUUID: uuid, CallSecret: secret, RelayURL: registration.RelayURL,
			Generation: generation, Direction: "incoming", MediaTransport: payload.MediaTransport,
		})
	}
	return true, nil
}

func (p *pushManager) sendSMS(message smsMessage) (bool, error) {
	if message.DeliveryID == "" {
		return false, nil
	}
	p.mu.Lock()
	registration := p.config
	if !p.cloudEnabledLocked() || registration.RelayURL == "" || registration.AlertToken == "" ||
		p.smsDelivered[message.DeliveryID] || p.smsInFlight[message.DeliveryID] {
		p.mu.Unlock()
		return false, nil
	}
	p.smsInFlight[message.DeliveryID] = true
	client := p.client
	p.mu.Unlock()

	payload := incomingSMSPushEvent{
		Event: "incoming_sms", DeviceID: registration.DeviceID,
		DeviceSecret: registration.DeviceSecret, DeliveryID: message.DeliveryID,
		Sender: message.Sender, Content: message.Content, Code: message.Code,
		Timestamp: message.Timestamp.UTC().Format(time.RFC3339Nano),
	}
	err := p.postJSON(client, registration.RelayURL+"/v1/events/sms", payload)
	p.mu.Lock()
	delete(p.smsInFlight, message.DeliveryID)
	if err != nil {
		p.lastError = err.Error()
		p.mu.Unlock()
		return false, err
	}
	p.smsDelivered[message.DeliveryID] = true
	p.smsOrder = append(p.smsOrder, message.DeliveryID)
	if len(p.smsOrder) > 256 {
		delete(p.smsDelivered, p.smsOrder[0])
		p.smsOrder = p.smsOrder[1:]
	}
	p.lastSMSID = message.DeliveryID
	p.lastError = ""
	p.mu.Unlock()
	return true, nil
}

func (p *pushManager) sendCallOwner(callID, callUUID, owner, phase string) error {
	if callID == "" || callUUID == "" ||
		(owner != "watch" && owner != "iphone") ||
		(phase != "active" && phase != "ended") {
		return errors.New("通话所有权事件无效")
	}
	p.mu.Lock()
	registration := p.config
	client := p.client
	cloudEnabled := p.cloudEnabledLocked()
	generation := p.lastGeneration
	p.mu.Unlock()
	if !cloudEnabled || registration.RelayURL == "" || registration.AlertToken == "" {
		return nil
	}
	return p.postJSON(client, registration.RelayURL+"/v1/events/call-owner", callOwnerPushEvent{
		Event: "call_owner", DeviceID: registration.DeviceID,
		DeviceSecret: registration.DeviceSecret, CallID: callID, CallUUID: callUUID,
		Generation: generation, Owner: owner, Phase: phase,
	})
}

func (p *pushManager) sendCallState(callID, phase string) error {
	if callID == "" || !validCallLifecyclePhase(phase) {
		return errors.New("通话状态事件无效")
	}
	p.mu.Lock()
	registration := p.config
	client := p.client
	cloudEnabled := p.cloudEnabledLocked()
	callUUID := ""
	generation := uint64(0)
	if p.lastCallID == callID {
		callUUID = p.lastUUID
		generation = p.lastGeneration
	}
	p.mu.Unlock()
	if !cloudEnabled || registration.RelayURL == "" || callUUID == "" {
		return nil
	}
	return p.postJSON(client, registration.RelayURL+"/v1/events/call-state", callStatePushEvent{
		Event: "call_state", DeviceID: registration.DeviceID,
		DeviceSecret: registration.DeviceSecret, CallID: callID,
		CallUUID: callUUID, Generation: generation, Phase: phase,
		Source: "agent", Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		TraceID: fmt.Sprintf("agent-%s-%d-%s", callID, generation, phase),
	})
}

func validCallLifecyclePhase(phase string) bool {
	switch phase {
	case "ringing", "connecting", "active", "ending", "ended", "failed":
		return true
	default:
		return false
	}
}

func (p *pushManager) sendHeartbeat(snapshot agentHeartbeatSnapshot) error {
	if snapshot.CellularState != "registered" && snapshot.CellularState != "searching" &&
		snapshot.CellularState != "denied" && snapshot.CellularState != "unregistered" {
		return errors.New("蜂窝心跳状态无效")
	}
	p.mu.Lock()
	registration := p.config
	client := p.client
	cloudEnabled := p.cloudEnabledLocked()
	p.mu.Unlock()
	if !cloudEnabled || registration.RelayURL == "" {
		return nil
	}
	return p.postJSON(client, registration.RelayURL+"/v1/events/heartbeat", agentHeartbeatEvent{
		Event: "agent_heartbeat", DeviceID: registration.DeviceID,
		DeviceSecret: registration.DeviceSecret, AgentVersion: agentVersion,
		ATOK: snapshot.ATOK, CellularState: snapshot.CellularState,
		CellularRegistration: snapshot.CellularRegistration,
		CellularRecovery:     snapshot.CellularRecovery, ECMCarrier: snapshot.ECMCarrier,
		SignalDBM: snapshot.SignalDBM,
	})
}

func (p *pushManager) commandRegistration() (pushRegistration, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	registration := p.config
	ready := p.cloudEnabledLocked() && registration.DeviceID != "" &&
		registration.DeviceSecret != "" && registration.RelayURL != ""
	return registration, ready
}

func (p *pushManager) pullCommands() ([]cloudDeviceCommand, error) {
	registration, ready := p.commandRegistration()
	if !ready {
		return nil, nil
	}
	var batch struct {
		Commands []cloudDeviceCommand `json:"commands"`
	}
	err := p.postJSONResponse(
		p.client,
		registration.RelayURL+"/v1/commands/pull",
		map[string]string{
			"device_id": registration.DeviceID, "device_secret": registration.DeviceSecret,
		},
		&batch,
	)
	if err != nil {
		return nil, err
	}
	return batch.Commands, nil
}

func (p *pushManager) completeCommand(result cloudCommandResult) error {
	registration, ready := p.commandRegistration()
	if !ready {
		return errors.New("公网命令设备身份无效")
	}
	payload := struct {
		DeviceID     string         `json:"device_id"`
		DeviceSecret string         `json:"device_secret"`
		CommandID    string         `json:"command_id"`
		Status       string         `json:"status"`
		Result       map[string]any `json:"result,omitempty"`
		Error        string         `json:"error,omitempty"`
	}{
		DeviceID: registration.DeviceID, DeviceSecret: registration.DeviceSecret,
		CommandID: result.CommandID, Status: result.Status, Result: result.Result, Error: result.Error,
	}
	return p.postJSON(p.client, registration.RelayURL+"/v1/commands/complete", payload)
}

func (p *pushManager) postJSON(client *http.Client, endpoint string, value any) error {
	return p.postJSONResponse(client, endpoint, value, nil)
}

func (p *pushManager) postJSONResponse(client *http.Client, endpoint string, value, output any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	request, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "AirSIM-QDC507/"+agentVersion)
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("推送中继返回 HTTP %d", response.StatusCode)
	}
	if output != nil {
		if err := json.NewDecoder(response.Body).Decode(output); err != nil {
			return fmt.Errorf("解析推送中继响应失败: %w", err)
		}
	}
	return nil
}

func randomUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"%08x-%04x-%04x-%04x-%012x",
		value[0:4], value[4:6], value[6:8], value[8:10], value[10:16],
	), nil
}

func randomCallSecret() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func (a *agent) pushRegister(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var registration pushRegistration
	if !decodeJSON(response, request, &registration) {
		return
	}
	if err := a.push.store(registration); err != nil {
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	go a.syncPushRegistration()
	a.mu.RLock()
	var call *callRecord
	if a.calls.Active != nil {
		copy := *a.calls.Active
		call = &copy
	}
	a.mu.RUnlock()
	if call != nil {
		a.scheduleIncomingPush(call.ID)
	}
	writeJSON(response, http.StatusOK, a.push.status())
}

func (a *agent) pushStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	writeJSON(response, http.StatusOK, a.push.status())
}

func (a *agent) pushMode(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Enabled bool `json:"enabled"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if err := a.push.setCloudEnabled(body.Enabled); err != nil {
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	if body.Enabled {
		go a.syncPushRegistration()
	}
	writeJSON(response, http.StatusOK, a.push.status())
}

func (a *agent) syncPushRegistration() {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(1<<attempt) * time.Second)
		}
		if err := a.push.sendRegistration(); err == nil {
			if syncErr := a.syncCloudCommandsOnce(); syncErr != nil {
				a.debug.add("cloud-command", "pull_failed", "注册后拉取待处理命令失败", syncErr.Error(), nil)
			}
			return
		} else {
			lastErr = err
		}
	}
	if lastErr != nil {
		a.push.mu.Lock()
		a.push.lastError = lastErr.Error()
		a.push.mu.Unlock()
	}
}

func (a *agent) scheduleIncomingPush(callID string) {
	if callID == "" {
		return
	}
	go func() {
		// Give +CLIP a short window to fill the number without delaying CallKit by seconds.
		time.Sleep(350 * time.Millisecond)
		a.mu.RLock()
		if a.calls.Active == nil || a.calls.Active.ID != callID {
			a.mu.RUnlock()
			return
		}
		call := *a.calls.Active
		a.mu.RUnlock()
		var lastErr error
		for attempt := 0; attempt < 3; attempt++ {
			if attempt > 0 {
				time.Sleep(time.Duration(1<<attempt) * time.Second)
			}
			if _, err := a.push.sendIncoming(call, time.Now()); err == nil {
				return
			} else {
				lastErr = err
			}
		}
		if lastErr != nil {
			a.debug.add("push", "tx", "来电推送失败", lastErr.Error(), map[string]string{"call_id": callID})
		}
	}()
}

func (a *agent) scheduleSMSPush(message smsMessage) {
	if message.DeliveryID == "" || a.push == nil {
		return
	}
	go func() {
		var lastErr error
		for attempt := 0; attempt < 3; attempt++ {
			if attempt > 0 {
				time.Sleep(time.Duration(1<<attempt) * time.Second)
			}
			if _, err := a.push.sendSMS(message); err == nil {
				return
			} else {
				lastErr = err
			}
		}
		if lastErr != nil {
			a.debug.add("push", "tx", "短信推送失败", lastErr.Error(), map[string]string{"delivery_id": message.DeliveryID})
		}
	}()
}
