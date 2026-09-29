package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

type smsMessage struct {
	Sender     string    `json:"sender"`
	Content    string    `json:"content"`
	Code       string    `json:"code,omitempty"`
	Timestamp  time.Time `json:"timestamp"`
	DeliveryID string    `json:"delivery_id,omitempty"`
}

type storedSMS struct {
	Index   int
	Memory  string
	Message smsMessage
}

type smsStorageRef struct {
	Memory string
	Index  int
}

var verificationCodePattern = regexp.MustCompile(`(?:^|[^0-9])([0-9]{4,8})(?:[^0-9]|$)`)

var smsStorageURCPattern = regexp.MustCompile(`(?i)^\+CMTI:\s*"(SM|ME)"\s*,\s*(\d+)\s*$`)

func parseSMSStorageURC(line string) (smsStorageRef, bool) {
	match := smsStorageURCPattern.FindStringSubmatch(strings.TrimSpace(line))
	if len(match) != 3 {
		return smsStorageRef{}, false
	}
	index, err := strconv.Atoi(match[2])
	if err != nil || index < 0 {
		return smsStorageRef{}, false
	}
	return smsStorageRef{Memory: strings.ToUpper(match[1]), Index: index}, true
}

func (a *agent) enqueueSMSNotice(notice smsStorageRef) {
	select {
	case a.smsNotices <- notice:
	default:
		a.mu.Lock()
		a.smsRescanRequested = true
		a.smsRescanRevision++
		a.mu.Unlock()
	}
}

func (a *agent) refreshRequestedSMSRescanIfIdle() {
	a.mu.RLock()
	requested := a.smsRescanRequested
	revision := a.smsRescanRevision
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	if !requested || callActive {
		return
	}
	a.refreshSMS()
	a.mu.Lock()
	if a.smsError == "" && a.smsRescanRevision == revision {
		a.smsRescanRequested = false
	}
	a.mu.Unlock()
}

func (a *agent) refreshSMSIfIdle() {
	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	if !callActive {
		a.refreshSMS()
	}
}

func (a *agent) refreshSMS() {
	items, err := a.readAllSMS()
	if err != nil {
		a.mu.Lock()
		a.smsError = err.Error()
		a.mu.Unlock()
		return
	}

	a.mergeSMS(items)
}

func (a *agent) mergeSMS(items []storedSMS) {
	a.mu.Lock()
	combined := append([]storedSMS(nil), a.messages...)
	newMessages := make([]smsMessage, 0, len(items))
	for _, item := range items {
		if !containsStoredSMS(combined, item) {
			combined = append(combined, item)
			newMessages = append(newMessages, item.Message)
		}
	}
	sort.SliceStable(combined, func(left, right int) bool {
		return combined[left].Message.Timestamp.After(combined[right].Message.Timestamp)
	})
	a.messages = combined
	a.smsError = ""
	if len(newMessages) > 0 {
		a.smsRevision++
		a.notifyAgentEventChangedLocked()
	}
	a.mu.Unlock()
	for _, message := range newMessages {
		a.scheduleSMSPush(message)
	}
}

func (a *agent) refreshStoredSMS(notice smsStorageRef) {
	if notice.Memory != "SM" && notice.Memory != "ME" {
		return
	}
	if _, err := a.at.command("AT+CMGF=1", 3*time.Second); err != nil {
		a.setSMSError(err)
		return
	}
	if _, err := a.at.command(`AT+CSCS="UCS2"`, 3*time.Second); err != nil {
		a.setSMSError(err)
		return
	}
	if _, err := a.at.command(fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, notice.Memory, notice.Memory, notice.Memory), 5*time.Second); err != nil {
		a.setSMSError(err)
		return
	}
	response, err := a.at.command(fmt.Sprintf("AT+CMGR=%d", notice.Index), 8*time.Second)
	if err != nil {
		a.setSMSError(err)
		return
	}
	// CMGR 与 CMGL 的字段布局仅相差记录索引，复用经过验证的文本模式解析器。
	response = strings.Replace(response, "+CMGR:", fmt.Sprintf("+CMGL: %d,", notice.Index), 1)
	a.mergeSMS(parseTextModeSMS(response, notice.Memory))
}

func (a *agent) setSMSError(err error) {
	a.mu.Lock()
	if err == nil {
		a.smsError = ""
	} else {
		a.smsError = err.Error()
	}
	a.mu.Unlock()
}

// containsStoredSMS 防止后台校准把同一条模块存储记录重复加入交付队列。
func containsStoredSMS(messages []storedSMS, candidate storedSMS) bool {
	for _, message := range messages {
		if message.Memory == candidate.Memory && message.Index == candidate.Index &&
			message.Message.DeliveryID == candidate.Message.DeliveryID {
			return true
		}
	}
	return false
}

func containsSMS(messages []smsMessage, candidate smsMessage) bool {
	for _, message := range messages {
		if message.Sender == candidate.Sender && message.Content == candidate.Content && message.Timestamp.Equal(candidate.Timestamp) {
			return true
		}
	}
	return false
}

func (a *agent) readAllSMS() ([]storedSMS, error) {
	if _, err := a.at.command("AT+CMGF=1", 3*time.Second); err != nil {
		return nil, formatError("切换短信文本模式", err)
	}
	if _, err := a.at.command(`AT+CSCS="UCS2"`, 3*time.Second); err != nil {
		return nil, formatError("切换短信 UCS2 字符集", err)
	}

	var result []storedSMS
	var failures []string
	for _, memory := range []string{"SM", "ME"} {
		if _, err := a.at.command(fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, memory, memory, memory), 5*time.Second); err != nil {
			failures = append(failures, memory+": "+err.Error())
			continue
		}
		response, err := a.at.command(`AT+CMGL="ALL"`, 8*time.Second)
		if err != nil {
			failures = append(failures, memory+": "+err.Error())
			continue
		}
		result = append(result, parseTextModeSMS(response, memory)...)
	}
	if len(result) == 0 && len(failures) == 2 {
		return nil, fmt.Errorf("读取短信失败: %s", strings.Join(failures, "; "))
	}
	return result, nil
}

func parseTextModeSMS(response, memory string) []storedSMS {
	lines := strings.Split(strings.ReplaceAll(response, "\r", ""), "\n")
	items := make([]storedSMS, 0)
	for index := 0; index < len(lines); index++ {
		header := strings.TrimSpace(lines[index])
		if !strings.HasPrefix(header, "+CMGL:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(header, "+CMGL:")))
		if len(fields) < 3 {
			continue
		}
		messageIndex, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		sender := decodeMaybeUCS2(fields[2])
		timestamp := time.Now()
		for fieldIndex := len(fields) - 1; fieldIndex >= 3; fieldIndex-- {
			if parsed, ok := parseSMSTimestamp(decodeMaybeUCS2(fields[fieldIndex])); ok {
				timestamp = parsed
				break
			}
		}
		body := ""
		if index+1 < len(lines) {
			candidate := strings.TrimSpace(lines[index+1])
			if candidate != "OK" && !strings.HasPrefix(candidate, "+CMGL:") {
				body = decodeMaybeUCS2(candidate)
				index++
			}
		}
		code := ""
		if match := verificationCodePattern.FindStringSubmatch(body); len(match) == 2 {
			code = match[1]
		}
		message := smsMessage{
			Sender: sender, Content: body, Code: code, Timestamp: timestamp,
		}
		// 交付 ID 只用于手机落盘后的确认，不参与用户可见的短信去重。
		digest := sha256.Sum256([]byte(sender + "\x00" + body))
		message.DeliveryID = fmt.Sprintf("%s-%d-%x", memory, messageIndex, digest[:8])
		items = append(items, storedSMS{Index: messageIndex, Memory: memory, Message: message})
	}
	return items
}

func decodeMaybeUCS2(value string) string {
	value = strings.Trim(strings.TrimSpace(value), `"`)
	if value == "" || len(value)%4 != 0 {
		return value
	}
	raw, err := hex.DecodeString(value)
	if err != nil || len(raw)%2 != 0 {
		return value
	}
	units := make([]uint16, 0, len(raw)/2)
	for index := 0; index < len(raw); index += 2 {
		units = append(units, uint16(raw[index])<<8|uint16(raw[index+1]))
	}
	decoded := string(utf16.Decode(units))
	if strings.ContainsRune(decoded, '\uFFFD') {
		return value
	}
	return decoded
}

func encodeUCS2(value string) string {
	units := utf16.Encode([]rune(value))
	raw := make([]byte, 0, len(units)*2)
	for _, unit := range units {
		raw = append(raw, byte(unit>>8), byte(unit))
	}
	return strings.ToUpper(hex.EncodeToString(raw))
}

func splitUCS2(value string, limit int) []string {
	if limit <= 0 {
		return nil
	}
	var result []string
	var current []rune
	units := 0
	for _, character := range []rune(value) {
		width := len(utf16.Encode([]rune{character}))
		if units+width > limit && len(current) > 0 {
			result = append(result, string(current))
			current = nil
			units = 0
		}
		current = append(current, character)
		units += width
	}
	if len(current) > 0 {
		result = append(result, string(current))
	}
	return result
}

func parseSMSTimestamp(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	match := regexp.MustCompile(`^(\d{2})/(\d{2})/(\d{2}),(\d{2}):(\d{2}):(\d{2})([+-])(\d{2})$`).FindStringSubmatch(value)
	if len(match) != 9 {
		return time.Time{}, false
	}
	numbers := make([]int, 6)
	for index := range numbers {
		numbers[index], _ = strconv.Atoi(match[index+1])
	}
	quarters, _ := strconv.Atoi(match[8])
	offset := quarters * 15 * 60
	if match[7] == "-" {
		offset = -offset
	}
	zone := time.FixedZone("SMS", offset)
	return time.Date(2000+numbers[0], time.Month(numbers[1]), numbers[2], numbers[3], numbers[4], numbers[5], 0, zone), true
}

func (a *agent) smsList(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	stored := append([]storedSMS(nil), a.messages...)
	a.mu.RUnlock()
	messages := make([]smsMessage, 0, len(stored))
	for _, item := range stored {
		messages = append(messages, item.Message)
	}
	if messages == nil {
		messages = []smsMessage{}
	}
	writeJSON(response, http.StatusOK, messages)
}

func (a *agent) smsStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	count, lastError := len(a.messages), a.smsError
	a.mu.RUnlock()
	writeJSON(response, http.StatusOK, map[string]any{
		"auto_cleanup_me": true, "count": count, "last_poll_error": lastError,
	})
}

func (a *agent) smsSend(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Phone   string `json:"phone"`
		Message string `json:"message"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	segments, err := a.sendSMSMessage(body.Phone, body.Message)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{"sent": true, "segments": segments})
}

func (a *agent) sendSMSMessage(rawPhone, message string) (int, error) {
	phone := normalizeDialNumber(rawPhone)
	if phone == "" || len(phone) > 82 || strings.TrimSpace(message) == "" || len([]rune(message)) > 2000 {
		return 0, errors.New("号码或短信内容无效")
	}
	segments := splitUCS2(message, 70)
	if len(segments) == 0 {
		return 0, errors.New("短信内容为空")
	}
	if a.profile.AndroidTelecom {
		commandID, err := randomUUID()
		if err != nil {
			return 0, fmt.Errorf("create Android SMS command: %w", err)
		}
		result := a.android.execute(context.Background(), androidCommand{
			ID: commandID, Action: "send_sms", Number: phone, Message: message,
		}, 60*time.Second)
		if !result.Success {
			return 0, errors.New(result.Error)
		}
		if result.Segments <= 0 {
			return len(segments), nil
		}
		return result.Segments, nil
	}
	if _, err := a.at.command("AT+CMGF=1", 3*time.Second); err != nil {
		return 0, err
	}
	for _, command := range []string{`AT+CSCS="UCS2"`, "AT+CSMP=17,167,0,8"} {
		if _, err := a.at.command(command, 3*time.Second); err != nil {
			return 0, err
		}
	}
	for index, segment := range segments {
		payload := append([]byte(encodeUCS2(segment)), 0x1a)
		if _, err := a.at.promptCommand(`AT+CMGS="`+encodeUCS2(phone)+`"`, payload, 45*time.Second); err != nil {
			return 0, fmt.Errorf("发送第 %d/%d 段失败: %v", index+1, len(segments), err)
		}
	}
	return len(segments), nil
}

func (a *agent) smsRefresh(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if !a.profile.AndroidTelecom {
		a.refreshSMS()
	}
	a.mu.RLock()
	lastError, count := a.smsError, len(a.messages)
	a.mu.RUnlock()
	if lastError != "" {
		writeError(response, http.StatusBadGateway, lastError)
		return
	}
	writeJSON(response, http.StatusAccepted, map[string]any{"accepted": true, "count": count})
}

// smsAck 在手机确认本地 JSON 已原子写入后，才删除对应的 SIM/ME 短信和内存交付项。
func (a *agent) smsAck(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		IDs []string `json:"ids"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	requested := make(map[string]bool, len(body.IDs))
	for _, id := range body.IDs {
		if id != "" {
			requested[id] = true
		}
	}

	a.mu.RLock()
	pending := append([]storedSMS(nil), a.messages...)
	a.mu.RUnlock()
	succeeded := make(map[string]bool)
	var failures []string
	for _, item := range pending {
		id := item.Message.DeliveryID
		if !requested[id] {
			continue
		}
		if err := a.deleteStoredSMS(item); err != nil {
			failures = append(failures, id+": "+err.Error())
			continue
		}
		succeeded[id] = true
	}

	a.mu.Lock()
	remaining := a.messages[:0]
	for _, item := range a.messages {
		if !succeeded[item.Message.DeliveryID] {
			remaining = append(remaining, item)
		}
	}
	a.messages = remaining
	a.mu.Unlock()
	if len(failures) > 0 {
		writeError(response, http.StatusBadGateway, "删除已交付模块短信失败: "+strings.Join(failures, "; "))
		return
	}
	writeJSON(response, http.StatusOK, map[string]int{"acknowledged": len(succeeded)})
}

func (a *agent) deleteStoredSMS(item storedSMS) error {
	if item.Memory == "ANDROID" {
		return nil
	}
	if item.Memory != "SM" && item.Memory != "ME" {
		return fmt.Errorf("未知短信存储区 %q", item.Memory)
	}
	if _, err := a.at.command(fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, item.Memory, item.Memory, item.Memory), 5*time.Second); err != nil {
		return err
	}
	_, err := a.at.command(fmt.Sprintf("AT+CMGD=%d", item.Index), 5*time.Second)
	return err
}

func (a *agent) smsSettings(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPatch) {
		return
	}
	var body struct {
		AutoCleanup *bool `json:"auto_cleanup_me"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.AutoCleanup == nil {
		writeError(response, http.StatusBadRequest, "缺少 auto_cleanup_me")
		return
	}
	// 新协议始终在手机确认落盘后清理，旧客户端的开关请求只保留兼容响应。
	a.mu.Lock()
	a.smsAuto = true
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]bool{"auto_cleanup_me": true})
}

func (a *agent) smsClear(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if a.profile.AndroidTelecom {
		a.mu.Lock()
		totalBefore := len(a.messages)
		a.messages = nil
		a.mu.Unlock()
		writeJSON(response, http.StatusOK, map[string]any{"cleared": true, "before": totalBefore, "after": 0})
		return
	}
	totalBefore := 0
	for _, memory := range []string{"SM", "ME"} {
		selectResponse, err := a.at.command(fmt.Sprintf(`AT+CPMS="%s","%s","%s"`, memory, memory, memory), 5*time.Second)
		if err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
		totalBefore += parseCPMSUsed(selectResponse)
		if _, err := a.at.command("AT+CMGD=1,4", 20*time.Second); err != nil {
			writeError(response, http.StatusBadGateway, err.Error())
			return
		}
	}
	a.mu.Lock()
	a.messages = nil
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{"cleared": true, "before": totalBefore, "after": 0})
}

func parseCPMSUsed(response string) int {
	match := regexp.MustCompile(`\+CPMS:\s*(\d+)`).FindStringSubmatch(response)
	if len(match) != 2 {
		return 0
	}
	value, _ := strconv.Atoi(match[1])
	return value
}

func (a *agent) simIdentity(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	result, err := a.at.command("AT+CNUM", 3*time.Second)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]string{"phone_number": parseCNUM(result)})
}

func parseCNUM(response string) string {
	for _, line := range strings.Split(response, "\n") {
		if !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(line)), "+CNUM:") {
			continue
		}
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "+CNUM:")))
		if len(fields) >= 2 {
			return decodeMaybeUCS2(fields[1])
		}
	}
	return ""
}
