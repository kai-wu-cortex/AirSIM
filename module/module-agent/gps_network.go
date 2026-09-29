package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type gpsFix struct {
	UTC        string    `json:"utc,omitempty"`
	Latitude   string    `json:"latitude,omitempty"`
	Longitude  string    `json:"longitude,omitempty"`
	HDOP       string    `json:"hdop"`
	Altitude   string    `json:"altitude,omitempty"`
	Fix        string    `json:"fix,omitempty"`
	Satellites string    `json:"satellites"`
	Timestamp  time.Time `json:"timestamp"`
}

type gpsTracker struct {
	Enabled   bool
	LastFix   *gpsFix
	LastError string
}

func (a *agent) runGPSCommand(command string, timeout time.Duration) (string, error) {
	if a.gpsCommand != nil {
		return a.gpsCommand(command, timeout)
	}
	return a.at.command(command, timeout)
}

func parseGPSLocation(response string) (*gpsFix, error) {
	value := commandValue(response, "+QGPSLOC:")
	if value == "" {
		return nil, fmt.Errorf("暂未获得定位，请移至窗边或室外后重试")
	}
	fields := strings.Split(value, ",")
	if len(fields) < 11 {
		return nil, fmt.Errorf("定位响应格式不完整")
	}
	return &gpsFix{
		UTC: strings.TrimSpace(fields[0]), Latitude: strings.TrimSpace(fields[1]), Longitude: strings.TrimSpace(fields[2]),
		HDOP: strings.TrimSpace(fields[3]), Altitude: strings.TrimSpace(fields[4]), Fix: strings.TrimSpace(fields[5]),
		Satellites: strings.TrimSpace(fields[10]), Timestamp: time.Now(),
	}, nil
}

func (a *agent) gpsStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	result, err := a.runGPSCommand("AT+QGPS?", 3*time.Second)
	a.mu.Lock()
	if err == nil {
		a.gps.Enabled = strings.Contains(result, "+QGPS: 1")
	}
	status := a.gps
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{"enabled": status.Enabled, "last_fix": status.LastFix, "last_error": status.LastError})
}

func (a *agent) gpsStart(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	result, err := a.runGPSCommand("AT+QGPS=1", 8*time.Second)
	if err != nil && !strings.Contains(strings.ToUpper(result), "ALREADY") {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	a.mu.Lock()
	a.gps.Enabled = true
	a.gps.LastError = ""
	lastFix := a.gps.LastFix
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{"enabled": true, "last_fix": lastFix})
}

func (a *agent) gpsStop(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	result, err := a.runGPSCommand("AT+QGPSEND", 8*time.Second)
	if err != nil && !strings.Contains(strings.ToUpper(result), "NOT START") {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	a.mu.Lock()
	a.gps.Enabled = false
	a.gps.LastError = ""
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]bool{"enabled": false})
}

func (a *agent) gpsRefresh(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	a.mu.RLock()
	enabled := a.gps.Enabled
	a.mu.RUnlock()
	if !enabled {
		writeError(response, http.StatusConflict, "请先启动定位")
		return
	}
	result, err := a.runGPSCommand("AT+QGPSLOC=2", 12*time.Second)
	if err != nil {
		a.mu.Lock()
		a.gps.LastError = err.Error()
		a.mu.Unlock()
		writeError(response, http.StatusServiceUnavailable, err.Error())
		return
	}
	fix, err := parseGPSLocation(result)
	if err != nil {
		a.mu.Lock()
		a.gps.LastError = err.Error()
		a.mu.Unlock()
		writeError(response, http.StatusServiceUnavailable, err.Error())
		return
	}
	a.mu.Lock()
	a.gps.LastFix = fix
	a.gps.LastError = ""
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, fix)
}

func (a *agent) executeAT(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Command string `json:"command"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	command := strings.TrimSpace(body.Command)
	if len(command) < 2 || len(command) > 256 || !strings.HasPrefix(strings.ToUpper(command), "AT") || strings.ContainsAny(command, "\r\n\x00\x1a") {
		writeError(response, http.StatusBadRequest, "AT 指令格式无效")
		return
	}
	result, err := a.at.command(command, 15*time.Second)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]string{"response": result})
}

func (a *agent) cellularPolicy(response http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		a.mu.RLock()
		forceOff := a.force4GOff
		a.mu.RUnlock()
		writeJSON(response, http.StatusOK, map[string]any{"force_off": forceOff, "services": []string{"module-packet-data"}})
	case http.MethodPost:
		var body struct {
			ForceOff *bool `json:"force_off"`
		}
		if !decodeJSON(response, request, &body) {
			return
		}
		if body.ForceOff == nil {
			writeError(response, http.StatusBadRequest, "缺少 force_off")
			return
		}
		command := "AT+CGATT=1"
		if *body.ForceOff {
			command = "AT+CGATT=0"
		}
		if _, err := a.at.command(command, 12*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
		a.mu.Lock()
		a.force4GOff = *body.ForceOff
		a.mu.Unlock()
		writeJSON(response, http.StatusOK, map[string]any{"force_off": *body.ForceOff, "services": []string{"module-packet-data"}})
	default:
		requireMethod(response, request, http.MethodGet, http.MethodPost)
	}
}

func (a *agent) check4G(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	addressResponse, addressErr := a.at.command("AT+CGPADDR=1", 5*time.Second)
	attachResponse, attachErr := a.at.command("AT+CGATT?", 5*time.Second)
	ok := addressErr == nil && attachErr == nil && strings.Contains(attachResponse, "+CGATT: 1") && hasPDPAddress(addressResponse)
	summary := "模块 4G 数据出口不可用"
	if ok {
		summary = "模块 4G 数据出口正常"
	}
	detail := strings.TrimSpace(attachResponse + "\n" + addressResponse)
	writeJSON(response, http.StatusOK, map[string]any{"ok": ok, "summary": summary, "detail": detail})
}

func hasPDPAddress(response string) bool {
	value := commandValue(response, "+CGPADDR:")
	for _, field := range splitCSV(value) {
		field = strings.Trim(field, `"`)
		if ip := net.ParseIP(field); ip != nil && !ip.IsUnspecified() {
			return true
		}
	}
	return false
}

func (a *agent) checkProxy(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	// iPad 直连版不再经过 Mac HTTP 代理，这里的“代理”即模块本地控制服务。
	writeJSON(response, http.StatusOK, map[string]any{
		"ok": true, "summary": "模块本地控制服务正常", "detail": "直连模式无需 Mac 代理，控制面监听 192.168.225.1:7575",
	})
}

func (a *agent) rebootModule(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	writeJSON(response, http.StatusAccepted, map[string]bool{"rebooting": true})
	go func() {
		time.Sleep(200 * time.Millisecond)
		_, _ = a.at.command("AT+CFUN=1,1", 5*time.Second)
	}()
}

type usbConfiguration struct{ fields []string }

const (
	usbGadgetPath      = "/sys/devices/virtual/android_usb/android0"
	qdc507USBVendorID  = "2c7c"
	qdc507USBProductID = "0125"
)

var qdc507KnownUSBFields = []string{"0x2C7C", "0x0125", "1", "1", "1", "1", "1", "1", "1"}

func parseUSBConfiguration(response string) (usbConfiguration, error) {
	value := commandValue(response, `+QCFG: "usbcfg",`)
	if value == "" {
		// 某些固件在逗号前后加入空格，退回正则提取。
		match := regexp.MustCompile(`(?i)\+QCFG:\s*"usbcfg"\s*,\s*([^\n]+)`).FindStringSubmatch(response)
		if len(match) == 2 {
			value = match[1]
		}
	}
	fields := splitCSV(value)
	if len(fields) != 9 {
		return usbConfiguration{}, fmt.Errorf("USBCFG 功能位数量异常（%d）", len(fields))
	}
	if fields[8] != "0" && fields[8] != "1" {
		return usbConfiguration{}, fmt.Errorf("USBCFG UAC 位异常（%s）", fields[8])
	}
	return usbConfiguration{fields: fields}, nil
}

func (configuration usbConfiguration) uacEnabled() bool { return configuration.fields[8] == "1" }

func (configuration usbConfiguration) withUAC(enabled bool) string {
	fields := append([]string(nil), configuration.fields...)
	if enabled {
		fields[8] = "1"
	} else {
		fields[8] = "0"
	}
	return `AT+QCFG="usbcfg",` + strings.Join(fields, ",")
}

func knownQDC507USBConfiguration(uacEnabled bool) usbConfiguration {
	fields := append([]string(nil), qdc507KnownUSBFields...)
	if !uacEnabled {
		fields[8] = "0"
	}
	return usbConfiguration{fields: fields}
}

func inferQDC507USBConfiguration(readFile func(string) ([]byte, error)) (usbConfiguration, string, error) {
	// 仅对实机验证过的 2c7c:0125 回退，绝不把固定 USBCFG 元组盲写到其他模块。
	vendor, vendorErr := readFile(usbGadgetPath + "/idVendor")
	product, productErr := readFile(usbGadgetPath + "/idProduct")
	functions, functionsErr := readFile(usbGadgetPath + "/functions")
	if vendorErr != nil || productErr != nil || functionsErr != nil {
		return usbConfiguration{}, "", fmt.Errorf("无法读取 USB gadget 身份或功能")
	}
	if strings.ToLower(strings.TrimSpace(string(vendor))) != qdc507USBVendorID ||
		strings.ToLower(strings.TrimSpace(string(product))) != qdc507USBProductID {
		return usbConfiguration{}, "", fmt.Errorf("USB gadget 不是已验证的 QDC507 2c7c:0125")
	}
	rawFunctions := strings.TrimSpace(string(functions))
	uacEnabled := false
	for _, function := range strings.Split(rawFunctions, ",") {
		if strings.TrimSpace(function) == "audio" {
			uacEnabled = true
			break
		}
	}
	return knownQDC507USBConfiguration(uacEnabled), "gadget functions=" + rawFunctions, nil
}

func (a *agent) readUSBConfiguration() (usbConfiguration, string, error) {
	current, err := a.at.command(`AT+QCFG="usbcfg"`, 5*time.Second)
	if err == nil {
		configuration, parseErr := parseUSBConfiguration(current)
		return configuration, strings.TrimSpace(current), parseErr
	}
	configuration, raw, fallbackErr := inferQDC507USBConfiguration(os.ReadFile)
	if fallbackErr != nil {
		return usbConfiguration{}, "", fmt.Errorf("读取 USBCFG 失败（%v），gadget 回退也失败：%w", err, fallbackErr)
	}
	return configuration, raw, nil
}

const usbMacModeMarker = agentDataDirectory + "/usb-mode-mac"

func persistUSBModeMarker(path, mode string) (bool, error) {
	wantMac := mode == "mac"
	_, statErr := os.Stat(path)
	hasMarker := statErr == nil
	if statErr != nil && !os.IsNotExist(statErr) {
		return false, statErr
	}
	if hasMarker == wantMac {
		return false, nil
	}
	if !wantMac {
		return true, os.Remove(path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return false, err
	}
	temporary := path + ".new"
	if err := os.WriteFile(temporary, []byte("mac\n"), 0o600); err != nil {
		return false, err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return false, err
	}
	return true, nil
}

func (a *agent) usbProfile(response http.ResponseWriter, request *http.Request) {
	configuration, raw, err := a.readUSBConfiguration()
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	if request.Method == http.MethodGet {
		writeUSBProfile(response, configuration, raw, false, "")
		return
	}
	if request.Method != http.MethodPost {
		requireMethod(response, request, http.MethodGet, http.MethodPost)
		return
	}
	var body struct {
		Mode string `json:"mode"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	mode := strings.ToLower(strings.TrimSpace(body.Mode))
	if mode != "mobile" && mode != "mac" {
		writeError(response, http.StatusBadRequest, "mode 必须是 mobile 或 mac")
		return
	}
	wantUAC := mode == "mac"
	changed := configuration.uacEnabled() != wantUAC
	if changed {
		if _, err := a.at.command(configuration.withUAC(wantUAC), 8*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
		configuration.fields[8] = map[bool]string{true: "1", false: "0"}[wantUAC]
	}
	markerChanged, markerErr := persistUSBModeMarker(usbMacModeMarker, mode)
	if markerErr != nil {
		writeError(response, http.StatusInternalServerError, "保存 USB 模式失败: "+markerErr.Error())
		return
	}
	message := "当前已经是 iPad 直连模式"
	needsReconnect := changed || markerChanged
	if mode == "mac" {
		message = "已切换为 Mac 完整模式，模块正在重启；重连后可直接插到 Mac"
	} else if changed {
		message = "已切换为 iPad 直连模式，模块正在重启；重连后请重新插拔 USB"
	}
	writeUSBProfile(response, configuration, configuration.withUAC(wantUAC), needsReconnect, message)
	if needsReconnect {
		// 先把成功响应交给客户端，再重启模块；否则预期中的 USB 断开会被 UI 误报为失败。
		go func() {
			time.Sleep(350 * time.Millisecond)
			if _, rebootErr := a.at.command("AT+CFUN=1,1", 5*time.Second); rebootErr != nil {
				log.Printf("切换 USB 模式后的模块重启失败: %v", rebootErr)
			}
		}()
	}
}

func writeUSBProfile(response http.ResponseWriter, configuration usbConfiguration, raw string, reconnect bool, message string) {
	mode := "mobile"
	if configuration.uacEnabled() {
		mode = "mac"
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"mode": mode, "uac_enabled": configuration.uacEnabled(), "configuration": strings.TrimSpace(raw),
		"needs_reconnect": reconnect, "message": message,
	})
}

func (a *agent) networkDiagnostic(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	usbnet, usbnetErr := a.at.command(`AT+QCFG="usbnet"`, 5*time.Second)
	usbcfg, usbcfgErr := a.at.command(`AT+QCFG="usbcfg"`, 5*time.Second)
	contexts, contextsErr := a.at.command("AT+CGDCONT?", 5*time.Second)
	active, activeErr := a.at.command("AT+CGACT?", 5*time.Second)
	addresses, addressesErr := a.at.command("AT+CGPADDR", 5*time.Second)
	errors := map[string]string{}
	for name, err := range map[string]error{"usbnet": usbnetErr, "usbcfg": usbcfgErr, "pdp_contexts": contextsErr, "active_contexts": activeErr, "pdp_addresses": addressesErr} {
		if err != nil {
			errors[name] = err.Error()
		}
	}
	interfaces := localInterfaces()
	writeJSON(response, http.StatusOK, map[string]any{
		"usbnet_mode": commandValue(usbnet, `+QCFG: "usbnet",`), "usbcfg": strings.TrimSpace(usbcfg),
		"pdp_contexts": parsePDPContexts(contexts), "active_contexts": parseActiveContexts(active),
		"pdp_addresses": parsePDPAddresses(addresses), "mac_interfaces": interfaces,
		"default_route": readDefaultRoute(), "usb_network_present": hasInterface(interfaces, "ecm0"),
		"usb_device": map[string]any{"vendor": "Quectel/Baiwang", "product": "QDC507", "vendor_id": "2c7c", "product_id": "0125", "mode": "CDC ECM"},
		"errors":     errors,
	})
}

func parsePDPContexts(response string) []map[string]any {
	result := []map[string]any{}
	for _, line := range strings.Split(response, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "+CGDCONT:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "+CGDCONT:")))
		if len(fields) >= 3 {
			result = append(result, map[string]any{"id": parseInt(fields[0]), "pdn": fields[1], "apn": fields[2]})
		}
	}
	return result
}

func parseActiveContexts(response string) []int {
	result := []int{}
	for _, line := range strings.Split(response, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "+CGACT:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "+CGACT:")))
		if len(fields) >= 2 && fields[1] == "1" {
			result = append(result, parseInt(fields[0]))
		}
	}
	return result
}

func parsePDPAddresses(response string) []string {
	result := []string{}
	for _, line := range strings.Split(response, "\n") {
		if value := commandValue(line, "+CGPADDR:"); value != "" {
			fields := splitCSV(value)
			if len(fields) >= 2 {
				result = append(result, strings.Trim(fields[1], `"`))
			}
		}
	}
	return result
}

func localInterfaces() []map[string]string {
	result := []map[string]string{}
	interfaces, _ := net.Interfaces()
	for _, item := range interfaces {
		status := "down"
		if item.Flags&net.FlagUp != 0 {
			status = "up"
		}
		ipv4 := ""
		addresses, _ := item.Addrs()
		for _, address := range addresses {
			ip, _, _ := net.ParseCIDR(address.String())
			if ip != nil && ip.To4() != nil {
				ipv4 = address.String()
				break
			}
		}
		result = append(result, map[string]string{"name": item.Name, "status": status, "ipv4": ipv4, "mac": item.HardwareAddr.String(), "kind": "module"})
	}
	return result
}

func hasInterface(interfaces []map[string]string, name string) bool {
	for _, item := range interfaces {
		if item["name"] == name {
			return true
		}
	}
	return false
}

func readDefaultRoute() map[string]string {
	file, err := os.Open("/proc/net/route")
	if err != nil {
		return map[string]string{}
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 3 || fields[1] != "00000000" {
			continue
		}
		value, err := strconv.ParseUint(fields[2], 16, 32)
		if err != nil {
			continue
		}
		bytes := make([]byte, 4)
		binary.LittleEndian.PutUint32(bytes, uint32(value))
		return map[string]string{"interface": fields[0], "gateway": net.IP(bytes).String()}
	}
	return map[string]string{}
}

func (a *agent) shutdown(response http.ResponseWriter, request *http.Request) {
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
		writeError(response, http.StatusBadRequest, "必须明确确认停止服务")
		return
	}
	writeJSON(response, http.StatusAccepted, map[string]bool{"stopping": true})
	go func() {
		time.Sleep(200 * time.Millisecond)
		_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
	}()
}
