package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

const defaultReleasePublicKeyBase64 = "7fGe7k6ZJ5xhU5Uljm97EPKRzfSJUULVnaHpUBT8Gho="

var releasePublicKeyBase64 = defaultReleasePublicKeyBase64

func main() {
	tokenPath := environment("AIRSIM_INSTALLER_TOKEN_FILE", "/var/lib/airsim/control.token")
	tokenData, err := os.ReadFile(tokenPath)
	if err != nil {
		log.Fatalf("读取 installer token 失败: %v", err)
	}
	publicKey, err := decodePublicKey(releasePublicKeyBase64)
	if err != nil {
		log.Fatalf("发行公钥无效: %v", err)
	}
	stateDirectory := environment("AIRSIM_INSTALLER_STATE_DIR", "/var/lib/airsim-installerd")
	server := &http.Server{
		Addr: environment("AIRSIM_INSTALLER_LISTEN", "0.0.0.0:7576"),
		Handler: newInstallerServer(installerConfig{
			Token: strings.TrimSpace(string(tokenData)), PublicKey: publicKey,
			StateDirectory: stateDirectory,
		}, systemInstallerBackend{healthURL: "http://127.0.0.1:7575/api/health"}),
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       90 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	log.Printf("AirSIM installerd 监听 %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func decodePublicKey(value string) (ed25519.PublicKey, error) {
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errors.New("Ed25519 public key must be 32 bytes")
	}
	return ed25519.PublicKey(decoded), nil
}

func environment(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
