package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	usbCarrierPath           = "/sys/class/net/ecm0/carrier"
	usbRebindStampPath       = "/run/airsim-usb-rebind.uptime"
	usbGadgetRebindStampPath = "/run/airsim-ecm-gadget-rebind.uptime"
	usbLinkDebounce          = 10 * time.Second
	usbCarrierPollInterval   = time.Second
	usbRebindMinimumSpacing  = 5 * time.Minute
	usbBlockedRetryDelay     = 15 * time.Second
	usbVerifyRetryDelay      = 5 * time.Second
)

type ecmLinkState uint8

const (
	ecmLinkUnknown ecmLinkState = iota
	ecmLinkUp
	ecmLinkCarrierDown
	ecmLinkMissing
)

func detectECMLinkState(carrier []byte, err error) ecmLinkState {
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ecmLinkMissing
		}
		return ecmLinkUnknown
	}
	switch strings.TrimSpace(string(carrier)) {
	case "1":
		return ecmLinkUp
	case "0":
		return ecmLinkCarrierDown
	default:
		return ecmLinkUnknown
	}
}

type usbRebindOutcome struct {
	Retry      bool
	RetryAfter time.Duration
	Reason     string
}

func usbCooldownOutcome(uptime, last int64, spacing time.Duration) usbRebindOutcome {
	elapsed := time.Duration(uptime-last) * time.Second
	remaining := spacing - elapsed
	if remaining < time.Second {
		remaining = time.Second
	}
	return usbRebindOutcome{Retry: true, RetryAfter: remaining, Reason: "USB 重绑冷却中"}
}

func usbBlockedOutcome(reason string) usbRebindOutcome {
	return usbRebindOutcome{Retry: true, RetryAfter: usbBlockedRetryDelay, Reason: reason}
}

func usbFailureOutcome(reason string) usbRebindOutcome {
	return usbRebindOutcome{Retry: true, RetryAfter: usbBlockedRetryDelay, Reason: reason}
}

func validateUSBSoftwareReconnect(callActive, voiceActive bool, functions string) error {
	if callActive {
		return errors.New("通话进行中")
	}
	if voiceActive {
		return errors.New("媒体路由运行中")
	}
	tokens := map[string]bool{}
	for _, token := range strings.Split(functions, ",") {
		tokens[strings.TrimSpace(token)] = true
	}
	if !tokens["ecm"] {
		return errors.New("USB 组合缺少 ECM")
	}
	if tokens["serial"] || tokens["audio"] {
		return errors.New("Mac/USB 音频组合禁止软件重连")
	}
	return nil
}

// A missing ECM netdev is different from a carrier-only failure: the USB
// function has already disappeared, so reloading the exact active composite is
// the recovery path. Keep the call/media safety gates, but do not reject the
// normal iPhone composite merely because it also contains serial or audio.
func validateMissingECMGadgetRecovery(callActive, voiceActive bool, functions string) error {
	if callActive {
		return errors.New("通话进行中")
	}
	if voiceActive {
		return errors.New("媒体路由运行中")
	}
	tokens := map[string]bool{}
	for _, token := range strings.Split(functions, ",") {
		tokens[strings.TrimSpace(token)] = true
	}
	if !tokens["ecm"] {
		return errors.New("USB 组合缺少 ECM")
	}
	return nil
}

type usbReconnectDebouncer struct {
	agent     *agent
	logger    *log.Logger
	debounce  time.Duration
	reconnect func() usbRebindOutcome
	recover   func(ecmLinkState) usbRebindOutcome
	mu        sync.Mutex
	timer     *time.Timer
	down      bool
	state     ecmLinkState
}

func newUSBReconnectDebouncer(agent *agent, logger *log.Logger) *usbReconnectDebouncer {
	return &usbReconnectDebouncer{
		agent: agent, logger: logger, debounce: usbLinkDebounce,
		recover: func(state ecmLinkState) usbRebindOutcome {
			switch state {
			case ecmLinkMissing:
				return agent.tryMissingECMGadgetRecovery(logger, "ecm-interface-missing-10s")
			case ecmLinkCarrierDown:
				return agent.tryECMLinkPowerCycle(logger, "ecm-carrier-down-10s")
			default:
				return usbRebindOutcome{}
			}
		},
	}
}

func (d *usbReconnectDebouncer) carrierChanged(down bool) {
	state := ecmLinkUp
	if down {
		state = ecmLinkCarrierDown
	}
	d.linkStateChanged(state)
}

func (d *usbReconnectDebouncer) linkStateChanged(state ecmLinkState) {
	if state == ecmLinkUnknown {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	wasDown := d.down
	d.state = state
	d.down = state != ecmLinkUp
	if !d.down {
		if d.timer != nil {
			d.timer.Stop()
			d.timer = nil
		}
		if wasDown {
			d.agent.debug.add("usb", "event", "ecm0 carrier recovered", "", nil)
			d.agent.recordECMWatchdogEvent(ecmLinkUp, "carrier-recovered", "ecm0 carrier=1")
			d.agent.recordUSBFault("carrier-recovered", "netlink", "ecm0 carrier=1")
		}
		return
	}
	if d.timer != nil {
		return
	}
	summary := "ecm0 carrier down; debounce started"
	reason := "ecm0 carrier=0"
	phase := "carrier-down"
	if state == ecmLinkMissing {
		summary = "ecm0 interface missing; debounce started"
		reason = "ecm0 netdev missing"
		phase = "ecm-missing"
	}
	d.agent.debug.add("usb", "event", summary, "", map[string]string{
		"debounce": d.debounce.String(), "state": phase,
	})
	d.agent.recordECMWatchdogEvent(state, phase, reason)
	d.agent.recordUSBFault(phase, "monitor", reason)
	d.scheduleLocked(d.debounce)
}

func (d *usbReconnectDebouncer) scheduleLocked(delay time.Duration) {
	if delay <= 0 {
		delay = time.Second
	}
	d.timer = time.AfterFunc(delay, func() {
		d.mu.Lock()
		d.timer = nil
		if !d.down {
			d.mu.Unlock()
			return
		}
		state := d.state
		d.mu.Unlock()
		var outcome usbRebindOutcome
		if d.recover != nil {
			outcome = d.recover(state)
		} else {
			outcome = d.reconnect()
		}
		d.agent.recordECMWatchdogEvent(state, "recovery-attempt", outcome.Reason)
		if !outcome.Retry {
			return
		}
		d.mu.Lock()
		defer d.mu.Unlock()
		if d.down && d.timer == nil {
			d.agent.debug.add("usb", "event", "USB recovery retry scheduled", "", map[string]string{
				"after": outcome.RetryAfter.String(), "reason": outcome.Reason,
			})
			d.scheduleLocked(outcome.RetryAfter)
		}
	})
}

// pollECMCarrier is the fallback for kernels or USB transitions that do not
// deliver a usable RTM_NEWLINK event. It reports the initial state and later
// transitions; the shared debouncer guarantees that polling and netlink cannot
// start duplicate recovery timers.
func pollECMCarrier(
	ctx context.Context,
	interval time.Duration,
	readCarrier func() (down bool, err error),
	changed func(down bool),
) {
	if interval <= 0 {
		interval = time.Second
	}
	var previous bool
	havePrevious := false
	poll := func() {
		down, err := readCarrier()
		if err != nil {
			return
		}
		if !havePrevious || down != previous {
			previous = down
			havePrevious = true
			changed(down)
		}
	}
	poll()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			poll()
		}
	}
}

func pollECMLinkState(
	ctx context.Context,
	interval time.Duration,
	probe func() ecmLinkState,
	changed func(ecmLinkState),
) {
	if interval <= 0 {
		interval = time.Second
	}
	previous := ecmLinkUnknown
	poll := func() {
		state := probe()
		if state == ecmLinkUnknown || state == previous {
			return
		}
		previous = state
		changed(state)
	}
	poll()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			poll()
		}
	}
}

func powerCycleECMLink(run func(string, ...string) error, sleep func(time.Duration)) error {
	if err := run("ifconfig", "ecm0", "down"); err != nil {
		return fmt.Errorf("关闭 ecm0 失败: %w", err)
	}
	sleep(time.Second)
	if err := run("ifconfig", "ecm0", "up"); err != nil {
		return fmt.Errorf("恢复 ecm0 失败: %w", err)
	}
	return nil
}

func rebindMissingECMGadget(
	enabled, functions string,
	write func(path, value string) error,
	sleep func(time.Duration),
) error {
	enabled = strings.TrimSpace(enabled)
	functions = strings.TrimSpace(functions)
	if enabled != "0" && enabled != "1" {
		return fmt.Errorf("USB gadget enable 状态无效: %q", enabled)
	}
	hasECM := false
	for _, token := range strings.Split(functions, ",") {
		if strings.TrimSpace(token) == "ecm" {
			hasECM = true
			break
		}
	}
	if !hasECM {
		return errors.New("USB 组合缺少 ECM")
	}

	disabledHere := enabled == "1"
	if disabledHere {
		if err := write(usbGadgetPath+"/enable", "0\n"); err != nil {
			return fmt.Errorf("停用 USB gadget 失败: %w", err)
		}
		sleep(time.Second)
	}
	if err := write(usbGadgetPath+"/functions", functions+"\n"); err != nil {
		if disabledHere {
			_ = write(usbGadgetPath+"/enable", "1\n")
		}
		return fmt.Errorf("重新装载 ECM function 失败: %w", err)
	}
	if err := write(usbGadgetPath+"/enable", "1\n"); err != nil {
		return fmt.Errorf("启用 USB gadget 失败: %w", err)
	}
	return nil
}

func (a *agent) tryMissingECMGadgetRecovery(logger *log.Logger, trigger string) usbRebindOutcome {
	if _, err := os.Stat(usbCarrierPath); err == nil {
		a.recordUSBFault("carrier-recovered", trigger, "ecm0 netdev 已恢复")
		return usbRebindOutcome{}
	} else if !errors.Is(err, os.ErrNotExist) {
		reason := "检查 ecm0 netdev 失败: " + err.Error()
		a.recordUSBFault("gadget-rebind-deferred", trigger, reason)
		return usbFailureOutcome(reason)
	}

	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	a.voice.mu.Lock()
	voiceActive := a.voice.command != nil || a.voice.routeCommand != nil ||
		a.voice.mediaRouteStarted || a.voice.stopping
	a.voice.mu.Unlock()
	functionsData, functionsErr := os.ReadFile(usbGadgetPath + "/functions")
	enabledData, enabledErr := os.ReadFile(usbGadgetPath + "/enable")
	if functionsErr != nil || enabledErr != nil {
		reason := fmt.Sprintf("USB gadget 状态不可读: functions=%v enable=%v", functionsErr, enabledErr)
		a.recordUSBFault("gadget-rebind-deferred", trigger, reason)
		return usbFailureOutcome(reason)
	}
	functions := strings.TrimSpace(string(functionsData))
	if err := validateMissingECMGadgetRecovery(callActive, voiceActive, functions); err != nil {
		a.debug.add("usb", "event", "ECM gadget recovery skipped", "", map[string]string{"reason": err.Error()})
		a.recordUSBFault("gadget-rebind-deferred", trigger, err.Error())
		return usbBlockedOutcome(err.Error())
	}

	uptime, err := systemUptimeSeconds()
	if err != nil {
		a.recordUSBFault("gadget-rebind-deferred", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}
	if stamp, readErr := os.ReadFile(usbGadgetRebindStampPath); readErr == nil {
		last, parseErr := strconv.ParseInt(strings.TrimSpace(string(stamp)), 10, 64)
		if parseErr == nil && time.Duration(uptime-last)*time.Second < usbRebindMinimumSpacing {
			outcome := usbCooldownOutcome(uptime, last, usbRebindMinimumSpacing)
			a.recordUSBFault("gadget-rebind-deferred", trigger, outcome.Reason)
			return outcome
		}
	}
	if err := os.WriteFile(usbGadgetRebindStampPath, []byte(strconv.FormatInt(uptime, 10)+"\n"), 0o600); err != nil {
		a.recordUSBFault("gadget-rebind-deferred", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}

	fields := map[string]string{"trigger": trigger, "functions": functions, "scope": "android-usb-gadget"}
	a.debug.add("usb", "event", "Missing ECM gadget recovery started", "", fields)
	a.recordUSBFault("gadget-rebind-start", trigger, "ecm0 missing; reloading existing ECM function")
	appendVoiceSystemSnapshot("ecm-gadget-rebind-before")
	write := func(path, value string) error {
		if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
			return fmt.Errorf("写入 %s 失败: %w", path, err)
		}
		return nil
	}
	if err := rebindMissingECMGadget(string(enabledData), functions, write, time.Sleep); err != nil {
		logger.Printf("ECM gadget 重新装载失败: %v", err)
		a.recordUSBFault("gadget-rebind-failed", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}
	a.debug.add("usb", "event", "Missing ECM gadget recovery completed", "", fields)
	appendVoiceSystemSnapshot("ecm-gadget-rebind-after")
	a.recordUSBFault("gadget-rebind-complete", trigger, "ECM function reloaded; waiting for ecm0")
	return usbRebindOutcome{Retry: true, RetryAfter: usbVerifyRetryDelay, Reason: "验证 ecm0 是否重新出现"}
}

func (a *agent) tryECMLinkPowerCycle(logger *log.Logger, trigger string) usbRebindOutcome {
	carrier, err := os.ReadFile(usbCarrierPath)
	if err != nil {
		reason := "读取 ecm0 carrier 失败: " + err.Error()
		a.recordUSBFault("rebind-deferred", trigger, reason)
		return usbFailureOutcome(reason)
	}
	if strings.TrimSpace(string(carrier)) != "0" {
		a.recordUSBFault("carrier-recovered", trigger, "ecm0 carrier 已恢复")
		return usbRebindOutcome{}
	}

	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	a.voice.mu.Lock()
	voiceActive := a.voice.command != nil || a.voice.routeCommand != nil ||
		a.voice.mediaRouteStarted || a.voice.stopping
	a.voice.mu.Unlock()
	functionsData, err := os.ReadFile(usbGadgetPath + "/functions")
	if err != nil {
		a.debug.add("usb", "event", "USB software rebind skipped", "", map[string]string{"reason": err.Error()})
		a.recordUSBFault("rebind-deferred", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}
	functions := strings.TrimSpace(string(functionsData))
	if err := validateUSBSoftwareReconnect(callActive, voiceActive, functions); err != nil {
		a.debug.add("usb", "event", "USB software rebind skipped", "", map[string]string{"reason": err.Error()})
		a.recordUSBFault("rebind-deferred", trigger, err.Error())
		return usbBlockedOutcome(err.Error())
	}

	uptime, err := systemUptimeSeconds()
	if err != nil {
		a.debug.add("usb", "event", "USB software rebind skipped", "", map[string]string{"reason": err.Error()})
		a.recordUSBFault("rebind-deferred", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}
	if stamp, readErr := os.ReadFile(usbRebindStampPath); readErr == nil {
		last, parseErr := strconv.ParseInt(strings.TrimSpace(string(stamp)), 10, 64)
		if parseErr == nil && time.Duration(uptime-last)*time.Second < usbRebindMinimumSpacing {
			outcome := usbCooldownOutcome(uptime, last, usbRebindMinimumSpacing)
			a.recordUSBFault("rebind-deferred", trigger, outcome.Reason)
			return outcome
		}
	}
	if err := os.WriteFile(usbRebindStampPath, []byte(strconv.FormatInt(uptime, 10)+"\n"), 0o600); err != nil {
		a.recordUSBFault("rebind-deferred", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}

	fields := map[string]string{"trigger": trigger, "functions": functions, "scope": "ecm0-netdev"}
	a.debug.add("usb", "event", "Linux ECM interface power cycle started", "", fields)
	a.recordUSBFault("rebind-start", trigger, "ecm0 link power cycle started; USB gadget and modem remain enabled")
	appendVoiceSystemSnapshot("usb-rebind-before")
	run := func(name string, arguments ...string) error {
		output, err := exec.Command(name, arguments...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %w", strings.TrimSpace(string(output)), err)
		}
		return nil
	}
	if err := powerCycleECMLink(run, time.Sleep); err != nil {
		logger.Printf("ECM 网卡下电重启失败: %v", err)
		a.recordUSBFault("rebind-failed", trigger, err.Error())
		return usbFailureOutcome(err.Error())
	}
	a.debug.add("usb", "event", "Linux ECM interface power cycle completed", "", fields)
	appendVoiceSystemSnapshot("usb-rebind-after")
	a.recordUSBFault("rebind-complete", trigger, "ecm0 restarted without USB gadget re-enumeration")
	return usbRebindOutcome{Retry: true, RetryAfter: usbVerifyRetryDelay, Reason: "验证 ECM 恢复结果"}
}

func systemUptimeSeconds() (int64, error) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, fmt.Errorf("读取系统 uptime 失败: %w", err)
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, errors.New("系统 uptime 为空")
	}
	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, fmt.Errorf("解析系统 uptime 失败: %w", err)
	}
	return int64(seconds), nil
}
