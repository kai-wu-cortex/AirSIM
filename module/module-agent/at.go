package main

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
)

// atPort 串行化所有基带请求。SMD AT 通道不支持并发交错命令。
type atPort struct {
	path         string
	mu           sync.Mutex
	file         *os.File
	urcHandler   func(string)
	onReopen     func()
	debugHandler func(string, string, string)
	urcPending   []byte
	monitorOnce  sync.Once
	healthMu     sync.RWMutex
	health       atPortHealth
	openedOnce   bool
}

type atPortHealth struct {
	LastSuccess         time.Time
	ConsecutiveFailures int
	ReopenCount         int
}

func newATPort(path string) *atPort {
	return &atPort{path: path}
}

func atOpenFlags() int {
	// system/update 会派生启动脚本；禁止脚本及监督器继承独占的 DATA11 fd，
	// 否则旧 Agent 退出后新 Agent 会持续收到 EBUSY。
	return syscall.O_RDWR | syscall.O_NONBLOCK | syscall.O_CLOEXEC
}

func (p *atPort) setURCHandler(handler func(string)) {
	p.mu.Lock()
	p.urcHandler = handler
	p.mu.Unlock()
}

func (p *atPort) setReopenHandler(handler func()) {
	p.mu.Lock()
	p.onReopen = handler
	p.mu.Unlock()
}

func (p *atPort) setDebugHandler(handler func(direction, summary, payload string)) {
	p.mu.Lock()
	p.debugHandler = handler
	p.mu.Unlock()
}

func (p *atPort) debug(direction, summary, payload string) {
	if p.debugHandler != nil {
		p.debugHandler(direction, summary, payload)
	}
}

func (p *atPort) healthSnapshot() atPortHealth {
	p.healthMu.RLock()
	defer p.healthMu.RUnlock()
	return p.health
}

// startURCMonitor 在没有同步命令占用端口时持续收取异步事件。
// TryLock 保证它不会读取属于 AT 命令、短信提示符或 eSIM APDU 的响应。
func (p *atPort) startURCMonitor() {
	p.monitorOnce.Do(func() {
		go func() {
			ticker := time.NewTicker(50 * time.Millisecond)
			defer ticker.Stop()
			for range ticker.C {
				if !p.mu.TryLock() {
					continue
				}
				p.harvestPendingURCs()
				p.mu.Unlock()
			}
		}()
	})
}

func (p *atPort) open() error {
	if p.file != nil {
		return nil
	}
	fd, err := syscall.Open(p.path, atOpenFlags(), 0)
	if err != nil {
		return fmt.Errorf("打开 AT 端口失败: %w", err)
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		_ = syscall.Close(fd)
		return fmt.Errorf("设置 AT 端口非阻塞模式失败: %w", err)
	}
	p.file = os.NewFile(uintptr(fd), p.path)
	reopened := p.openedOnce
	p.healthMu.Lock()
	if reopened {
		p.health.ReopenCount++
	}
	p.openedOnce = true
	p.healthMu.Unlock()
	if reopened && p.onReopen != nil {
		p.onReopen()
	}
	return nil
}

func (p *atPort) close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closeLocked()
}

func (p *atPort) closeLocked() error {
	if p.file == nil {
		return nil
	}
	err := p.file.Close()
	p.file = nil
	p.urcPending = nil
	return err
}

// command 发送普通 AT 指令并等待 OK/ERROR 终止行。
func (p *atPort) command(command string, timeout time.Duration) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.open(); err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		return "", err
	}
	if strings.ContainsAny(command, "\r\n\x00") {
		return "", errors.New("AT 指令包含非法控制字符")
	}
	isCCHO := strings.HasPrefix(command, "AT+CCHO=")
	if isCCHO {
		log.Printf("AT CCHO 阶段: 端口已打开")
	}
	p.harvestPendingURCs()
	if isCCHO {
		log.Printf("AT CCHO 阶段: 缓冲已清理")
	}
	if err := p.writeAll([]byte(command+"\r"), 5*time.Second); err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		_ = p.closeLocked()
		return "", fmt.Errorf("写入 AT 指令失败: %w", err)
	}
	if isCCHO {
		log.Printf("AT CCHO 阶段: 指令已写入")
	}
	p.debug("tx", command, command)
	response, err := p.readUntil(timeout, func(buffer []byte) bool {
		return hasTerminalResult(buffer)
	})
	if err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		_ = p.closeLocked()
		return string(response), err
	}
	if isCCHO {
		log.Printf("AT CCHO 阶段: 已收到终止响应")
	}
	text := normalizeATText(response)
	if hasATError(text) {
		p.recordSuccess()
		p.debug("error", command, text)
		return text, fmt.Errorf("AT 指令失败: %s", lastNonEmptyLine(text))
	}
	p.recordSuccess()
	return text, nil
}

// promptCommand 处理 AT+CMGS 这类先返回提示符、再接收载荷的交互命令。
func (p *atPort) promptCommand(command string, payload []byte, timeout time.Duration) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.open(); err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		return "", err
	}
	p.harvestPendingURCs()
	if err := p.writeAll([]byte(command+"\r"), 5*time.Second); err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		_ = p.closeLocked()
		return "", err
	}
	p.debug("tx", command, command)
	prompt, err := p.readUntil(5*time.Second, func(buffer []byte) bool {
		return bytes.Contains(buffer, []byte(">")) || hasTerminalResult(buffer)
	})
	if err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		_ = p.closeLocked()
		return string(prompt), fmt.Errorf("等待短信输入提示符失败: %w", err)
	}
	if !bytes.Contains(prompt, []byte(">")) {
		p.recordSuccess()
		p.debug("error", command, normalizeATText(prompt))
		return normalizeATText(prompt), errors.New("模块未返回短信输入提示符")
	}
	if err := p.writeAll(payload, 10*time.Second); err != nil {
		p.recordFailure()
		p.debug("error", command+" payload", err.Error())
		_ = p.closeLocked()
		return "", err
	}
	p.debug("tx", command+" payload", string(payload))
	response, err := p.readUntil(timeout, func(buffer []byte) bool {
		return hasTerminalResult(buffer)
	})
	text := normalizeATText(response)
	if err != nil {
		p.recordFailure()
		p.debug("error", command, err.Error())
		_ = p.closeLocked()
		return text, err
	}
	if hasATError(text) {
		p.recordSuccess()
		p.debug("error", command, text)
		return text, fmt.Errorf("短信发送失败: %s", lastNonEmptyLine(text))
	}
	p.recordSuccess()
	return text, nil
}

func (p *atPort) recordSuccess() {
	p.healthMu.Lock()
	p.health.LastSuccess = time.Now()
	p.health.ConsecutiveFailures = 0
	p.healthMu.Unlock()
}

func (p *atPort) recordFailure() {
	p.healthMu.Lock()
	p.health.ConsecutiveFailures++
	p.healthMu.Unlock()
}

// probeATWithRecovery keeps DATA11 awake with the cheapest possible command.
// command closes a timed-out descriptor, so the second attempt necessarily
// reopens the SMD port instead of continuing on the stale file descriptor.
func probeATWithRecovery(command func(string, time.Duration) (string, error)) error {
	if _, err := command("AT", 2*time.Second); err == nil {
		return nil
	}
	_, err := command("AT", 3*time.Second)
	return err
}

// writeAll 直接使用非阻塞 fd 写入，并给字符设备背压设置硬截止时间。
func (p *atPort) writeAll(payload []byte, timeout time.Duration) error {
	if p.file == nil {
		return errors.New("AT 端口尚未打开")
	}
	deadline := time.Now().Add(timeout)
	for len(payload) > 0 {
		written, err := syscall.Write(int(p.file.Fd()), payload)
		if written > 0 {
			payload = payload[written:]
			continue
		}
		if err != nil && !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EWOULDBLOCK) {
			return err
		}
		if time.Now().After(deadline) {
			return errors.New("等待 AT 端口可写超时")
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil
}

func (p *atPort) readUntil(timeout time.Duration, complete func([]byte) bool) ([]byte, error) {
	deadline := time.Now().Add(timeout)
	buffer := make([]byte, 0, 4096)
	temporary := make([]byte, 1024)
	for time.Now().Before(deadline) {
		count, err := syscall.Read(int(p.file.Fd()), temporary)
		if count > 0 {
			buffer = append(buffer, temporary[:count]...)
			p.debug("rx", "AT receive", string(temporary[:count]))
			p.urcPending = p.dispatchCompleteURCLines(p.urcPending, temporary[:count])
			if len(buffer) > 256*1024 {
				return buffer, errors.New("AT 响应超过安全上限")
			}
			if complete(buffer) {
				return buffer, nil
			}
		}
		if err != nil && !errors.Is(err, syscall.EAGAIN) && !errors.Is(err, syscall.EWOULDBLOCK) {
			return buffer, fmt.Errorf("读取 AT 响应失败: %w", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	return buffer, errors.New("等待 AT 响应超时")
}

// harvestPendingURCs 清走上次命令的终止残留，但先交付其中的异步事件。
// SMD 端口可能持续输出 URC，因此同时限制时间和字节数，不能等待“绝对安静”。
func (p *atPort) harvestPendingURCs() {
	if p.file == nil {
		return
	}
	temporary := make([]byte, 1024)
	deadline := time.Now().Add(100 * time.Millisecond)
	drained := 0
	for time.Now().Before(deadline) && drained < 64*1024 {
		count, err := syscall.Read(int(p.file.Fd()), temporary)
		drained += count
		if count > 0 {
			p.debug("rx", "AT idle receive", string(temporary[:count]))
			p.urcPending = p.dispatchCompleteURCLines(p.urcPending, temporary[:count])
		}
		if count == 0 || err != nil {
			return
		}
	}
}

func (p *atPort) dispatchCompleteURCLines(pending, chunk []byte) []byte {
	pending = append(pending, chunk...)
	start := 0
	for index, value := range pending {
		if value != '\r' && value != '\n' {
			continue
		}
		if index > start {
			p.dispatchURC(strings.TrimSpace(string(pending[start:index])))
		}
		start = index + 1
	}
	if start == 0 {
		if len(pending) > 4096 {
			return pending[len(pending)-4096:]
		}
		return pending
	}
	return append(pending[:0], pending[start:]...)
}

func (p *atPort) dispatchURC(line string) {
	if line == "" || p.urcHandler == nil || !isURCLine(line) {
		return
	}
	p.debug("urc", "AT unsolicited result", line)
	p.urcHandler(line)
}

func isURCLine(line string) bool {
	upper := strings.ToUpper(strings.TrimSpace(line))
	return upper == "RING" || strings.HasPrefix(upper, "+CRING:") ||
		strings.HasPrefix(upper, "+CLIP:") || strings.HasPrefix(upper, "^DSCI:") ||
		strings.HasPrefix(upper, "+CMTI:") || strings.HasPrefix(upper, "+CEREG:") ||
		strings.HasPrefix(upper, "+CREG:") || strings.HasPrefix(upper, "+QSIMSTAT:")
}

func hasTerminalResult(buffer []byte) bool {
	normalized := strings.ReplaceAll(string(buffer), "\r", "")
	return strings.Contains(normalized, "\nOK\n") ||
		strings.Contains(normalized, "\nERROR\n") ||
		strings.Contains(normalized, "\n+CME ERROR:") ||
		strings.Contains(normalized, "\n+CMS ERROR:")
}

func normalizeATText(value []byte) string {
	text := strings.ReplaceAll(string(value), "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	lines := strings.Split(text, "\n")
	clean := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" {
			clean = append(clean, line)
		}
	}
	return strings.Join(clean, "\n")
}

func hasATError(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		if line == "ERROR" || strings.HasPrefix(line, "+CME ERROR:") || strings.HasPrefix(line, "+CMS ERROR:") {
			return true
		}
	}
	return false
}

func lastNonEmptyLine(text string) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) == 0 {
		return "未知错误"
	}
	return lines[len(lines)-1]
}
