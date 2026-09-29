package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os/exec"
	"strings"
	"time"
)

type systemInstallerBackend struct {
	healthURL string
}

func (backend systemInstallerBackend) packageMetadata(path string) (packageMetadata, error) {
	name, err := dpkgField(path, "Package")
	if err != nil {
		return packageMetadata{}, err
	}
	architecture, err := dpkgField(path, "Architecture")
	if err != nil {
		return packageMetadata{}, err
	}
	version, err := dpkgField(path, "Version")
	if err != nil {
		return packageMetadata{}, err
	}
	return packageMetadata{Name: name, Architecture: architecture, Version: version}, nil
}

func dpkgField(path, field string) (string, error) {
	output, err := exec.Command("dpkg-deb", "--field", path, field).Output()
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(output))
	if value == "" || strings.ContainsAny(value, "\r\n") {
		return "", errors.New("unexpected dpkg-deb metadata")
	}
	return value, nil
}

func (backend systemInstallerBackend) installedVersion() (string, error) {
	output, err := exec.Command("dpkg-query", "--show", "--showformat=${Version}", expectedPackageName).Output()
	return strings.TrimSpace(string(output)), err
}

func (backend systemInstallerBackend) install(path string) error {
	command := exec.Command("dpkg", "--install", path)
	output, err := command.CombinedOutput()
	if err != nil {
		return errors.New(strings.TrimSpace(string(output)))
	}
	return nil
}

func (backend systemInstallerBackend) restartAgent() error {
	return exec.Command("systemctl", "restart", "airsim-agent.service").Run()
}

func (backend systemInstallerBackend) compareVersions(left, right string) (int, error) {
	for relation, operator := range map[int]string{0: "eq", 1: "gt", -1: "lt"} {
		if exec.Command("dpkg", "--compare-versions", left, operator, right).Run() == nil {
			return relation, nil
		}
	}
	return 0, errors.New("dpkg could not compare versions")
}

func (backend systemInstallerBackend) agentHealthy(version string) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	for attempt := 0; attempt < 10; attempt++ {
		response, err := client.Get(backend.healthURL)
		if err == nil {
			var payload struct {
				OK      bool   `json:"ok"`
				Version string `json:"version"`
			}
			decodeErr := json.NewDecoder(response.Body).Decode(&payload)
			response.Body.Close()
			if decodeErr == nil && response.StatusCode == http.StatusOK && payload.OK && payload.Version == version {
				return true
			}
		}
		time.Sleep(time.Second)
	}
	return false
}
