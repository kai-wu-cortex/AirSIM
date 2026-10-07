package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	moduleUpdateFormat      = 1
	moduleUpdatePlatform    = "qdc507-armv7-linux-3.18.44"
	moduleUpdateContentType = "application/vnd.airsim.update+gzip"
	moduleUpdateMaxBytes    = 16 * 1024 * 1024
)

var moduleUpdateMarker = agentDataDirectory + "/update-pending"

type moduleUpdateManifest struct {
	FormatVersion int                `json:"format_version"`
	Version       string             `json:"version"`
	Platform      string             `json:"platform"`
	Files         []moduleUpdateFile `json:"files"`
}

type moduleUpdateFile struct {
	Name   string `json:"name"`
	Target string `json:"target"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   uint32 `json:"mode"`
}

var moduleUpdateTargets = map[string]struct {
	target string
	mode   uint32
}{
	"qdc507-agent":            {target: "bin/qdc507-agent", mode: 0o755},
	"qdc507_data11_bridge.ko": {target: "kernel/qdc507_data11_bridge.ko", mode: 0o644},
	"qdc507_aprv3.ko":         {target: "voice-runtime/qdc507_aprv3.ko", mode: 0o644},
	"qdc507_voice.ko":         {target: "voice-runtime/qdc507_voice.ko", mode: 0o644},
	voiceHelperName:           {target: "voice-runtime/" + voiceHelperName, mode: 0o755},
}

func (a *agent) systemUpdate(response http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodGet {
		publicKey, err := moduleUpdatePublicKey()
		if err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		keyID := sha256.Sum256(publicKey)
		a.mu.RLock()
		callActive := a.calls.Active != nil
		a.mu.RUnlock()
		writeJSON(response, http.StatusOK, map[string]any{
			"supported": true, "format_version": moduleUpdateFormat,
			"platform": moduleUpdatePlatform, "installed_version": agentVersion,
			"public_key_id":   hex.EncodeToString(keyID[:8]),
			"data_free_bytes": filesystemFreeBytes(agentDataDirectory),
			"temp_free_bytes": filesystemFreeBytes("/data/local/tmp"),
			"call_active":     callActive, "update_pending": fileExists(moduleUpdateMarker),
			"agent_pid": os.Getpid(), "factory_service_pid": processID("ql_manager_server"),
		})
		return
	}
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if !moduleUpdateRunMu.TryLock() {
		writeError(response, http.StatusConflict, "已有 Agent 安装正在进行")
		return
	}
	defer moduleUpdateRunMu.Unlock()
	mode := strings.TrimSpace(request.Header.Get("X-AirSIM-Update-Mode"))
	if mode == "" {
		mode = "normal"
	}
	if mode != "normal" && mode != "repair" {
		writeError(response, http.StatusBadRequest, "Agent 安装模式无效")
		return
	}
	operationID := fmt.Sprintf("update-%d", time.Now().UnixNano())
	updateModuleInstallState(operationID, mode, "uploading", "", 5, "正在接收签名安装包", nil, false)
	if mediaType := strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]); mediaType != moduleUpdateContentType {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "安装包类型无效", errors.New("模块更新包 Content-Type 无效"), false)
		writeError(response, http.StatusUnsupportedMediaType, "模块更新包 Content-Type 无效")
		return
	}

	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	a.voice.mu.Lock()
	voiceActive := a.voice.command != nil || a.voice.routeCommand != nil
	a.voice.mu.Unlock()
	if callActive || voiceActive {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "通话或语音运行期间拒绝安装", errors.New("通话或语音桥运行期间禁止更新模块"), false)
		writeError(response, http.StatusConflict, "通话或语音桥运行期间禁止更新模块")
		return
	}
	// 自动升级和手动修复都可能接在一次失败安装之后。先删除仅由更新器创建的
	// 上传缓存、暂存目录和已失效备份，避免 App 还没开始写新包就被旧残留占满。
	// update-pending 指向的有效回滚点会由 cleanup 函数保留。
	before := filesystemFreeBytes(agentDataDirectory)
	if err := cleanupStaleModuleUpdateArtifacts(agentDataDirectory, "/data/local/tmp", moduleUpdateMarker); err != nil {
		appendModuleUpdateLog("low-space cleanup warning: " + err.Error())
	}
	after := filesystemFreeBytes(agentDataDirectory)
	appendModuleUpdateLog(fmt.Sprintf(
		"low-space preflight mode=%s content_length=%d free_before=%d free_after=%d",
		mode, request.ContentLength, before, after,
	))

	request.Body = http.MaxBytesReader(response, request.Body, moduleUpdateMaxBytes)
	temporary, err := os.CreateTemp("/data/local/tmp", "airsim-update-*.tar.gz")
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "无法创建安装缓存", err, false)
		writeError(response, http.StatusInternalServerError, "无法创建更新临时文件: "+err.Error())
		return
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err = io.Copy(temporary, request.Body); err != nil {
		temporary.Close()
		updateModuleInstallState(operationID, mode, "failed", "", 100, "接收安装包失败", err, false)
		writeError(response, http.StatusBadRequest, "读取模块更新包失败: "+err.Error())
		return
	}
	if err = temporary.Sync(); err == nil {
		err = temporary.Close()
	} else {
		_ = temporary.Close()
	}
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "保存安装缓存失败", err, false)
		writeError(response, http.StatusInternalServerError, "保存模块更新包失败: "+err.Error())
		return
	}

	manifest, err := verifyModuleUpdateArchive(temporaryPath)
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "安装包验证失败", err, false)
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	updateModuleInstallState(operationID, mode, "verifying", manifest.Version, 25, "签名、平台与文件摘要验证通过", nil, false)
	if !shouldInstallModuleVersion(agentVersion, manifest.Version, mode) {
		writeJSON(response, http.StatusOK, map[string]any{
			"updated": false, "version": agentVersion, "message": "模块已是相同或更高版本",
		})
		updateModuleInstallState(operationID, mode, "completed", manifest.Version, 100, "模块已是目标版本，无需更新", nil, false)
		return
	}

	updateModuleInstallState(operationID, mode, "installing", manifest.Version, 55, "正在暂存并原子替换 Agent", nil, false)
	backupDirectory, err := installModuleUpdate(temporaryPath, manifest)
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", manifest.Version, 100, "安装失败，现有 Agent 保持不变", err, false)
		writeError(response, http.StatusInternalServerError, "安装模块更新失败: "+err.Error())
		return
	}
	if err := os.WriteFile(moduleUpdateMarker, []byte(backupDirectory+"\n"), 0o600); err != nil {
		if rollbackErr := rollbackModuleUpdate(backupDirectory); rollbackErr != nil {
			updateModuleInstallState(operationID, mode, "failed", manifest.Version, 100, "确认标记和回滚均失败", errors.Join(err, rollbackErr), false)
			writeError(response, http.StatusInternalServerError, fmt.Sprintf("写入更新确认标记失败: %v；回滚也失败: %v", err, rollbackErr))
			return
		}
		updateModuleInstallState(operationID, mode, "rolled_back", manifest.Version, 100, "写入确认标记失败，已恢复旧 Agent", err, true)
		writeError(response, http.StatusInternalServerError, "写入更新确认标记失败，已回滚: "+err.Error())
		return
	}
	updateModuleInstallState(operationID, mode, "restarting", manifest.Version, 80, "Agent 已安装，正在安全重启", nil, false)

	writeJSON(response, http.StatusOK, map[string]any{
		"updated": true, "version": manifest.Version, "restart_required": true,
		"message": "更新已验证并安装，模块代理正在安全重启",
	})
	go func() {
		time.Sleep(750 * time.Millisecond)
		const restartScript = `
/etc/init.d/airsim_agent stop >>/data/airsim/log/update.log 2>&1
sleep 1
/etc/init.d/airsim_agent start >>/data/airsim/log/update.log 2>&1 || exit 1
count=0
while test "$count" -lt 20; do
  if wget -qO- http://127.0.0.1:8575/api/health 2>/dev/null | grep -q '"product":"airsim"'; then
    if test "$(cat /data/airsim/update-pending 2>/dev/null)" = "$1"; then
      rm -f /data/airsim/update-pending
      rm -rf "$1"
      printf 'update-confirmed backup=%s\n' "$1" >>/data/airsim/log/update.log
    fi
    exit 0
  fi
  count=$((count + 1))
  sleep 1
done
exit 1
`
		command := exec.Command("/bin/sh", "-c", restartScript, "airsim-update", backupDirectory)
		_ = command.Start()
	}()
}

// cleanupStaleModuleUpdateArtifacts only removes paths created by previous App
// update attempts. A backup referenced by update-pending is the active rollback
// point and must survive until the restarted Agent confirms health.
func cleanupStaleModuleUpdateArtifacts(dataRoot, temporaryRoot, markerPath string) error {
	pendingBackup := ""
	if marker, err := os.ReadFile(markerPath); err == nil {
		pendingBackup = filepath.Clean(strings.TrimSpace(string(marker)))
	}
	patterns := []string{
		filepath.Join(temporaryRoot, "airsim-update-*.tar.gz"),
		filepath.Join(dataRoot, ".update-stage-*"),
		filepath.Join(dataRoot, "backup", "app-update-*"),
	}
	var cleanupErrors []error
	for _, pattern := range patterns {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			cleanupErrors = append(cleanupErrors, err)
			continue
		}
		for _, match := range matches {
			if pendingBackup != "" && filepath.Clean(match) == pendingBackup {
				continue
			}
			if err := os.RemoveAll(match); err != nil {
				cleanupErrors = append(cleanupErrors, fmt.Errorf("remove %s: %w", match, err))
			}
		}
	}
	return errors.Join(cleanupErrors...)
}

func moduleUpdatePublicKey() (ed25519.PublicKey, error) {
	decoded, err := base64.StdEncoding.DecodeString(moduleUpdatePublicKeyBase64)
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errors.New("模块更新公钥配置无效")
	}
	return ed25519.PublicKey(decoded), nil
}

func verifyModuleUpdateArchive(path string) (moduleUpdateManifest, error) {
	manifestData, signature, err := readModuleUpdateMetadata(path)
	if err != nil {
		return moduleUpdateManifest{}, err
	}
	publicKey, err := moduleUpdatePublicKey()
	if err != nil {
		return moduleUpdateManifest{}, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(publicKey, manifestData, signature) {
		return moduleUpdateManifest{}, errors.New("模块更新包签名无效")
	}

	decoder := json.NewDecoder(strings.NewReader(string(manifestData)))
	decoder.DisallowUnknownFields()
	var manifest moduleUpdateManifest
	if err := decoder.Decode(&manifest); err != nil {
		return moduleUpdateManifest{}, fmt.Errorf("模块更新清单无效: %w", err)
	}
	if err := validateModuleUpdateManifest(manifest); err != nil {
		return moduleUpdateManifest{}, err
	}
	return manifest, nil
}

func readModuleUpdateMetadata(path string) ([]byte, []byte, error) {
	reader, closeReader, err := openModuleUpdateArchive(path)
	if err != nil {
		return nil, nil, err
	}
	defer closeReader()

	manifestHeader, err := reader.Next()
	if err != nil || manifestHeader.Name != "manifest.json" || manifestHeader.Size <= 0 || manifestHeader.Size > 64*1024 {
		return nil, nil, errors.New("模块更新包必须以有效 manifest.json 开始")
	}
	manifestData, err := io.ReadAll(io.LimitReader(reader, manifestHeader.Size))
	if err != nil {
		return nil, nil, fmt.Errorf("读取模块更新清单失败: %w", err)
	}
	signatureHeader, err := reader.Next()
	if err != nil || signatureHeader.Name != "manifest.sig" || signatureHeader.Size != ed25519.SignatureSize {
		return nil, nil, errors.New("模块更新包缺少有效 manifest.sig")
	}
	signature, err := io.ReadAll(io.LimitReader(reader, signatureHeader.Size))
	if err != nil {
		return nil, nil, fmt.Errorf("读取模块更新签名失败: %w", err)
	}
	return manifestData, signature, nil
}

func openModuleUpdateArchive(path string) (*tar.Reader, func(), error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, func() {}, err
	}
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		file.Close()
		return nil, func() {}, fmt.Errorf("模块更新包不是有效 gzip: %w", err)
	}
	closeReader := func() {
		_ = gzipReader.Close()
		_ = file.Close()
	}
	return tar.NewReader(gzipReader), closeReader, nil
}

func validateModuleUpdateManifest(manifest moduleUpdateManifest) error {
	if manifest.FormatVersion != moduleUpdateFormat || manifest.Platform != moduleUpdatePlatform {
		return errors.New("模块更新包格式或硬件平台不匹配")
	}
	if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(manifest.Version) {
		return errors.New("模块更新版本号无效")
	}
	if len(manifest.Files) != len(moduleUpdateTargets) {
		return errors.New("模块更新包文件集合不完整")
	}
	seen := make(map[string]bool, len(manifest.Files))
	var totalSize int64
	for _, item := range manifest.Files {
		target, ok := moduleUpdateTargets[item.Name]
		if !ok || seen[item.Name] || item.Target != target.target || item.Mode != target.mode {
			return fmt.Errorf("模块更新文件 %q 的目标或权限无效", item.Name)
		}
		if item.Size <= 0 || item.Size > moduleUpdateMaxBytes || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(item.SHA256) {
			return fmt.Errorf("模块更新文件 %q 的大小或摘要无效", item.Name)
		}
		seen[item.Name] = true
		totalSize += item.Size
	}
	if totalSize > moduleUpdateMaxBytes {
		return errors.New("模块更新包解压后超过大小限制")
	}
	return nil
}

func installModuleUpdate(path string, manifest moduleUpdateManifest) (string, error) {
	changedFiles, err := moduleUpdateFilesRequiringReplacement(manifest, agentDataDirectory)
	if err != nil {
		return "", err
	}
	changed := make(map[string]bool, len(changedFiles))
	var stagingBytes uint64
	for _, item := range changedFiles {
		changed[item.Name] = true
		stagingBytes += uint64(item.Size)
	}
	const stagingMargin = 256 * 1024
	available := filesystemFreeBytes(agentDataDirectory)
	if stagingBytes+stagingMargin > available {
		return "", fmt.Errorf(
			"差量暂存空间不足: required=%d available=%d: no space left on device",
			stagingBytes+stagingMargin,
			available,
		)
	}
	appendModuleUpdateLog(fmt.Sprintf(
		"delta-stage files=%d bytes=%d free=%d reused=%d",
		len(changedFiles), stagingBytes, available, len(manifest.Files)-len(changedFiles),
	))

	stagingDirectory, err := os.MkdirTemp(agentDataDirectory, ".update-stage-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stagingDirectory)

	manifestFiles := make(map[string]moduleUpdateFile, len(manifest.Files))
	for _, item := range manifest.Files {
		manifestFiles[item.Name] = item
	}
	reader, closeReader, err := openModuleUpdateArchive(path)
	if err != nil {
		return "", err
	}
	defer closeReader()
	seen := make(map[string]bool, len(manifest.Files))
	for {
		header, nextErr := reader.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			return "", nextErr
		}
		if header.Name == "manifest.json" || header.Name == "manifest.sig" {
			continue
		}
		if header.Typeflag != tar.TypeReg || !strings.HasPrefix(header.Name, "payload/") {
			return "", fmt.Errorf("模块更新包包含不允许的归档项: %s", header.Name)
		}
		name := strings.TrimPrefix(header.Name, "payload/")
		item, ok := manifestFiles[name]
		if !ok || seen[name] || header.Size != item.Size {
			return "", fmt.Errorf("模块更新载荷 %q 不在清单中或大小不匹配", name)
		}
		digest := sha256.New()
		var copyErr, syncErr, closeErr error
		if changed[name] {
			destination := filepath.Join(stagingDirectory, name)
			file, createErr := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(item.Mode))
			if createErr != nil {
				return "", createErr
			}
			_, copyErr = io.Copy(io.MultiWriter(file, digest), reader)
			syncErr = file.Sync()
			closeErr = file.Close()
		} else {
			_, copyErr = io.Copy(digest, reader)
		}
		if copyErr != nil || syncErr != nil || closeErr != nil {
			return "", errors.Join(copyErr, syncErr, closeErr)
		}
		if hex.EncodeToString(digest.Sum(nil)) != item.SHA256 {
			return "", fmt.Errorf("模块更新载荷 %q 的 SHA-256 不匹配", name)
		}
		seen[name] = true
	}
	if len(seen) != len(manifest.Files) {
		return "", errors.New("模块更新包缺少清单中的载荷")
	}
	probePath := func(name string) string {
		if changed[name] {
			return filepath.Join(stagingDirectory, name)
		}
		return filepath.Join(agentDataDirectory, manifestFiles[name].Target)
	}
	if output, err := exec.Command(probePath("qdc507-agent"), "--startup-probe", "runtime").CombinedOutput(); err != nil {
		return "", fmt.Errorf("新 Agent 启动探针失败: %v (%s)", err, strings.TrimSpace(string(output)))
	}
	if output, err := exec.Command(probePath(voiceHelperName), "--check").CombinedOutput(); err != nil {
		return "", fmt.Errorf("新 PCM helper 自检失败: %v (%s)", err, strings.TrimSpace(string(output)))
	}

	backupDirectory := filepath.Join(agentDataDirectory, "backup", fmt.Sprintf("app-update-%d", time.Now().Unix()))
	if err := os.MkdirAll(backupDirectory, 0o700); err != nil {
		return "", err
	}
	installed := make([]moduleUpdateFile, 0, len(manifest.Files))
	for _, item := range manifest.Files {
		targetPath := filepath.Join(agentDataDirectory, item.Target)
		backupPath := filepath.Join(backupDirectory, item.Name)
		if !changed[item.Name] {
			// The startup rollback hook expects a complete five-file backup. A
			// hard link satisfies that contract without duplicating unchanged
			// payload bytes on the constrained /data filesystem.
			if err := os.Link(targetPath, backupPath); err != nil {
				_ = restoreInstalledUpdateFiles(backupDirectory, installed)
				return "", fmt.Errorf("建立复用载荷 %s 的零拷贝回滚点失败: %w", item.Name, err)
			}
			continue
		}
		if err := os.Rename(targetPath, backupPath); err != nil {
			_ = restoreInstalledUpdateFiles(backupDirectory, installed)
			return "", fmt.Errorf("备份 %s 失败: %w", item.Name, err)
		}
		if err := os.Rename(filepath.Join(stagingDirectory, item.Name), targetPath); err != nil {
			_ = os.Rename(backupPath, targetPath)
			_ = restoreInstalledUpdateFiles(backupDirectory, installed)
			return "", fmt.Errorf("提交 %s 失败: %w", item.Name, err)
		}
		if err := os.Chmod(targetPath, os.FileMode(item.Mode)); err != nil {
			_ = restoreInstalledUpdateFiles(backupDirectory, append(installed, item))
			return "", fmt.Errorf("设置 %s 权限失败: %w", item.Name, err)
		}
		installed = append(installed, item)
	}
	return backupDirectory, nil
}

func moduleUpdateFilesRequiringReplacement(manifest moduleUpdateManifest, dataRoot string) ([]moduleUpdateFile, error) {
	changed := make([]moduleUpdateFile, 0, len(manifest.Files))
	for _, item := range manifest.Files {
		matches, err := fileMatchesSHA256(filepath.Join(dataRoot, item.Target), item.SHA256)
		if err != nil {
			return nil, fmt.Errorf("读取已安装载荷 %s 失败: %w", item.Name, err)
		}
		if !matches {
			changed = append(changed, item)
		}
	}
	return changed, nil
}

func fileMatchesSHA256(path, expected string) (bool, error) {
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return false, err
	}
	return hex.EncodeToString(digest.Sum(nil)) == expected, nil
}

func restoreInstalledUpdateFiles(backupDirectory string, files []moduleUpdateFile) error {
	var restoreErrors []error
	for index := len(files) - 1; index >= 0; index-- {
		item := files[index]
		targetPath := filepath.Join(agentDataDirectory, item.Target)
		failedPath := targetPath + ".failed"
		_ = os.Remove(failedPath)
		if err := os.Rename(targetPath, failedPath); err != nil && !os.IsNotExist(err) {
			restoreErrors = append(restoreErrors, err)
		}
		if err := os.Rename(filepath.Join(backupDirectory, item.Name), targetPath); err != nil {
			restoreErrors = append(restoreErrors, err)
		}
	}
	return errors.Join(restoreErrors...)
}

func rollbackModuleUpdate(backupDirectory string) error {
	files := make([]moduleUpdateFile, 0, len(moduleUpdateTargets))
	for name, target := range moduleUpdateTargets {
		files = append(files, moduleUpdateFile{Name: name, Target: target.target})
	}
	return restoreInstalledUpdateFiles(backupDirectory, files)
}

func compareModuleVersions(left, right string) int {
	parse := func(value string) [3]int {
		var result [3]int
		parts := strings.Split(value, ".")
		for index := 0; index < len(result) && index < len(parts); index++ {
			result[index], _ = strconv.Atoi(parts[index])
		}
		return result
	}
	lhs, rhs := parse(left), parse(right)
	for index := range lhs {
		if lhs[index] < rhs[index] {
			return -1
		}
		if lhs[index] > rhs[index] {
			return 1
		}
	}
	return 0
}
