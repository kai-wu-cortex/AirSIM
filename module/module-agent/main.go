package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	agentVersion = "0.4.2"
	// 监听所有本机接口以容忍 ECM 地址晚于 init 服务出现；请求层仍只放行 USB 私网与环回。
	listenAddress = "0.0.0.0:7575"
	// DATA11 桥与原厂 DATA1 完全分离，禁止重新使用 ql_manager_server 占用的 /dev/smd7。
	atDevice = "/dev/airsim_data11"
)

type agent struct {
	at                   *atPort
	profile              runtimeProfile
	gpsCommand           func(string, time.Duration) (string, error)
	started              time.Time
	mu                   sync.RWMutex
	modem                modemStatus
	calls                callTracker
	messages             []storedSMS
	smsAuto              bool
	smsError             string
	gps                  gpsTracker
	muted                bool
	isRecording          bool
	force4GOff           bool
	voice                voiceTracker
	voiceBackend         voiceBackendConfig
	voiceBackendErr      error
	defaultRoute         func() map[string]string
	esimMu               sync.Mutex
	rxStart              uint64
	txStart              uint64
	callRefresh          chan struct{}
	callChanged          chan struct{}
	callRevision         uint64
	smsNotices           chan smsStorageRef
	eventChanged         chan struct{}
	eventRevision        uint64
	smsRevision          uint64
	smsRescanRequested   bool
	smsRescanRevision    uint64
	debug                debugLog
	push                 *pushManager
	cloudCallMu          sync.Mutex
	cloudCallCancel      context.CancelFunc
	cloudCallCurrent     *cloudCallDescriptor
	callControlCommand   func(string, time.Duration) (string, error)
	callControlSleep     func(time.Duration)
	callControlDelays    []time.Duration
	cloudCommandExecMu   sync.Mutex
	cloudCommandMu       sync.Mutex
	cloudCommandResults  map[string]cloudCommandResult
	cloudCommandExpiry   map[string]time.Time
	hangupFlight         operationFlight
	usbFaults            *usbFaultStore
	cellularRecovery     *cellularRecoveryTracker
	router               *routerManager
	android              *androidControl
	pairRegistrationSync func()
}

func newAgent(atPath string) *agent {
	voiceBackend, voiceBackendErr := loadVoiceBackend(os.Getenv)
	androidToken, androidTokenErr := loadAndroidControlToken(os.Getenv)
	service := &agent{
		at: newATPort(atPath), profile: currentRuntimeProfile(), started: time.Now(), smsAuto: true,
		callRefresh: make(chan struct{}, 1), callChanged: make(chan struct{}),
		smsNotices: make(chan smsStorageRef, 16), eventChanged: make(chan struct{}),
		push:                newPushManager(filepath.Join(agentDataDirectory, "push.json")),
		cloudCommandResults: make(map[string]cloudCommandResult),
		cloudCommandExpiry:  make(map[string]time.Time),
		usbFaults:           newUSBFaultStore(filepath.Join(agentDataDirectory, "log", "usb-faults.json"), usbFaultHistoryLimit),
		cellularRecovery:    newCellularRecoveryTracker(time.Now()),
		router:              newRouterManager(agentDataDirectory),
		android:             newAndroidControl(androidToken),
		voiceBackend:        voiceBackend,
		voiceBackendErr:     voiceBackendErr,
	}
	service.at.setURCHandler(service.handleURC)
	service.pairRegistrationSync = service.syncPushRegistration
	service.push.onCallDelivered = service.startCloudCall
	service.at.setReopenHandler(service.handleATReopen)
	service.at.setDebugHandler(func(direction, summary, payload string) {
		service.debug.add("at", direction, summary, payload, nil)
	})
	service.debug.add("system", "", "agent initialized", "", map[string]string{"version": agentVersion})
	if voiceBackendErr != nil {
		service.debug.add("voice-backend", "error", "语音后端配置无效", voiceBackendErr.Error(), nil)
	} else {
		service.debug.add("voice-backend", "configured", "语音后端已选择", "", map[string]string{
			"backend": string(voiceBackend.kind),
		})
	}
	if androidTokenErr != nil {
		service.debug.add("android-telecom", "error", "Android 控制令牌读取失败", androidTokenErr.Error(), nil)
	}
	return service
}

func (a *agent) handleATReopen() {
	a.debug.add("system", "", "AT port reopened", "", nil)
	a.mu.Lock()
	a.calls.Configured = false
	a.calls.EventDriven = false
	a.mu.Unlock()
	a.requestCallRefresh()
	go func() {
		_, _ = a.at.command("AT+CEREG=1", 3*time.Second)
		_, _ = a.at.command("AT+CMGF=1", 3*time.Second)
		_, _ = a.at.command(`AT+CNMI=2,1,0,0,0`, 3*time.Second)
	}()
}

func main() {
	configureRuntimeStability()
	if len(os.Args) > 1 && os.Args[1] == "--startup-probe" {
		// 使用最早可见标记，区分包初始化崩溃与 main 内部崩溃。
		fmt.Println("启动探针标记: main-entry")
	}
	logger := log.New(os.Stdout, "airsim-agent: ", log.LstdFlags|log.LUTC)
	go startRuntimeMonitor(logger)
	probed, err := runStartupProbe(logger)
	if err != nil {
		logger.Fatalf("启动探针失败: %v", err)
	}
	if probed {
		return
	}

	service := newAgent(atDevice)
	if !service.profile.AndroidTelecom {
		logger.Fatal("AirSIM 仅支持 android-avf 运行配置，不启动 QDC507 模块模式")
	}
	if service.voiceBackendErr != nil || service.voiceBackend.kind != voiceBackendSamsungAndroid {
		logger.Fatalf("AirSIM 需要有效的三星私网 PCM 地址: %v", service.voiceBackendErr)
	}
	modemAvailable := false
	if modemAvailable {
		defer service.at.close()
		service.at.startURCMonitor()
		// USB 音频门若为网络 PCM 所需，只在 Agent 启动阶段设置一次；通话
		// 接听与挂断期间保持不变，避免 ECM 与 f_audio 同组合时重新枚举。
		service.initializeVoiceAudioGateAtStartup()

		service.rxStart, service.txStart, _ = readInterfaceCounters("ecm0")
		// 原厂服务刚释放 SMD 端口时，首轮 AT 查询可能需要几十秒。
		// 先启动 HTTP 服务，再由轮询协程刷新状态，避免 iPad 把慢启动误判成代理离线。
		go service.pollLoop()
		go service.atKeepaliveLoop()
		go service.router.monitorLoop(context.Background(), func(summary, detail string) {
			service.debug.add("router", "event", summary, detail, nil)
		})
		// 由内核 RTM_NEWLINK/RTM_DELLINK 事件驱动 ECM 恢复；1 秒轮询作为
		// netlink 丢事件时的兜底，并覆盖 ecm0 整个从 sysfs 消失的情况。
		startUSBLinkMonitor(service, logger)
		// 监听器建立后落一份基线，后续即使 ECM 失联，也能在模块本地对比
		// Agent PID 与 ql_manager_server PID 是否发生变化。
		go func() {
			time.Sleep(2 * time.Second)
			service.recordUSBFault("agent-start", "startup", "startup baseline")
		}()
	}
	// Push/Relay 属于 Agent 控制面。Android AVF 没有直通 AT 端口，但仍须
	// 保持公网心跳和命令通道，由 Android Telecom 执行运营商通话动作。
	go service.cloudHeartbeatLoop()
	go service.cloudCommandLoop()

	server := &http.Server{
		Addr:              listenAddress,
		Handler:           service.routes(logger),
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      190 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		// 给正在返回结果的控制请求留出短暂完成时间。
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	logger.Printf("监听 %s，版本 %s", listenAddress, agentVersion)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("HTTP 服务退出: %v", err)
	}
}

// runStartupProbe 分阶段验证启动路径，不发送 AT 指令，也不改变模块网络状态。
func runStartupProbe(logger *log.Logger) (bool, error) {
	if len(os.Args) == 1 || os.Args[1] != "--startup-probe" {
		return false, nil
	}
	if len(os.Args) != 3 {
		return true, errors.New("用法: --startup-probe runtime|routes|listen|voice-backend|at-open|esim-read")
	}

	fmt.Println("启动探针标记: stage-entry")
	service := newAgent(atDevice)
	fmt.Println("启动探针标记: service-created")
	switch os.Args[2] {
	case "runtime":
		// 部署器据此核对 Agent 内嵌白名单与同批 helper，阻止错配产物提交。
		fmt.Printf("__VOICE_HELPER_SHA256__%s\n", voiceHelperSHA256)
		logger.Printf("启动探针通过: runtime")
	case "routes":
		_ = service.routes(logger)
		logger.Printf("启动探针通过: routes")
	case "listen":
		listener, err := net.Listen("tcp", listenAddress)
		if err != nil {
			return true, fmt.Errorf("监听 %s 失败: %w", listenAddress, err)
		}
		if err := listener.Close(); err != nil {
			return true, fmt.Errorf("关闭探针监听失败: %w", err)
		}
		logger.Printf("启动探针通过: listen")
	case "voice-backend":
		endpoint, err := service.voicePCMEndpoint()
		if err != nil {
			return true, err
		}
		if err := probeVoicePCMBackend(endpoint, func(network, address string) (net.Conn, error) {
			return net.DialTimeout(network, address, 3*time.Second)
		}); err != nil {
			return true, fmt.Errorf("三星 PCM 后端握手失败: %w", err)
		}
		logger.Printf("启动探针通过: voice-backend")
	case "at-open":
		if err := service.at.open(); err != nil {
			return true, err
		}
		if err := service.at.close(); err != nil {
			return true, err
		}
		logger.Printf("启动探针通过: at-open")
	case "esim-read":
		// 直接读取 LPA，避免 HTTP 服务的通话/短信轮询与 eUICC APDU 争用同一 AT 端口。
		if err := service.at.open(); err != nil {
			return true, err
		}
		defer service.at.close()
		overview, err := service.readESIMOverview()
		if err != nil {
			return true, err
		}
		encoded, err := json.Marshal(overview)
		if err != nil {
			return true, fmt.Errorf("编码 eSIM 总览失败: %w", err)
		}
		fmt.Printf("__ESIM_OVERVIEW__%s\n", encoded)
		logger.Printf("启动探针通过: esim-read")
	default:
		return true, fmt.Errorf("未知启动探针阶段: %s", os.Args[2])
	}
	return true, nil
}

func (a *agent) routes(logger *log.Logger) http.Handler {
	admission := newRequestAdmission(defaultNormalRequests, defaultControlRequests, defaultLongPolls)
	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", a.health)
	mux.HandleFunc("/api/debug", a.debugStatus)
	mux.HandleFunc("/api/debug/clear", a.debugClear)
	mux.HandleFunc("/api/usb/faults", a.usbFaultStatus)
	mux.HandleFunc("/api/platform", a.platform)
	mux.HandleFunc("/api/android/status", a.androidStatus)
	mux.HandleFunc("/api/android/calls/event", a.androidCallEvent)
	mux.HandleFunc("/api/android/sms/event", a.androidSMSEvent)
	mux.HandleFunc("/api/android/pair/register", a.androidPairRegister)
	mux.HandleFunc("/api/android/commands/next", a.androidCommandNext)
	mux.HandleFunc("/api/android/commands/result", a.androidCommandResult)
	mux.HandleFunc("/api/status", a.status)
	mux.HandleFunc("/api/events", a.agentEvents)
	mux.HandleFunc("/api/push/register", a.pushRegister)
	mux.HandleFunc("/api/push/status", a.pushStatus)
	mux.HandleFunc("/api/push/mode", a.pushMode)
	mux.HandleFunc("/api/calls/status", a.callStatus)
	mux.HandleFunc("/api/calls/events", a.callEvents)
	mux.HandleFunc("/api/calls/history/ack", a.callHistoryAck)
	mux.HandleFunc("/api/calls/dial", a.dial)
	mux.HandleFunc("/api/calls/answer", a.answer)
	mux.HandleFunc("/api/calls/reject", a.reject)
	mux.HandleFunc("/api/calls/hangup", a.hangup)
	mux.HandleFunc("/api/calls/dtmf", a.dtmf)
	mux.HandleFunc("/api/calls/audio/mute", a.mute)
	mux.HandleFunc("/api/calls/audio/record", a.recording)
	mux.HandleFunc("/api/calls/audio/host/warmup", a.audioHostWarmup)
	mux.HandleFunc("/api/calls/audio/host/register", a.audioHostRegister)
	mux.HandleFunc("/api/calls/audio/host/config", a.audioHostConfig)
	mux.HandleFunc("/api/sms", a.smsList)
	mux.HandleFunc("/api/sms/status", a.smsStatus)
	mux.HandleFunc("/api/sms/send", a.smsSend)
	mux.HandleFunc("/api/sms/refresh", a.smsRefresh)
	mux.HandleFunc("/api/sms/ack", a.smsAck)
	mux.HandleFunc("/api/sms/settings", a.smsSettings)
	mux.HandleFunc("/api/sms/clear-module", a.smsClear)
	mux.HandleFunc("/api/sim/identity", a.simIdentity)
	mux.HandleFunc("/api/network/traffic", a.networkTraffic)
	mux.HandleFunc("/api/network/cellular-policy", a.cellularPolicy)
	mux.HandleFunc("/api/network/check-4g", a.check4G)
	mux.HandleFunc("/api/network/check-proxy", a.checkProxy)
	mux.HandleFunc("/api/network/reboot-module", a.rebootModule)
	mux.HandleFunc("/api/network", a.networkDiagnostic)
	mux.HandleFunc("/api/router/status", a.routerStatus)
	mux.HandleFunc("/api/router/config", a.routerConfig)
	mux.HandleFunc("/api/router/internet", a.routerInternet)
	mux.HandleFunc("/api/router/quota/reset", a.routerQuotaReset)
	mux.HandleFunc("/api/router/repair", a.routerRepair)
	mux.HandleFunc("/api/router/clients", a.routerClients)
	mux.HandleFunc("/api/system/power", a.systemPower)
	mux.HandleFunc("/api/usb/profile", a.usbProfile)
	mux.HandleFunc("/api/gps", a.gpsStatus)
	mux.HandleFunc("/api/gps/start", a.gpsStart)
	mux.HandleFunc("/api/gps/stop", a.gpsStop)
	mux.HandleFunc("/api/gps/refresh", a.gpsRefresh)
	mux.HandleFunc("/api/at", a.executeAT)
	mux.HandleFunc("/api/esim", a.esimOverview)
	mux.HandleFunc("/api/esim/health", a.esimHealth)
	mux.HandleFunc("/api/esim/notes", a.esimNotes)
	mux.HandleFunc("/api/esim/phonebook/probe", a.esimPhonebookProbe)
	mux.HandleFunc("/api/esim/switch", a.esimSwitch)
	mux.HandleFunc("/api/esim/profile", a.esimProfile)
	mux.HandleFunc("/api/esim/download", a.esimDownload)
	mux.HandleFunc("/api/module/setup", a.moduleSetup)
	mux.HandleFunc("/api/voice/status", a.voiceStatus)
	mux.HandleFunc("/api/voice/provision", a.voiceProvision)
	mux.HandleFunc("/api/system/update", a.systemUpdate)
	mux.HandleFunc("/api/system/update/status", a.systemUpdateStatus)
	mux.HandleFunc("/api/system/update/log", a.systemUpdateLog)
	mux.HandleFunc("/api/service/shutdown", a.shutdown)
	mux.HandleFunc("/", func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/" {
			writeError(response, http.StatusNotFound, "接口不存在")
			return
		}
		a.debugStatus(response, request)
	})

	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		started := time.Now()
		requestCapture := &cappedCapture{}
		if request.Body != nil {
			originalBody := request.Body
			request.Body = &teeReadCloser{Reader: io.TeeReader(originalBody, requestCapture), Closer: originalBody}
		}
		capturedResponse := &debugResponseWriter{ResponseWriter: response}
		capturedResponse.Header().Set("Content-Type", "application/json; charset=utf-8")
		capturedResponse.Header().Set("Cache-Control", "no-store")
		capturedResponse.Header().Set("X-Content-Type-Options", "nosniff")
		capturedResponse.Header().Set("X-Frame-Options", "DENY")
		capturedResponse.Header().Set("Referrer-Policy", "no-referrer")
		release, admitted := admission.acquire(request.Context(), request.URL.Path)
		if !admitted {
			rejectBusy(capturedResponse)
		} else {
			func() {
				defer release()
				if !allowedRemoteWithNetworks(request.RemoteAddr, a.profile, localIPv4Networks()) {
					writeError(capturedResponse, http.StatusForbidden, "只允许 USB 本地网络访问")
					return
				}
				mux.ServeHTTP(capturedResponse, request)
			}()
		}
		if capturedResponse.status == 0 {
			capturedResponse.status = http.StatusOK
		}
		duration := time.Since(started).Round(time.Millisecond)
		responseBody := capturedResponse.capture.text()
		if request.URL.Path == "/" || request.URL.Path == "/api/debug" {
			responseBody = "[debug snapshot body omitted from recursive capture]"
		}
		requestBody := requestCapture.text()
		if strings.HasPrefix(request.URL.Path, "/api/android/") || strings.HasPrefix(request.URL.Path, "/api/sms") {
			requestBody = "[Android control body omitted]"
			responseBody = "[SMS/control response body omitted]"
		}
		fields := map[string]string{
			"remote": request.RemoteAddr, "status": strconv.Itoa(capturedResponse.status),
			"duration": duration.String(), "request_bytes": strconv.FormatInt(requestCapture.total, 10),
			"response_bytes": strconv.FormatInt(capturedResponse.capture.total, 10),
		}
		if traceID := strings.TrimSpace(request.Header.Get("X-AirSIM-Trace-ID")); traceID != "" {
			if len(traceID) > 128 {
				traceID = traceID[:128]
			}
			fields["trace_id"] = traceID
		}
		a.debug.add("http", "request/response", request.Method+" "+request.URL.RequestURI(),
			"request:\n"+requestBody+"\nresponse:\n"+responseBody,
			fields)
		logger.Printf("%s %s %s", request.Method, request.URL.Path, duration)
	})
}

// allowedRemote 把控制面限制在模块自身和 CDC ECM 子网。
func allowedRemote(remote string) bool {
	return allowedRemoteWithNetworks(remote, runtimeProfileFrom("qdc507"), nil)
}

func allowedRemoteWithNetworks(remote string, profile runtimeProfile, networks []*net.IPNet) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	if (v4[0] == 192 && v4[1] == 168 && v4[2] == 225) ||
		(v4[0] == 10 && v4[1] == 185 && v4[2] == 5) {
		return true
	}
	if !profile.AndroidTelecom || !ip.IsPrivate() {
		return false
	}
	for _, network := range networks {
		if network != nil && network.Contains(v4) {
			return true
		}
	}
	return false
}

func localIPv4Networks() []*net.IPNet {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	networks := make([]*net.IPNet, 0, len(addresses))
	for _, address := range addresses {
		if network, ok := address.(*net.IPNet); ok && network.IP.To4() != nil {
			networks = append(networks, network)
		}
	}
	return networks
}

func (a *agent) pollLoop() {
	go a.callPollLoop()
	go a.modemPollLoop()
	go a.smsPollLoop()

	voiceTicker := time.NewTicker(time.Second)
	defer voiceTicker.Stop()
	for {
		<-voiceTicker.C
		// 通话过程中语音桥可能因内核设备短暂不可用而退出；只要通话仍在，下一轮主动恢复媒体链路。
		a.maintainVoiceRoute()
	}
}

func (a *agent) callPollLoop() {
	a.refreshCalls()
	for {
		a.mu.RLock()
		eventDriven := a.calls.EventDriven
		callActive := a.calls.Active != nil
		a.mu.RUnlock()
		timer := time.NewTimer(callPollInterval(eventDriven, callActive))
		select {
		case <-timer.C:
			a.refreshCalls()
		case <-a.callRefresh:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			a.refreshCalls()
		}
	}
}

func callPollInterval(eventDriven, callActive bool) time.Duration {
	if callActive {
		return 2 * time.Second
	}
	if eventDriven {
		return 30 * time.Second
	}
	return 5 * time.Second
}

func (a *agent) modemPollLoop() {
	a.refreshModemStatic()
	a.refreshModemDynamic()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		a.refreshModemDynamic()
	}
}

// atKeepaliveLoop replaces the old 0.7.5-era heavy 1-second CLCC polling with
// a lightweight heartbeat. Some QDC507 firmware lets DATA11 become unresponsive
// after a quiet period; one failed probe is retried through a freshly opened fd.
func (a *agent) atKeepaliveLoop() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		if err := probeATWithRecovery(a.at.command); err != nil {
			a.debug.add("at", "recovery", "AT keepalive recovery failed", err.Error(), nil)
		}
	}
}

func (a *agent) smsPollLoop() {
	if a.profile.AndroidTelecom {
		return
	}
	_, _ = a.at.command("AT+CMGF=1", 3*time.Second)
	_, _ = a.at.command(`AT+CNMI=2,1,0,0,0`, 3*time.Second)
	initial := time.NewTimer(15 * time.Second)
	defer initial.Stop()
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	rescanTicker := time.NewTicker(30 * time.Second)
	defer rescanTicker.Stop()
	for {
		select {
		case notice := <-a.smsNotices:
			a.refreshStoredSMS(notice)
		case <-initial.C:
			a.refreshSMSIfIdle()
		case <-ticker.C:
			a.refreshSMSIfIdle()
		case <-rescanTicker.C:
			a.refreshRequestedSMSRescanIfIdle()
		}
	}
}

func (a *agent) health(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	lastError := a.modem.LastError
	cellularState := a.modem.CellularState
	cellularRecovery := a.modem.RecoveryState
	registrationText := a.modem.RegistrationText
	a.mu.RUnlock()
	atHealth := a.at.healthSnapshot()
	hardwareAvailable := a.profile.RequiresModem
	agentHealthy := hardwareAvailable && atHealth.ConsecutiveFailures < 3
	if !hardwareAvailable && a.externalVoiceBackendConfigured() {
		agentHealthy = true
	}
	if hardwareAvailable && atHealth.ConsecutiveFailures < 3 {
		confirmPendingModuleUpdateState()
	}
	lastSuccess := ""
	if !atHealth.LastSuccess.IsZero() {
		lastSuccess = atHealth.LastSuccess.UTC().Format(time.RFC3339Nano)
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"ok":                      agentHealthy,
		"version":                 agentVersion,
		"platform":                a.profile.Platform,
		"runtime_profile":         a.profile.Name,
		"voice_backend":           a.voiceBackendName(),
		"hardware_available":      hardwareAvailable,
		"at_device":               atDevice,
		"uptime_seconds":          int(time.Since(a.started).Seconds()),
		"last_poll_error":         lastError,
		"last_at_success_at":      lastSuccess,
		"at_consecutive_failures": atHealth.ConsecutiveFailures,
		"at_reopen_count":         atHealth.ReopenCount,
		"control_plane":           "local-agent-reachable",
		"cellular_state":          cellularState,
		"cellular_registration":   registrationText,
		"cellular_recovery":       cellularRecovery,
	})
}

func (a *agent) platform(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"os": "linux", "version": agentVersion, "platform": a.profile.Platform,
		"runtime_profile": a.profile.Name, "direct_module": a.profile.DirectModule,
		"voice_backend": a.voiceBackendName(),
		"call_audio":    a.profile.CallAudio || a.externalVoiceBackendConfigured(), "direct_usb_at": false, "native_contacts": a.profile.NativeContacts,
		"network_policy_native": a.profile.NetworkPolicyNative, "wrt_lite": a.profile.WRTLite, "esim_full": false,
	})
}

func (a *agent) status(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	a.mu.RLock()
	status := a.modem
	a.mu.RUnlock()
	writeJSON(response, http.StatusOK, status)
}

func (a *agent) networkTraffic(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	rx, tx, err := readInterfaceCounters("ecm0")
	if err != nil {
		writeJSON(response, http.StatusOK, map[string]any{"available": false, "error": err.Error()})
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"available": true, "interface": "ecm0", "rx_bytes": rx, "tx_bytes": tx,
		"session_rx_bytes": rx - min(rx, a.rxStart), "session_tx_bytes": tx - min(tx, a.txStart),
		"session_total_bytes": rx - min(rx, a.rxStart) + tx - min(tx, a.txStart),
		"sampled_at_ms":       time.Now().UnixMilli(),
	})
}

func readInterfaceCounters(name string) (uint64, uint64, error) {
	read := func(counter string) (uint64, error) {
		data, err := os.ReadFile(filepath.Join("/sys/class/net", name, "statistics", counter))
		if err != nil {
			return 0, err
		}
		return strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
	}
	rx, err := read("rx_bytes")
	if err != nil {
		return 0, 0, err
	}
	tx, err := read("tx_bytes")
	return rx, tx, err
}

func min(a, b uint64) uint64 {
	if a < b {
		return a
	}
	return b
}

func requireMethod(response http.ResponseWriter, request *http.Request, methods ...string) bool {
	for _, method := range methods {
		if request.Method == method {
			return true
		}
	}
	writeError(response, http.StatusMethodNotAllowed, "请求方法不受支持")
	return false
}

func decodeJSON(response http.ResponseWriter, request *http.Request, target any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeError(response, http.StatusBadRequest, "JSON 请求无效: "+err.Error())
		return false
	}
	return true
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func writeError(response http.ResponseWriter, status int, message string) {
	writeJSON(response, status, map[string]string{"error": message})
}

func (a *agent) unsupported(response http.ResponseWriter, message string) {
	writeError(response, http.StatusNotImplemented, message)
}

func commandValue(response string, prefix string) string {
	for _, line := range strings.Split(response, "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

func parseInt(value string) int {
	number, _ := strconv.Atoi(strings.TrimSpace(value))
	return number
}

func splitCSV(value string) []string {
	var fields []string
	var current strings.Builder
	quoted := false
	for _, character := range value {
		switch character {
		case '"':
			quoted = !quoted
		case ',':
			if !quoted {
				fields = append(fields, strings.TrimSpace(current.String()))
				current.Reset()
				continue
			}
			current.WriteRune(character)
		default:
			current.WriteRune(character)
		}
	}
	fields = append(fields, strings.TrimSpace(current.String()))
	return fields
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func firstLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && line != "OK" && !strings.HasPrefix(line, "AT") {
			return line
		}
	}
	return ""
}

func formatError(operation string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", operation, err)
}
