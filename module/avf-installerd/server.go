package main

import (
	"crypto/ed25519"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	debianPackageContentType = "application/vnd.debian.binary-package"
	maximumPackageBytes      = 64 * 1024 * 1024
	expectedPackageName      = "airsim-avf-agent"
	expectedArchitecture     = "arm64"
)

var debianVersionPattern = regexp.MustCompile(`^[0-9][0-9A-Za-z.+:~_-]{0,127}$`)

type packageMetadata struct {
	Name         string `json:"name"`
	Architecture string `json:"architecture"`
	Version      string `json:"version"`
}

type installationState struct {
	Phase             string `json:"phase"`
	InstalledVersion  string `json:"installed_version,omitempty"`
	TargetVersion     string `json:"target_version,omitempty"`
	Message           string `json:"message"`
	Error             string `json:"error,omitempty"`
	RollbackAvailable bool   `json:"rollback_available"`
	UpdatedAt         string `json:"updated_at"`
}

type installerBackend interface {
	packageMetadata(path string) (packageMetadata, error)
	installedVersion() (string, error)
	install(path string) error
	restartAgent() error
	agentHealthy(version string) bool
	compareVersions(left, right string) (int, error)
}

type installerConfig struct {
	Token          string
	PublicKey      ed25519.PublicKey
	StateDirectory string
}

type installerServer struct {
	config  installerConfig
	backend installerBackend
	mu      sync.Mutex
}

func newInstallerServer(config installerConfig, backend installerBackend) http.Handler {
	return &installerServer{config: config, backend: backend}
}

func (server *installerServer) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	if !allowedInstallerPeer(request.RemoteAddr) {
		writeInstallerError(response, http.StatusForbidden, "installer 只接受 AVF 私网或本机连接")
		return
	}
	if !validBearer(request.Header.Get("Authorization"), server.config.Token) {
		response.Header().Set("WWW-Authenticate", "Bearer")
		writeInstallerError(response, http.StatusUnauthorized, "installer 鉴权失败")
		return
	}
	switch request.URL.Path {
	case "/v1/status":
		server.status(response, request)
	case "/v1/packages/install":
		server.install(response, request)
	case "/v1/packages/rollback":
		server.rollback(response, request)
	default:
		writeInstallerError(response, http.StatusNotFound, "installer 路径不存在")
	}
}

func allowedInstallerPeer(remote string) bool {
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
	return v4 != nil && (v4[0] == 10 || (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31))
}

func validBearer(header, expected string) bool {
	const prefix = "Bearer "
	if len(expected) < 24 || !strings.HasPrefix(header, prefix) {
		return false
	}
	provided := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	return len(provided) == len(expected) &&
		subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

func (server *installerServer) status(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeInstallerError(response, http.StatusMethodNotAllowed, "status 只支持 GET")
		return
	}
	state := server.readState()
	if version, err := server.backend.installedVersion(); err == nil {
		state.InstalledVersion = version
	}
	state.RollbackAvailable = fileExists(server.previousPackagePath())
	writeInstallerJSON(response, http.StatusOK, state)
}

func (server *installerServer) install(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writeInstallerError(response, http.StatusMethodNotAllowed, "install 只支持 POST")
		return
	}
	if mediaType := strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]); mediaType != debianPackageContentType {
		writeInstallerError(response, http.StatusUnsupportedMediaType, "安装包 Content-Type 无效")
		return
	}
	signature, err := decodeSignature(request.Header.Get("X-AirSIM-Signature"))
	if err != nil {
		writeInstallerError(response, http.StatusBadRequest, err.Error())
		return
	}
	payload, err := io.ReadAll(io.LimitReader(request.Body, maximumPackageBytes+1))
	if err != nil {
		writeInstallerError(response, http.StatusBadRequest, "读取安装包失败")
		return
	}
	if len(payload) == 0 || len(payload) > maximumPackageBytes {
		writeInstallerError(response, http.StatusRequestEntityTooLarge, "安装包为空或超过 64 MiB")
		return
	}
	if len(server.config.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(server.config.PublicKey, payload, signature) {
		writeInstallerError(response, http.StatusBadRequest, "安装包签名无效")
		return
	}

	server.mu.Lock()
	defer server.mu.Unlock()
	if err := os.MkdirAll(filepath.Join(server.config.StateDirectory, "packages"), 0o700); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "无法准备 installer 状态目录")
		return
	}
	stagedPath := filepath.Join(server.config.StateDirectory, "packages", "staged.deb")
	if err := writeAtomic(stagedPath, payload, 0o600); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "无法保存安装包")
		return
	}
	defer os.Remove(stagedPath)
	metadata, err := server.backend.packageMetadata(stagedPath)
	if err != nil {
		writeInstallerError(response, http.StatusBadRequest, "无法读取 Debian 包元数据")
		return
	}
	if err := validatePackageMetadata(metadata); err != nil {
		writeInstallerError(response, http.StatusBadRequest, err.Error())
		return
	}
	mode := strings.TrimSpace(request.Header.Get("X-AirSIM-Install-Mode"))
	if mode == "" {
		mode = "normal"
	}
	if mode != "normal" && mode != "repair" {
		writeInstallerError(response, http.StatusBadRequest, "安装模式必须是 normal 或 repair")
		return
	}
	currentPath := server.currentPackagePath()
	installedVersion, installedErr := server.backend.installedVersion()
	if installedErr == nil && installedVersion != "" && !fileExists(currentPath) {
		writeInstallerError(response, http.StatusConflict,
			"缺少首次安装包，拒绝无回滚点升级；请重新执行一次性 AVF 引导")
		return
	}
	if installedErr == nil && installedVersion != "" {
		relation, compareErr := server.backend.compareVersions(metadata.Version, installedVersion)
		if compareErr != nil {
			writeInstallerError(response, http.StatusInternalServerError, "无法比较 Debian 包版本")
			return
		}
		if mode == "normal" && relation <= 0 {
			writeInstallerError(response, http.StatusConflict, "normal 模式只接受高于当前版本的签名包")
			return
		}
		if mode == "repair" && relation != 0 {
			writeInstallerError(response, http.StatusConflict, "repair 模式只接受与当前版本相同的签名包")
			return
		}
	} else if mode == "repair" {
		writeInstallerError(response, http.StatusConflict, "未安装 Agent 时不能使用 repair 模式")
		return
	}
	server.writeState(installationState{
		Phase: "installing", TargetVersion: metadata.Version,
		Message: "签名与 arm64 包身份验证通过，正在安装",
	})

	previousPath := server.previousPackagePath()
	if fileExists(currentPath) {
		if err := copyFileAtomic(currentPath, previousPath); err != nil {
			writeInstallerError(response, http.StatusInternalServerError, "无法创建回滚包")
			return
		}
	}
	if err := server.backend.install(stagedPath); err != nil {
		installErr := err
		if fileExists(previousPath) {
			previousMetadata, metadataErr := server.backend.packageMetadata(previousPath)
			if metadataErr == nil && validatePackageMetadata(previousMetadata) == nil {
				restoreErr := server.backend.install(previousPath)
				if restoreErr == nil {
					restoreErr = server.backend.restartAgent()
				}
				if restoreErr == nil && !server.backend.agentHealthy(agentVersionForPackage(previousMetadata.Version)) {
					restoreErr = errors.New("恢复版本健康检查失败")
				}
				if restoreErr != nil {
					installErr = errors.Join(installErr, fmt.Errorf("恢复失败: %w", restoreErr))
				} else {
					_ = os.Remove(previousPath)
				}
			} else {
				installErr = errors.Join(installErr, errors.New("回滚包元数据无效"))
			}
		}
		server.failState(metadata.Version, "dpkg 安装失败，已尝试恢复当前版本", installErr)
		writeInstallerError(response, http.StatusInternalServerError, "Debian 包安装失败")
		return
	}
	agentVersion := agentVersionForPackage(metadata.Version)
	if err := server.backend.restartAgent(); err != nil || !server.backend.agentHealthy(agentVersion) {
		healthErr := err
		if healthErr == nil {
			healthErr = errors.New("新 Agent 健康检查失败")
		}
		if fileExists(previousPath) {
			previousMetadata, metadataErr := server.backend.packageMetadata(previousPath)
			if metadataErr != nil || validatePackageMetadata(previousMetadata) != nil {
				healthErr = errors.Join(healthErr, errors.New("回滚包元数据无效"))
				server.failState(metadata.Version, "新版本不健康且回滚包无效", healthErr)
				writeInstallerError(response, http.StatusInternalServerError, "新版本不健康且回滚包无效")
				return
			}
			rollbackErr := server.backend.install(previousPath)
			if rollbackErr == nil {
				rollbackErr = server.backend.restartAgent()
			}
			if rollbackErr == nil && !server.backend.agentHealthy(agentVersionForPackage(previousMetadata.Version)) {
				rollbackErr = errors.New("回滚 Agent 健康检查失败")
			}
			if rollbackErr != nil {
				healthErr = errors.Join(healthErr, fmt.Errorf("回滚失败: %w", rollbackErr))
				server.failState(metadata.Version, "新版本不健康且回滚失败", healthErr)
				writeInstallerError(response, http.StatusInternalServerError, "新版本不健康且回滚失败")
				return
			}
			_ = os.Remove(previousPath)
			server.writeState(installationState{
				Phase: "rolled_back", TargetVersion: metadata.Version,
				Message: "新 Agent 健康检查失败，已恢复上一版本",
				Error:   healthErr.Error(), RollbackAvailable: false,
			})
			writeInstallerError(response, http.StatusBadGateway, "新 Agent 健康检查失败，已自动回滚")
			return
		}
		server.failState(metadata.Version, "新 Agent 健康检查失败且没有回滚包", healthErr)
		writeInstallerError(response, http.StatusBadGateway, "新 Agent 健康检查失败且没有回滚包")
		return
	}
	if err := copyFileAtomic(stagedPath, currentPath); err != nil {
		server.failState(metadata.Version, "Agent 已运行，但无法保留回滚包", err)
		writeInstallerError(response, http.StatusInternalServerError, "无法保留已安装包")
		return
	}
	state := installationState{
		Phase: "completed", InstalledVersion: metadata.Version, TargetVersion: metadata.Version,
		Message:           "AirSIM AVF Agent 安装并通过健康检查",
		RollbackAvailable: fileExists(previousPath),
	}
	server.writeState(state)
	writeInstallerJSON(response, http.StatusOK, state)
}

func (server *installerServer) rollback(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writeInstallerError(response, http.StatusMethodNotAllowed, "rollback 只支持 POST")
		return
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	previousPath := server.previousPackagePath()
	if !fileExists(previousPath) {
		writeInstallerError(response, http.StatusConflict, "没有可用的回滚包")
		return
	}
	metadata, err := server.backend.packageMetadata(previousPath)
	if err != nil || validatePackageMetadata(metadata) != nil {
		writeInstallerError(response, http.StatusInternalServerError, "回滚包元数据无效")
		return
	}
	if err := server.backend.install(previousPath); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "回滚安装失败")
		return
	}
	if err := server.backend.restartAgent(); err != nil || !server.backend.agentHealthy(agentVersionForPackage(metadata.Version)) {
		writeInstallerError(response, http.StatusBadGateway, "回滚版本健康检查失败")
		return
	}
	if err := swapRetainedPackages(server.currentPackagePath(), previousPath); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "Agent 已回滚，但无法交换保留包")
		return
	}
	state := installationState{
		Phase: "completed", InstalledVersion: metadata.Version, TargetVersion: metadata.Version,
		Message: "已回滚并通过健康检查", RollbackAvailable: true,
	}
	server.writeState(state)
	writeInstallerJSON(response, http.StatusOK, state)
}

func decodeSignature(value string) ([]byte, error) {
	signature, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(signature) != ed25519.SignatureSize {
		return nil, errors.New("缺少有效的 Ed25519 安装包签名")
	}
	return signature, nil
}

func validatePackageMetadata(metadata packageMetadata) error {
	if metadata.Name != expectedPackageName {
		return fmt.Errorf("只允许安装 %s", expectedPackageName)
	}
	if metadata.Architecture != expectedArchitecture {
		return errors.New("只允许安装 arm64 Debian 包")
	}
	if !debianVersionPattern.MatchString(metadata.Version) {
		return errors.New("Debian 包版本无效")
	}
	return nil
}

// agentVersionForPackage converts a Debian package version such as 0.4.2-1
// into the upstream version reported by the Agent health endpoint.
func agentVersionForPackage(version string) string {
	if epoch := strings.IndexByte(version, ':'); epoch >= 0 {
		version = version[epoch+1:]
	}
	if revision := strings.LastIndexByte(version, '-'); revision >= 0 {
		version = version[:revision]
	}
	return version
}

func (server *installerServer) currentPackagePath() string {
	return filepath.Join(server.config.StateDirectory, "packages", "current.deb")
}

func (server *installerServer) previousPackagePath() string {
	return filepath.Join(server.config.StateDirectory, "packages", "previous.deb")
}

func (server *installerServer) statePath() string {
	return filepath.Join(server.config.StateDirectory, "state.json")
}

func (server *installerServer) readState() installationState {
	data, err := os.ReadFile(server.statePath())
	if err != nil {
		return installationState{Phase: "idle", Message: "等待 Android App 管理", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
	}
	var state installationState
	if json.Unmarshal(data, &state) != nil || state.Phase == "" {
		return installationState{Phase: "idle", Message: "installer 状态需要重建", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
	}
	return state
}

func (server *installerServer) writeState(state installationState) {
	state.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	state.RollbackAvailable = state.RollbackAvailable || fileExists(server.previousPackagePath())
	data, err := json.Marshal(state)
	if err == nil {
		_ = os.MkdirAll(server.config.StateDirectory, 0o700)
		_ = writeAtomic(server.statePath(), append(data, '\n'), 0o600)
	}
}

func (server *installerServer) failState(target, message string, err error) {
	state := installationState{Phase: "failed", TargetVersion: target, Message: message}
	if err != nil {
		state.Error = err.Error()
	}
	server.writeState(state)
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".airsim-write-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err = temporary.Write(data); err == nil {
		err = temporary.Sync()
	}
	closeErr := temporary.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporaryPath, path)
}

func copyFileAtomic(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return writeAtomic(destination, data, 0o600)
}

func swapRetainedPackages(currentPath, previousPath string) error {
	temporaryPath := filepath.Join(filepath.Dir(currentPath), ".swap.deb")
	_ = os.Remove(temporaryPath)
	if err := os.Rename(currentPath, temporaryPath); err != nil {
		return err
	}
	if err := os.Rename(previousPath, currentPath); err != nil {
		_ = os.Rename(temporaryPath, currentPath)
		return err
	}
	if err := os.Rename(temporaryPath, previousPath); err != nil {
		_ = os.Rename(currentPath, previousPath)
		_ = os.Rename(temporaryPath, currentPath)
		return err
	}
	return nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func writeInstallerJSON(response http.ResponseWriter, status int, value any) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func writeInstallerError(response http.ResponseWriter, status int, message string) {
	writeInstallerJSON(response, status, map[string]string{"error": message})
}
