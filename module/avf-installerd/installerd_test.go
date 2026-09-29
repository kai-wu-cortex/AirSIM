package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeInstallerBackend struct {
	metadata           packageMetadata
	installed          string
	healthyVersion     string
	installFailVersion string
	installHistory     []string
	healthHistory      []string
}

func (backend *fakeInstallerBackend) packageMetadata(path string) (packageMetadata, error) {
	metadata := backend.metadata
	if payload, err := os.ReadFile(path); err == nil && string(payload) == "old-package" {
		metadata.Version = "1.0.0-1"
	}
	return metadata, nil
}

func (backend *fakeInstallerBackend) installedVersion() (string, error) {
	return backend.installed, nil
}

func (backend *fakeInstallerBackend) install(path string) error {
	metadata := backend.metadata
	if payload, err := os.ReadFile(path); err == nil && string(payload) == "old-package" {
		metadata.Version = "1.0.0-1"
	}
	backend.installHistory = append(backend.installHistory, metadata.Version)
	if metadata.Version == backend.installFailVersion {
		return errors.New("simulated dpkg failure")
	}
	backend.installed = metadata.Version
	return nil
}

func TestDpkgFailureRestoresRetainedPackage(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	stateDirectory := t.TempDir()
	packages := filepath.Join(stateDirectory, "packages")
	if err := os.MkdirAll(packages, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packages, "current.deb"), []byte("old-package"), 0o600); err != nil {
		t.Fatal(err)
	}
	payload := []byte("new-package")
	backend := &fakeInstallerBackend{
		metadata:  packageMetadata{Name: "airsim-avf-agent", Architecture: "arm64", Version: "2.0.0-1"},
		installed: "1.0.0-1", healthyVersion: "1.0.0", installFailVersion: "2.0.0-1",
	}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey, StateDirectory: stateDirectory,
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader(payload))
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	request.Header.Set("Content-Type", debianPackageContentType)
	request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)))
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("dpkg failure status=%d body=%s", response.Code, response.Body.String())
	}
	if backend.installed != "1.0.0-1" || len(backend.installHistory) != 2 {
		t.Fatalf("dpkg failure restore installed=%q history=%v", backend.installed, backend.installHistory)
	}
}

func (backend *fakeInstallerBackend) restartAgent() error { return nil }

func (backend *fakeInstallerBackend) agentHealthy(version string) bool {
	backend.healthHistory = append(backend.healthHistory, version)
	return version == backend.healthyVersion
}

func (backend *fakeInstallerBackend) compareVersions(left, right string) (int, error) {
	return strings.Compare(left, right), nil
}

func TestAgentVersionForPackageRelease(t *testing.T) {
	for input, expected := range map[string]string{
		"0.4.2-1":     "0.4.2",
		"1:0.4.2-3":   "0.4.2",
		"0.4.2~rc1-2": "0.4.2~rc1",
		"0.4.2":       "0.4.2",
	} {
		if actual := agentVersionForPackage(input); actual != expected {
			t.Errorf("agentVersionForPackage(%q)=%q, want %q", input, actual, expected)
		}
	}
}

func TestInstallRejectsPackageWithoutValidSignature(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	backend := &fakeInstallerBackend{metadata: packageMetadata{
		Name: "airsim-avf-agent", Architecture: "arm64", Version: "1.0.0-1",
	}}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey,
		StateDirectory: t.TempDir(),
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader([]byte("deb-package")))
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	request.Header.Set("Content-Type", debianPackageContentType)
	request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize)))
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("invalid signature status=%d body=%s", response.Code, response.Body.String())
	}
	if backend.installed != "" {
		t.Fatalf("invalid signature installed version %q", backend.installed)
	}
}

func TestInstallAcceptsSignedAirSIMArm64Package(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("signed-deb-package")
	backend := &fakeInstallerBackend{
		metadata:       packageMetadata{Name: "airsim-avf-agent", Architecture: "arm64", Version: "1.2.0-1"},
		healthyVersion: "1.2.0",
	}
	stateDirectory := t.TempDir()
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey,
		StateDirectory: stateDirectory,
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader(payload))
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	request.Header.Set("Content-Type", debianPackageContentType)
	request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)))
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("signed package status=%d body=%s", response.Code, response.Body.String())
	}
	if backend.installed != "1.2.0-1" {
		t.Fatalf("installed=%q", backend.installed)
	}
	if _, err := os.Stat(filepath.Join(stateDirectory, "packages", "current.deb")); err != nil {
		t.Fatalf("successful package was not retained for rollback: %v", err)
	}
}

func TestInstallRejectsWrongPackageIdentity(t *testing.T) {
	for _, metadata := range []packageMetadata{
		{Name: "other-agent", Architecture: "arm64", Version: "1.0.0-1"},
		{Name: "airsim-avf-agent", Architecture: "amd64", Version: "1.0.0-1"},
	} {
		t.Run(metadata.Name+"-"+metadata.Architecture, func(t *testing.T) {
			publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			payload := []byte("wrong-package")
			backend := &fakeInstallerBackend{metadata: metadata}
			server := newInstallerServer(installerConfig{
				Token: "test-installer-token-1234567890", PublicKey: publicKey,
				StateDirectory: t.TempDir(),
			}, backend)
			request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader(payload))
			request.RemoteAddr = "172.29.240.24:42000"
			request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
			request.Header.Set("Content-Type", debianPackageContentType)
			request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)))
			response := httptest.NewRecorder()

			server.ServeHTTP(response, request)

			if response.Code != http.StatusBadRequest {
				t.Fatalf("wrong package status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestInstalledAgentRequiresBootstrapRollbackPackage(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("signed-deb-package")
	backend := &fakeInstallerBackend{
		metadata:  packageMetadata{Name: "airsim-avf-agent", Architecture: "arm64", Version: "1.2.0-1"},
		installed: "1.0.0-1",
	}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey,
		StateDirectory: t.TempDir(),
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader(payload))
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	request.Header.Set("Content-Type", debianPackageContentType)
	request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)))
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusConflict {
		t.Fatalf("missing bootstrap rollback package status=%d body=%s", response.Code, response.Body.String())
	}
	if len(backend.installHistory) != 0 {
		t.Fatalf("unsafe first update installed package: %v", backend.installHistory)
	}
}

func TestNormalInstallRejectsDowngrade(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	stateDirectory := t.TempDir()
	if err := os.MkdirAll(filepath.Join(stateDirectory, "packages"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDirectory, "packages", "current.deb"), []byte("current-package"), 0o600); err != nil {
		t.Fatal(err)
	}
	payload := []byte("downgrade-package")
	backend := &fakeInstallerBackend{
		metadata:  packageMetadata{Name: "airsim-avf-agent", Architecture: "arm64", Version: "1.0.0-1"},
		installed: "2.0.0-1",
	}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey, StateDirectory: stateDirectory,
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader(payload))
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	request.Header.Set("Content-Type", debianPackageContentType)
	request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)))
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusConflict || len(backend.installHistory) != 0 {
		t.Fatalf("downgrade status=%d installs=%v body=%s", response.Code, backend.installHistory, response.Body.String())
	}
}

func TestFailedHealthCheckRollsBackToRetainedPackage(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	stateDirectory := t.TempDir()
	packages := filepath.Join(stateDirectory, "packages")
	if err := os.MkdirAll(packages, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packages, "current.deb"), []byte("old-package"), 0o600); err != nil {
		t.Fatal(err)
	}
	payload := []byte("new-package")
	backend := &fakeInstallerBackend{
		metadata:  packageMetadata{Name: "airsim-avf-agent", Architecture: "arm64", Version: "2.0.0-1"},
		installed: "1.0.0-1", healthyVersion: "1.0.0",
	}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey,
		StateDirectory: stateDirectory,
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/install", bytes.NewReader(payload))
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	request.Header.Set("Content-Type", debianPackageContentType)
	request.Header.Set("X-AirSIM-Signature", base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)))
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusBadGateway {
		t.Fatalf("failed health status=%d body=%s", response.Code, response.Body.String())
	}
	if backend.installed != "1.0.0-1" {
		t.Fatalf("rollback installed=%q", backend.installed)
	}
	if len(backend.installHistory) != 2 || backend.installHistory[0] != "2.0.0-1" || backend.installHistory[1] != "1.0.0-1" {
		t.Fatalf("install history=%v", backend.installHistory)
	}
	if len(backend.healthHistory) != 2 || backend.healthHistory[0] != "2.0.0" || backend.healthHistory[1] != "1.0.0" {
		t.Fatalf("health history=%v", backend.healthHistory)
	}
}

func TestManualRollbackSwapsRetainedPackages(t *testing.T) {
	stateDirectory := t.TempDir()
	packages := filepath.Join(stateDirectory, "packages")
	if err := os.MkdirAll(packages, 0o700); err != nil {
		t.Fatal(err)
	}
	currentPath := filepath.Join(packages, "current.deb")
	previousPath := filepath.Join(packages, "previous.deb")
	if err := os.WriteFile(currentPath, []byte("new-package"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(previousPath, []byte("old-package"), 0o600); err != nil {
		t.Fatal(err)
	}
	backend := &fakeInstallerBackend{
		metadata:  packageMetadata{Name: "airsim-avf-agent", Architecture: "arm64", Version: "2.0.0-1"},
		installed: "2.0.0-1", healthyVersion: "1.0.0",
	}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: make(ed25519.PublicKey, ed25519.PublicKeySize),
		StateDirectory: stateDirectory,
	}, backend)
	request := httptest.NewRequest(http.MethodPost, "/v1/packages/rollback", nil)
	request.RemoteAddr = "172.29.240.24:42000"
	request.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	response := httptest.NewRecorder()

	server.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("rollback status=%d body=%s", response.Code, response.Body.String())
	}
	current, _ := os.ReadFile(currentPath)
	previous, _ := os.ReadFile(previousPath)
	if string(current) != "old-package" || string(previous) != "new-package" {
		t.Fatalf("retained packages current=%q previous=%q", current, previous)
	}
}

func TestInstallerRejectsUnauthenticatedAndPublicPeers(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newInstallerServer(installerConfig{
		Token: "test-installer-token-1234567890", PublicKey: publicKey,
		StateDirectory: t.TempDir(),
	}, &fakeInstallerBackend{})

	missingToken := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	missingToken.RemoteAddr = "172.29.240.24:42000"
	missingTokenResponse := httptest.NewRecorder()
	server.ServeHTTP(missingTokenResponse, missingToken)
	if missingTokenResponse.Code != http.StatusUnauthorized {
		t.Fatalf("missing token status=%d", missingTokenResponse.Code)
	}

	publicPeer := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	publicPeer.RemoteAddr = "203.0.113.9:42000"
	publicPeer.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	publicPeerResponse := httptest.NewRecorder()
	server.ServeHTTP(publicPeerResponse, publicPeer)
	if publicPeerResponse.Code != http.StatusForbidden {
		t.Fatalf("public peer status=%d", publicPeerResponse.Code)
	}

	lanPeer := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	lanPeer.RemoteAddr = "192.168.1.20:42000"
	lanPeer.Header.Set("Authorization", "Bearer test-installer-token-1234567890")
	lanPeerResponse := httptest.NewRecorder()
	server.ServeHTTP(lanPeerResponse, lanPeer)
	if lanPeerResponse.Code != http.StatusForbidden {
		t.Fatalf("LAN peer status=%d", lanPeerResponse.Code)
	}
}
