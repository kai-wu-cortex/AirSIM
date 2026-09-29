package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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
	moduleUpdateStatePath = agentDataDirectory + "/update-state.json"
	moduleUpdateLogPath   = agentDataDirectory + "/log/update.log"
	moduleUpdateLogMax    = 256 * 1024
	moduleUpdateLogChunk  = 64 * 1024
)

type moduleUpdateState struct {
	OperationID       string    `json:"operation_id"`
	Mode              string    `json:"mode"`
	Phase             string    `json:"phase"`
	InstalledVersion  string    `json:"installed_version"`
	TargetVersion     string    `json:"target_version,omitempty"`
	Progress          int       `json:"progress"`
	Message           string    `json:"message"`
	Error             string    `json:"error,omitempty"`
	RollbackConfirmed bool      `json:"rollback_confirmed"`
	UpdatedAt         time.Time `json:"updated_at"`
}

var (
	moduleUpdateStateMu sync.Mutex
	moduleUpdateRunMu   sync.Mutex
)

func defaultModuleUpdateState() moduleUpdateState {
	return moduleUpdateState{
		Phase: "idle", InstalledVersion: agentVersion,
		Message: "尚未执行安装", UpdatedAt: time.Now().UTC(),
	}
}

func readModuleUpdateState() moduleUpdateState {
	moduleUpdateStateMu.Lock()
	defer moduleUpdateStateMu.Unlock()
	data, err := os.ReadFile(moduleUpdateStatePath)
	if err != nil {
		return defaultModuleUpdateState()
	}
	var state moduleUpdateState
	if json.Unmarshal(data, &state) != nil || state.Phase == "" {
		return defaultModuleUpdateState()
	}
	return state
}

func writeModuleUpdateState(state moduleUpdateState) error {
	moduleUpdateStateMu.Lock()
	defer moduleUpdateStateMu.Unlock()
	state.UpdatedAt = time.Now().UTC()
	if err := os.MkdirAll(filepath.Dir(moduleUpdateStatePath), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	temporary := moduleUpdateStatePath + ".tmp"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(append(data, '\n')); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporary, moduleUpdateStatePath)
}

func updateModuleInstallState(operationID, mode, phase, target string, progress int, message string, installError error, rollback bool) {
	state := moduleUpdateState{
		OperationID: operationID, Mode: mode, Phase: phase,
		InstalledVersion: agentVersion, TargetVersion: target,
		Progress: progress, Message: message, RollbackConfirmed: rollback,
	}
	if installError != nil {
		state.Error = installError.Error()
	}
	_ = writeModuleUpdateState(state)
	appendModuleUpdateLog(formatModuleUpdateLogLine(phase, progress, message, state.Error))
}

func formatModuleUpdateLogLine(phase string, progress int, message, installError string) string {
	line := fmt.Sprintf("phase=%s progress=%d message=%s", phase, progress, message)
	if installError != "" {
		line += " error=" + installError
	}
	return line
}

func appendModuleUpdateLog(message string) {
	moduleUpdateStateMu.Lock()
	defer moduleUpdateStateMu.Unlock()
	_ = os.MkdirAll(filepath.Dir(moduleUpdateLogPath), 0o700)
	line := fmt.Sprintf("%s %s\n", time.Now().UTC().Format(time.RFC3339), strings.ReplaceAll(message, "\n", " "))
	file, err := os.OpenFile(moduleUpdateLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err == nil {
		_, _ = file.WriteString(line)
		_ = file.Close()
	}
	info, err := os.Stat(moduleUpdateLogPath)
	if err != nil || info.Size() <= moduleUpdateLogMax {
		return
	}
	data, err := os.ReadFile(moduleUpdateLogPath)
	if err != nil {
		return
	}
	if len(data) > moduleUpdateLogMax {
		data = data[len(data)-moduleUpdateLogMax:]
		if index := strings.IndexByte(string(data), '\n'); index >= 0 {
			data = data[index+1:]
		}
	}
	_ = os.WriteFile(moduleUpdateLogPath, data, 0o600)
}

func (a *agent) systemUpdateStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	confirmPendingModuleUpdateState()
	writeJSON(response, http.StatusOK, readModuleUpdateState())
}

func (a *agent) systemUpdateLog(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	after, err := strconv.ParseInt(request.URL.Query().Get("after"), 10, 64)
	if request.URL.Query().Get("after") == "" {
		after = 0
		err = nil
	}
	if err != nil || after < 0 {
		writeError(response, http.StatusBadRequest, "日志偏移无效")
		return
	}
	file, err := os.Open(moduleUpdateLogPath)
	if errors.Is(err, os.ErrNotExist) {
		writeJSON(response, http.StatusOK, map[string]any{"text": "", "next_offset": 0, "complete": true})
		return
	}
	if err != nil {
		writeError(response, http.StatusInternalServerError, "无法读取安装日志")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		writeError(response, http.StatusInternalServerError, "无法读取安装日志状态")
		return
	}
	if after > info.Size() {
		after = 0
	}
	if _, err = file.Seek(after, io.SeekStart); err != nil {
		writeError(response, http.StatusInternalServerError, "无法定位安装日志")
		return
	}
	buffer := make([]byte, moduleUpdateLogChunk)
	count, readErr := file.Read(buffer)
	if readErr != nil && !errors.Is(readErr, io.EOF) {
		writeError(response, http.StatusInternalServerError, "无法读取安装日志")
		return
	}
	next := after + int64(count)
	writeJSON(response, http.StatusOK, map[string]any{"text": string(buffer[:count]), "next_offset": next, "complete": next >= info.Size()})
}

func filesystemFreeBytes(path string) uint64 {
	var stat syscall.Statfs_t
	if syscall.Statfs(path, &stat) != nil {
		return 0
	}
	return stat.Bavail * uint64(stat.Bsize)
}

func processID(name string) int {
	output, err := exec.Command("pidof", name).Output()
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(output))
	if len(fields) == 0 {
		return 0
	}
	value, _ := strconv.Atoi(fields[0])
	return value
}

func shouldInstallModuleVersion(installed, target, mode string) bool {
	comparison := compareModuleVersions(target, installed)
	if mode == "repair" {
		// repair is an explicit, user-authorized operation. The archive has
		// already passed Ed25519 verification, so it may repair the same version
		// or intentionally roll back to an older signed release.
		return true
	}
	return comparison > 0
}

func completedModuleUpdateState(state moduleUpdateState, runningVersion string, pendingMarkerPresent bool) (moduleUpdateState, bool) {
	if state.Phase != "restarting" && state.Phase != "verifying_health" {
		return state, false
	}
	// update-pending 是启动脚本持有的回滚锁。只有启动脚本确认新 Agent 的
	// HTTP 控制面持续可达并移除该锁后，状态接口才允许把重启阶段提升为完成。
	// 仅凭新进程报告的版本号不能证明监督器仍然存活。
	if pendingMarkerPresent || strings.TrimSpace(state.OperationID) == "" {
		return state, false
	}
	if strings.TrimSpace(state.TargetVersion) == "" || compareModuleVersions(state.TargetVersion, runningVersion) != 0 {
		return state, false
	}
	state.Phase = "completed"
	state.InstalledVersion = runningVersion
	state.Progress = 100
	state.Message = "新 Agent 健康检查通过"
	state.Error = ""
	state.RollbackConfirmed = false
	return state, true
}

func confirmPendingModuleUpdateState() {
	state, shouldConfirm := completedModuleUpdateState(
		readModuleUpdateState(),
		agentVersion,
		fileExists(moduleUpdateMarker),
	)
	if !shouldConfirm {
		return
	}
	_ = writeModuleUpdateState(state)
	appendModuleUpdateLog(fmt.Sprintf(
		"phase=completed progress=100 message=%s",
		state.Message,
	))
}
