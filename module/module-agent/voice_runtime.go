package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	voiceHelperName       = "mavo-pcm-bridge.armv7"
	voiceHelperSHA256     = "13d034205664071db51120f349af7f785df58e269eeb07f531af5be18d0af228"
	voiceRoutePIDFile     = "/run/mavo-voice-route.pid"
	voiceSessionPIDFile   = "/run/mavo-voice-session.pid"
	voiceRouteLogMaxBytes = 1024 * 1024
	voiceNetworkListen    = "192.168.225.1:7580"
	voiceMediaRouteFIFO   = "/run/voc_svr"
	voiceCalibrationLog   = "/run/mavo-alsaucm.log"
	voiceCalibrationFIFO  = "/run/alsaucm_test"
	voiceAudioEnablePath  = "/sys/class/android_usb/f_audio/audio_enable"
	voiceExpectedKernel   = "3.18.44"
	voiceExpectedCardName = "mdm9607-tomtom-i2s-snd-card"
	// helper 启动后只等待 TCP listener；客户端握手由独立观察器确认，不能在
	// 启动函数内等待尚未执行的 Dial。
	voiceListenerReadyTimeout = 5 * time.Second
)

var (
	voiceRouteLogFile   = agentDataDirectory + "/log/voice-route.log"
	voiceRouteLogBackup = agentDataDirectory + "/log/voice-route.log.1"
)

var voiceRuntimeFiles = map[string]string{
	"qdc507_aprv3.ko": "3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a",
	"qdc507_voice.ko": "ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c",
	voiceHelperName:   voiceHelperSHA256,
}

var voiceRequiredDevices = []string{
	"/dev/snd/controlC0", "/dev/snd/pcmC0D4p", "/dev/snd/pcmC0D4c",
	"/dev/snd/pcmC0D5p", "/dev/snd/pcmC0D6c",
}

type voiceRuntimeValidator struct {
	once      sync.Once
	installed bool
	err       error
}

var cachedVoiceRuntimeValidator voiceRuntimeValidator

type voiceTracker struct {
	// lifecycleMu 串行化启动和停止，但绝不能用于 HTTP 状态快照。此前同一把
	// mu 被冷启动持有最长 15 秒，导致 /audio/host/config 阻塞和 App 轮询停顿。
	lifecycleMu       sync.Mutex
	mu                sync.Mutex
	command           *exec.Cmd
	routeCommand      *exec.Cmd
	listening         bool
	ready             bool
	routeReady        bool
	starting          bool
	stopping          bool
	mediaRouteStarted bool
	hostEnabled       bool
	lastError         string
	startedAt         time.Time
	logOffset         int64
}

type voiceRouteSnapshot struct {
	Command           *exec.Cmd
	RouteCommand      *exec.Cmd
	Listening         bool
	Ready             bool
	RouteReady        bool
	Starting          bool
	Stopping          bool
	MediaRouteStarted bool
	HostEnabled       bool
	LastError         string
	StartedAt         time.Time
	LogOffset         int64
}

func (tracker *voiceTracker) snapshot() voiceRouteSnapshot {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	return voiceRouteSnapshot{
		Command: tracker.command, RouteCommand: tracker.routeCommand,
		Listening: tracker.listening,
		Ready:     tracker.ready, RouteReady: tracker.routeReady,
		Starting: tracker.starting, Stopping: tracker.stopping,
		MediaRouteStarted: tracker.mediaRouteStarted,
		HostEnabled:       tracker.hostEnabled, LastError: tracker.lastError,
		StartedAt: tracker.startedAt, LogOffset: tracker.logOffset,
	}
}

// beginRouteStart obtains the long-running lifecycle lease while keeping the
// small state mutex free for health, diagnostics and hangup decisions.
func (tracker *voiceTracker) beginRouteStart(now time.Time) (func(), bool) {
	if !tracker.lifecycleMu.TryLock() {
		return func() {}, false
	}
	tracker.mu.Lock()
	if tracker.stopping || tracker.listening || tracker.ready || tracker.starting ||
		tracker.command != nil || tracker.routeCommand != nil {
		tracker.mu.Unlock()
		tracker.lifecycleMu.Unlock()
		return func() {}, false
	}
	tracker.starting = true
	tracker.startedAt = now
	tracker.mu.Unlock()
	return func() {
		tracker.mu.Lock()
		tracker.starting = false
		tracker.mu.Unlock()
		tracker.lifecycleMu.Unlock()
	}, true
}

type voicePCMStats struct {
	UplinkBytes          uint64 `json:"uplink_bytes"`
	UplinkFrames         uint64 `json:"uplink_frames"`
	UplinkPeak           uint64 `json:"uplink_peak"`
	DownlinkBytes        uint64 `json:"downlink_bytes"`
	DownlinkFrames       uint64 `json:"downlink_frames"`
	DownlinkPeak         uint64 `json:"downlink_peak"`
	DownlinkDroppedFrame uint64 `json:"downlink_dropped_frames"`
}

var voiceDiagnosticLogMu sync.Mutex
var voiceRuntimePrepareMu sync.Mutex
var voiceAudioGateMu sync.Mutex
var voiceAudioGateReady bool

// initializeVoiceAudioGateAtStartup prepares the vendor audio gate once during
// Agent startup. Network PCM never disables it at hangup, because toggling a
// function inside the USB composite can force iOS to rediscover the sibling ECM
// interface and temporarily lose 192.168.225.1.
func (a *agent) initializeVoiceAudioGateAtStartup() {
	if !a.usesLocalVoiceRuntime() {
		return
	}
	installed, err := validateVoiceRuntime()
	if err != nil || !installed {
		if err != nil {
			appendVoiceDiagnosticEvent("启动阶段检查语音运行时失败: " + err.Error())
		}
		return
	}
	appendVoiceSystemSnapshot("audio-gate-before")
	if err := a.ensureVoiceAudioGate(); err != nil {
		appendVoiceDiagnosticEvent("启动阶段保持 f_audio/audio_enable 失败: " + err.Error())
		return
	}
	appendVoiceSystemSnapshot("audio-gate-after")
}

func (a *agent) ensureVoiceAudioGate() error {
	voiceAudioGateMu.Lock()
	defer voiceAudioGateMu.Unlock()

	if voiceAudioGateReady {
		return nil
	}

	current, err := os.ReadFile(voiceAudioEnablePath)
	if err != nil {
		return fmt.Errorf("读取 %s 失败: %w", voiceAudioEnablePath, err)
	}
	if strings.TrimSpace(string(current)) != "1" {
		if err := os.WriteFile(voiceAudioEnablePath, []byte("1\n"), 0o600); err != nil {
			return fmt.Errorf("启用 %s 失败: %w", voiceAudioEnablePath, err)
		}
		appendVoiceDiagnosticEvent("f_audio/audio_enable 已在 Agent 启动周期内固定为 1")
	}
	voiceAudioGateReady = true
	return nil
}

// ensureVoiceRuntimeWarm 只做内核模块加载和 ACDB 校准，不启动通话媒体路由。
// 预热期间即使用户尚未接听，也不会占用 7580 或向基带发送媒体启动命令。
func (a *agent) ensureVoiceRuntimeWarm() {
	if !a.usesLocalVoiceRuntime() {
		return
	}
	appendVoiceDiagnosticEvent("开始预热语音运行时")
	if err := prepareVoiceRuntime(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("语音运行时预热失败: " + err.Error())
		return
	}
	a.voice.mu.Lock()
	a.voice.lastError = ""
	a.voice.mu.Unlock()
	appendVoiceDiagnosticEvent("语音运行时预热完成")
}

// validateVoiceRuntime 在执行任何内核模块前校验固定上游文件，拒绝运行被替换的二进制。
func validateVoiceRuntime() (bool, error) {
	return cachedVoiceRuntimeValidator.validate(voiceRuntimePath, voiceRuntimeFiles)
}

func (v *voiceRuntimeValidator) validate(directory string, files map[string]string) (bool, error) {
	v.once.Do(func() {
		v.installed, v.err = validateVoiceRuntimeFiles(directory, files)
	})
	return v.installed, v.err
}

func validateVoiceRuntimeFiles(directory string, files map[string]string) (bool, error) {
	for name, expected := range files {
		path := filepath.Join(directory, name)
		file, err := os.Open(path)
		if os.IsNotExist(err) {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("读取语音运行时 %s 失败: %w", name, err)
		}
		digest := sha256.New()
		_, copyErr := io.CopyBuffer(digest, file, make([]byte, 32*1024))
		closeErr := file.Close()
		if copyErr != nil {
			return false, fmt.Errorf("校验语音运行时 %s 失败: %w", name, copyErr)
		}
		if closeErr != nil {
			return false, fmt.Errorf("关闭语音运行时 %s 失败: %w", name, closeErr)
		}
		if hex.EncodeToString(digest.Sum(nil)) != expected {
			return false, fmt.Errorf("语音运行时 %s 的 SHA-256 校验失败", name)
		}
	}
	return true, nil
}

func (a *agent) ensureVoiceRoute() {
	_ = a.ensureVoiceRouteListening()
}

func (a *agent) ensureVoiceRouteListening() error {
	if !a.usesLocalVoiceRuntime() {
		_, err := a.voicePCMEndpoint()
		a.voice.mu.Lock()
		a.voice.listening = err == nil
		a.voice.ready = false
		a.voice.lastError = errorText(err)
		a.voice.mu.Unlock()
		if err != nil {
			a.debug.add("voice-backend", "error", "三星 PCM 后端不可用", err.Error(), nil)
			return err
		}
		a.debug.add("voice-backend", "configured", "三星 PCM 端点已配置，等待媒体握手", "", map[string]string{
			"backend": string(a.voiceBackend.kind),
		})
		return nil
	}
	release, started := a.voice.beginRouteStart(time.Now().UTC())
	if !started {
		return nil
	}
	defer release()

	// 上一通电话可能还在异步退出。旧进程占着 7580 时直接返回会让新电话
	// 永远等不到 AIRSIMREADY，这是“能拨出但接听后回拨失败”的典型竞态。
	a.voice.mu.Lock()
	if a.voice.command != nil || a.voice.routeCommand != nil {
		oldCommand := a.voice.command
		oldRouteCommand := a.voice.routeCommand
		oldMediaRouteStarted := a.voice.mediaRouteStarted
		a.voice.command = nil
		a.voice.routeCommand = nil
		a.voice.listening = false
		a.voice.routeReady = false
		a.voice.mediaRouteStarted = false
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("清理未完成的旧网络 PCM 会话")
		terminateVoiceProcess(oldCommand)
		terminateVoiceProcess(oldRouteCommand)
		if oldMediaRouteStarted {
			stopVoiceMediaRouteForLifecycle()
		}
	} else {
		a.voice.mu.Unlock()
	}
	appendVoiceDiagnosticEvent("收到语音桥启动请求")
	if err := prepareVoiceRuntime(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("语音运行时准备失败: " + err.Error())
		return err
	}
	if err := a.ensureVoiceAudioGate(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("语音音频门准备失败: " + err.Error())
		return err
	}

	helper := filepath.Join(voiceRuntimePath, voiceHelperName)
	if output, err := exec.Command(helper, "--check").CombinedOutput(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = commandFailure("语音桥自检失败", output, err).Error()
		lastError := a.voice.lastError
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent(lastError)
		return errors.New(lastError)
	}
	if err := prepareVoiceDiagnosticLog(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		return err
	}
	startedAt := time.Now().UTC()
	appendVoiceDiagnosticEvent("开始新的网络 PCM 会话")
	logOffset := voiceDiagnosticLogSize()
	a.voice.mu.Lock()
	a.voice.startedAt = startedAt
	a.voice.logOffset = logOffset
	a.voice.mu.Unlock()
	if err := a.startVoiceRouteSession(helper, logOffset); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("VoLTE 路由会话启动失败: " + err.Error())
		return err
	}
	// D4 只建立 AFE hostless 路由；voc_svr 的 S 命令负责启动基带媒体时钟，二者缺一不可。
	if err := startVoiceMediaRoute(); err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		routeCommand := a.voice.routeCommand
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("基带语音媒体路由启动失败: " + err.Error())
		terminateVoiceProcess(routeCommand)
		return err
	}
	a.voice.mu.Lock()
	a.voice.mediaRouteStarted = true
	a.voice.mu.Unlock()
	appendVoiceDiagnosticEvent("基带语音媒体路由已启动")
	logFile, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		routeCommand := a.voice.routeCommand
		mediaRouteStarted := a.voice.mediaRouteStarted
		a.voice.mu.Unlock()
		terminateVoiceProcess(routeCommand)
		if mediaRouteStarted {
			stopVoiceMediaRouteForLifecycle()
			a.voice.mu.Lock()
			a.voice.mediaRouteStarted = false
			a.voice.mu.Unlock()
		}
		return err
	}
	// D5 是主机到基带的播放端，D6 是基带到主机的采集端；不再经过 USB UAC D4。
	command := exec.Command(
		helper,
		"--tcp-listen", voiceNetworkListen,
		"--playback-device", "hw:0,5",
		"--capture-device", "hw:0,6",
		"--no-mixers",
		"--verbose",
	)
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		a.voice.mu.Lock()
		a.voice.lastError = err.Error()
		routeCommand := a.voice.routeCommand
		mediaRouteStarted := a.voice.mediaRouteStarted
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("语音桥进程启动失败: " + err.Error())
		terminateVoiceProcess(routeCommand)
		if mediaRouteStarted {
			stopVoiceMediaRouteForLifecycle()
			a.voice.mu.Lock()
			a.voice.mediaRouteStarted = false
			a.voice.mu.Unlock()
		}
		return err
	}
	a.voice.mu.Lock()
	a.voice.command = command
	a.voice.mu.Unlock()
	_ = os.WriteFile(voiceRoutePIDFile, []byte(strconv.Itoa(command.Process.Pid)+"\n"), 0o600)
	appendVoiceDiagnosticEvent(fmt.Sprintf("语音桥进程已启动 pid=%d", command.Process.Pid))

	done := make(chan error, 1)
	go func() {
		waitErr := command.Wait()
		done <- waitErr
		_ = logFile.Close()
		var routeCommand *exec.Cmd
		mediaRouteStarted := false
		a.voice.mu.Lock()
		if a.voice.command == command {
			a.voice.command = nil
			a.voice.listening = false
			a.voice.ready = false
			routeCommand = a.voice.routeCommand
			mediaRouteStarted = a.voice.mediaRouteStarted
			a.voice.mediaRouteStarted = false
			_ = os.Remove(voiceRoutePIDFile)
		}
		a.voice.mu.Unlock()
		// 主 PCM 桥退出后必须同步释放 D4/voc_svr；否则残留 routeCommand 会阻止通话看门狗重新拉起。
		if routeCommand != nil {
			terminateVoiceProcess(routeCommand)
			if mediaRouteStarted {
				stopVoiceMediaRouteForLifecycle()
			}
			_ = os.Remove(voiceSessionPIDFile)
		}
		exitDetail := errorText(waitErr)
		if exitDetail == "" {
			exitDetail = "正常退出"
		}
		appendVoiceDiagnosticEvent("语音桥进程退出: " + exitDetail)
	}()

	deadline := time.Now().Add(voiceListenerReadyTimeout)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			a.voice.mu.Lock()
			a.voice.command = nil
			a.voice.lastError = errorText(waitErr)
			routeCommand := a.voice.routeCommand
			mediaRouteStarted := a.voice.mediaRouteStarted
			a.voice.mu.Unlock()
			terminateVoiceProcess(routeCommand)
			if mediaRouteStarted {
				stopVoiceMediaRouteForLifecycle()
				a.voice.mu.Lock()
				a.voice.mediaRouteStarted = false
				a.voice.mu.Unlock()
			}
			return fmt.Errorf("语音桥在监听前退出: %s", errorText(waitErr))
		default:
		}
		if voiceRouteListeningFrom(logOffset) {
			a.voice.mu.Lock()
			if a.voice.command == command {
				a.voice.listening = true
			}
			a.voice.lastError = ""
			a.voice.mu.Unlock()
			appendVoiceDiagnosticEvent("网络 PCM 已监听，等待客户端握手")
			go a.observeVoiceRouteHandshake(command, logOffset)
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = command.Process.Signal(syscall.SIGTERM)
	a.voice.mu.Lock()
	routeCommand := a.voice.routeCommand
	a.voice.listening = false
	a.voice.lastError = "网络 PCM 监听未在限定时间内就绪"
	lastError := a.voice.lastError
	mediaRouteStarted := a.voice.mediaRouteStarted
	a.voice.mu.Unlock()
	terminateVoiceProcess(routeCommand)
	appendVoiceDiagnosticEvent(lastError)
	if mediaRouteStarted {
		stopVoiceMediaRouteForLifecycle()
		a.voice.mu.Lock()
		a.voice.mediaRouteStarted = false
		a.voice.mu.Unlock()
	}
	return errors.New(lastError)
}

func (a *agent) markVoiceBackendHandshakeReady() {
	if a.usesLocalVoiceRuntime() {
		return
	}
	a.voice.mu.Lock()
	if a.voice.listening {
		a.voice.ready = true
		a.voice.lastError = ""
	}
	a.voice.mu.Unlock()
}

func (a *agent) observeVoiceRouteHandshake(command *exec.Cmd, logOffset int64) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		a.voice.mu.Lock()
		current := a.voice.command == command && a.voice.listening
		a.voice.mu.Unlock()
		if !current {
			return
		}
		if !voiceRouteReadyFrom(logOffset) {
			continue
		}
		a.voice.mu.Lock()
		if a.voice.command == command && a.voice.listening {
			a.voice.ready = true
			a.voice.lastError = ""
		}
		a.voice.mu.Unlock()
		appendVoiceDiagnosticEvent("网络 PCM 握手与双向工作线程已就绪")
		return
	}
}

func (a *agent) ensureVoiceRouteIfHostEnabled() {
	a.voice.mu.Lock()
	hostEnabled := a.voice.hostEnabled
	a.voice.mu.Unlock()
	if hostEnabled {
		a.ensureVoiceRoute()
	}
}

// maintainVoiceRoute 只在已有接通通话且当前语音桥未运行时触发恢复。
// 不在通话外启动语音桥，避免空闲时加载内核音频模块和占用 PCM 设备。
func (a *agent) maintainVoiceRoute() {
	a.mu.RLock()
	active := a.calls.Active != nil && a.calls.Active.State == "active"
	a.mu.RUnlock()
	if !active {
		return
	}

	snapshot := a.voice.snapshot()
	hostEnabled := snapshot.HostEnabled
	running := snapshot.Starting || snapshot.Stopping || snapshot.Ready ||
		snapshot.Command != nil || snapshot.RouteCommand != nil
	if hostEnabled && !running {
		go a.ensureVoiceRoute()
	}
}

// startVoiceRouteSession 启动 D4 hostless 会话，把 D5/D6 AFE PCM 真正接入基带通话。
func (a *agent) startVoiceRouteSession(helper string, logOffset int64) error {
	logFile, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command(helper, "--voice-route-session", "--verbose")
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	a.voice.mu.Lock()
	a.voice.routeCommand = command
	a.voice.routeReady = false
	a.voice.mu.Unlock()
	_ = os.WriteFile(voiceSessionPIDFile, []byte(strconv.Itoa(command.Process.Pid)+"\n"), 0o600)
	appendVoiceDiagnosticEvent(fmt.Sprintf("VoLTE 路由会话已启动 pid=%d", command.Process.Pid))

	done := make(chan error, 1)
	go func() {
		waitErr := command.Wait()
		done <- waitErr
		_ = logFile.Close()
		a.voice.mu.Lock()
		if a.voice.routeCommand == command {
			a.voice.routeCommand = nil
			a.voice.routeReady = false
			a.voice.listening = false
			a.voice.ready = false
			_ = os.Remove(voiceSessionPIDFile)
		}
		a.voice.mu.Unlock()
		exitDetail := errorText(waitErr)
		if exitDetail == "" {
			exitDetail = "正常退出"
		}
		appendVoiceDiagnosticEvent("VoLTE 路由会话退出: " + exitDetail)
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case waitErr := <-done:
			a.voice.mu.Lock()
			a.voice.routeCommand = nil
			a.voice.mu.Unlock()
			return fmt.Errorf("VoLTE 路由会话提前退出: %s", errorText(waitErr))
		default:
		}
		if voiceRouteSessionReadyFrom(logOffset) {
			a.voice.mu.Lock()
			a.voice.routeReady = true
			a.voice.mu.Unlock()
			appendVoiceDiagnosticEvent("VoLTE D4 路由与 AFE mixer 已就绪")
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	terminateVoiceProcess(command)
	return errors.New("VoLTE D4 路由会话未在限定时间内就绪")
}

func stopVoiceMediaRoute() {
	_ = writeVoiceMediaRoute(voiceMediaRouteFIFO, "T\nT\nB\n")
}

var stopVoiceMediaRouteForLifecycle = stopVoiceMediaRoute

func startVoiceMediaRoute() error {
	if err := writeVoiceMediaRoute(voiceMediaRouteFIFO, "S\n"); err != nil {
		return fmt.Errorf("启动模块 D5/D6 基带媒体路由失败: %w", err)
	}
	return nil
}

func writeVoiceMediaRoute(path string, command string) error {
	fifo, err := os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("打开语音路由 FIFO 失败: %w", err)
	}
	_, writeErr := fifo.WriteString(command)
	closeErr := fifo.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

// prepareVoiceRuntime 串行化预热与正式语音桥启动，避免快速接听时并发 insmod/校准。
func prepareVoiceRuntime() error {
	voiceRuntimePrepareMu.Lock()
	defer voiceRuntimePrepareMu.Unlock()
	return prepareVoiceRuntimeUnlocked()
}

func prepareVoiceRuntimeUnlocked() error {
	installed, err := validateVoiceRuntime()
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("模块语音运行时未安装")
	}
	release, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil || !strings.Contains(string(release), voiceExpectedKernel) {
		return fmt.Errorf("模块内核不匹配，需要 %s，实际 %s", voiceExpectedKernel, strings.TrimSpace(string(release)))
	}
	modules, _ := os.ReadFile("/proc/modules")
	for _, item := range []struct{ file, module string }{{"qdc507_aprv3.ko", "qdc507_aprv3"}, {"qdc507_voice.ko", "qdc507_voice"}} {
		if strings.Contains(string(modules), item.module+" ") {
			continue
		}
		output, commandErr := exec.Command("/sbin/insmod", filepath.Join(voiceRuntimePath, item.file)).CombinedOutput()
		if errors.Is(commandErr, exec.ErrNotFound) {
			output, commandErr = exec.Command("insmod", filepath.Join(voiceRuntimePath, item.file)).CombinedOutput()
		}
		if commandErr != nil {
			return commandFailure("加载 "+item.file+" 失败", output, commandErr)
		}
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if voiceDevicesReady() {
			return ensureVoiceCalibration()
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("语音驱动已加载，但 ALSA D4/D5/D6 设备没有出现")
}

func voiceDevicesReady() bool {
	for _, device := range voiceRequiredDevices {
		if !fileExists(device) {
			return false
		}
	}
	cards, err := os.ReadFile("/proc/asound/cards")
	return err == nil && strings.Contains(string(cards), voiceExpectedCardName)
}

func ensureVoiceCalibration() error {
	if logContains(voiceCalibrationLog, "ACDB -> Sent VocProc Cal!") {
		return nil
	}
	logFile, err := os.OpenFile(voiceCalibrationLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command("/usr/bin/alsaucm_test")
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		return fmt.Errorf("启动 VoLTE ACDB 校准服务失败: %w", err)
	}
	go func() {
		_ = command.Wait()
		_ = logFile.Close()
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && !fileExists(voiceCalibrationFIFO) {
		time.Sleep(100 * time.Millisecond)
	}
	if !fileExists(voiceCalibrationFIFO) {
		return errors.New("VoLTE ACDB 校准 FIFO 没有出现")
	}
	fifo, err := os.OpenFile(voiceCalibrationFIFO, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("打开 VoLTE ACDB 校准 FIFO 失败: %w", err)
	}
	_, writeErr := fifo.WriteString("open snd_soc_msm_9x07_Tomtom_I2S\nset _verb VoLTE\nset _enadev Auxpcm Rx\nset _enadev Auxpcm Tx\n")
	_ = fifo.Close()
	if writeErr != nil {
		return writeErr
	}
	deadline = time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if logContains(voiceCalibrationLog, "ACDB -> Sent VocProc Cal!") {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("VoLTE ACDB 校准未确认完成")
}

func voiceRouteReadyFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteLogReady(data)
}

func voiceRouteListeningFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteListeningLogReady(data)
}

func voiceRouteSessionReadyFrom(offset int64) bool {
	data, err := readVoiceDiagnosticLog(offset)
	return err == nil && voiceRouteSessionLogReady(data)
}

func voiceRouteLogReady(data []byte) bool {
	return voiceRouteListeningLogReady(data) &&
		strings.Contains(string(data), "network PCM client connected") &&
		strings.Contains(string(data), "bridge active on 192.168.225.1:7580")
}

func voiceRouteListeningLogReady(data []byte) bool {
	return voiceRouteSessionLogReady(data) &&
		strings.Contains(string(data), "network PCM listening on 192.168.225.1:7580")
}

func voiceRouteSessionLogReady(data []byte) bool {
	return strings.Contains(string(data), "VoLTE route session active on hw:0,4")
}

func (a *agent) stopVoiceRoute() {
	if !a.usesLocalVoiceRuntime() {
		a.voice.mu.Lock()
		a.voice.ready = false
		a.voice.listening = false
		a.voice.routeReady = false
		a.voice.mediaRouteStarted = false
		a.voice.lastError = ""
		a.voice.mu.Unlock()
		a.debug.add("voice-backend", "stopped", "三星 PCM Agent 会话已释放", "", map[string]string{
			"backend": string(a.voiceBackend.kind),
		})
		return
	}
	appendVoiceSystemSnapshot("voice-stop-before")
	// 与冷启动生命周期串行，但状态快照使用独立的短锁，因此等待清理时
	// /health 和 /audio/host/config 仍可正常返回。
	a.voice.lifecycleMu.Lock()
	a.voice.mu.Lock()
	if a.voice.stopping {
		a.voice.mu.Unlock()
		a.voice.lifecycleMu.Unlock()
		return
	}
	command := a.voice.command
	routeCommand := a.voice.routeCommand
	mediaRouteStarted := a.voice.mediaRouteStarted
	a.voice.ready = false
	a.voice.listening = false
	a.voice.routeReady = false
	a.voice.mediaRouteStarted = false
	a.voice.stopping = true
	// 先从状态中摘除旧进程，新的 ensureVoiceRoute 会看到 stopping 并等待，
	// 避免新旧 helper 同时抢占 7580 端口。
	a.voice.command = nil
	a.voice.routeCommand = nil
	a.voice.mu.Unlock()
	// 先断开 D5/D6 数据桥，再让 D4 route session 回滚 mixer。只有真正
	// 启动过媒体路由才允许写 voc_svr；拒接未接通的来电不得触碰它。
	terminateVoiceProcess(command)
	terminateVoiceProcess(routeCommand)
	if mediaRouteStarted {
		stopVoiceMediaRouteForLifecycle()
	}
	_ = os.Remove(voiceRoutePIDFile)
	_ = os.Remove(voiceSessionPIDFile)
	a.voice.mu.Lock()
	a.voice.stopping = false
	hostEnabled := a.voice.hostEnabled
	a.voice.mu.Unlock()
	appendVoiceSystemSnapshot("voice-stop-after")
	// 必须先释放生命周期租约再触发重启；beginRouteStart 使用 TryLock，
	// 若在持锁期间启动会把这次必要的恢复误判成重复启动。
	a.voice.lifecycleMu.Unlock()
	// 如果停止期间已经有新通话接通，立即补起语音桥，不依赖下一轮轮询。
	a.mu.RLock()
	active := a.calls.Active != nil && a.calls.Active.State == "active"
	a.mu.RUnlock()
	if active && hostEnabled {
		go a.ensureVoiceRoute()
	}
}

func appendVoiceSystemSnapshot(label string) {
	values := []string{
		"pid=" + strconv.Itoa(os.Getpid()),
		"ecm_operstate=" + readSystemState("/sys/class/net/ecm0/operstate"),
		"ecm_carrier=" + readSystemState("/sys/class/net/ecm0/carrier"),
		"ecm_address=" + readSystemState("/sys/class/net/ecm0/address"),
		"usb_state=" + readSystemState("/sys/class/android_usb/android0/state"),
		"usb_enable=" + readSystemState("/sys/class/android_usb/android0/enable"),
		"usb_functions=" + readSystemState("/sys/class/android_usb/android0/functions"),
		"audio_enable=" + readSystemState(voiceAudioEnablePath),
	}
	appendVoiceDiagnosticEvent("系统快照[" + label + "]: " + strings.Join(values, " "))
}

func readSystemState(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "missing"
		}
		return "error:" + err.Error()
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "empty"
	}
	if len(value) > 160 {
		value = value[:160]
	}
	return strings.Join(strings.Fields(value), ",")
}

func terminateVoiceProcess(command *exec.Cmd) {
	if command == nil || command.Process == nil {
		return
	}
	pid := command.Process.Pid
	_ = command.Process.Signal(syscall.SIGTERM)
	for attempt := 0; attempt < 30; attempt++ {
		if err := syscall.Kill(pid, 0); err != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func logContains(path, marker string) bool {
	data, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(data), marker)
}

// prepareVoiceDiagnosticLog 限制持久日志大小，避免长期通话耗尽模块的 /data 分区。
func prepareVoiceDiagnosticLog() error {
	voiceDiagnosticLogMu.Lock()
	defer voiceDiagnosticLogMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(voiceRouteLogFile), 0o700); err != nil {
		return fmt.Errorf("创建语音诊断目录失败: %w", err)
	}
	info, err := os.Stat(voiceRouteLogFile)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("读取语音诊断日志失败: %w", err)
	}
	if info.Size() < voiceRouteLogMaxBytes {
		return nil
	}
	if err := os.Rename(voiceRouteLogFile, voiceRouteLogBackup); err != nil {
		return fmt.Errorf("轮换语音诊断日志失败: %w", err)
	}
	return nil
}

// appendVoiceDiagnosticEvent 写入带 UTC 时间的控制面事件，不记录号码或原始音频。
func appendVoiceDiagnosticEvent(message string) {
	voiceDiagnosticLogMu.Lock()
	defer voiceDiagnosticLogMu.Unlock()
	if os.MkdirAll(filepath.Dir(voiceRouteLogFile), 0o700) != nil {
		return
	}
	file, err := os.OpenFile(voiceRouteLogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(file, "qdc507-agent[event]: time=%s %s\n", time.Now().UTC().Format(time.RFC3339Nano), message)
	_ = file.Close()
}

func voiceDiagnosticLogSize() int64 {
	info, err := os.Stat(voiceRouteLogFile)
	if err != nil {
		return 0
	}
	return info.Size()
}

func readVoiceDiagnosticLog(offset int64) ([]byte, error) {
	data, err := os.ReadFile(voiceRouteLogFile)
	if err != nil {
		return nil, err
	}
	if offset <= 0 {
		return data, nil
	}
	if offset >= int64(len(data)) {
		return []byte{}, nil
	}
	return data[offset:], nil
}

// parseVoicePCMStats 解析 helper 最后一条累计统计，供 HTTP 与单元测试共同使用。
func parseVoicePCMStats(data []byte) (voicePCMStats, bool) {
	lines := strings.Split(string(data), "\n")
	for lineIndex := len(lines) - 1; lineIndex >= 0; lineIndex-- {
		marker := "mavo-pcm-bridge[stats]: "
		markerIndex := strings.Index(lines[lineIndex], marker)
		if markerIndex < 0 {
			continue
		}
		values := make(map[string]uint64)
		for _, field := range strings.Fields(lines[lineIndex][markerIndex+len(marker):]) {
			parts := strings.SplitN(field, "=", 2)
			if len(parts) != 2 {
				continue
			}
			value, err := strconv.ParseUint(parts[1], 10, 64)
			if err == nil {
				values[parts[0]] = value
			}
		}
		return voicePCMStats{
			UplinkBytes:          values["uplink_bytes"],
			UplinkFrames:         values["uplink_frames"],
			UplinkPeak:           values["uplink_peak"],
			DownlinkBytes:        values["downlink_bytes"],
			DownlinkFrames:       values["downlink_frames"],
			DownlinkPeak:         values["downlink_peak"],
			DownlinkDroppedFrame: values["downlink_dropped_frames"],
		}, true
	}
	return voicePCMStats{}, false
}

func voiceDiagnosticSnapshot(offset int64) (voicePCMStats, bool, []string) {
	data, err := os.ReadFile(voiceRouteLogFile)
	if err != nil {
		return voicePCMStats{}, false, []string{}
	}
	statsData := data
	if offset > 0 && offset < int64(len(data)) {
		statsData = data[offset:]
	}
	stats, available := parseVoicePCMStats(statsData)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) > 24 {
		lines = lines[len(lines)-24:]
	}
	if len(lines) == 1 && lines[0] == "" {
		lines = []string{}
	}
	return stats, available, lines
}

func commandFailure(prefix string, output []byte, err error) error {
	detail := strings.TrimSpace(string(output))
	if len(detail) > 1000 {
		detail = detail[len(detail)-1000:]
	}
	if detail == "" {
		return fmt.Errorf("%s: %w", prefix, err)
	}
	return fmt.Errorf("%s: %s（%v）", prefix, detail, err)
}
