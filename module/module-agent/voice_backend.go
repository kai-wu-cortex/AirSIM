package main

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
)

type voiceBackendKind string

const (
	voiceBackendQDC507         voiceBackendKind = "qdc507"
	voiceBackendSamsungAndroid voiceBackendKind = "samsung_android"
	qdc507PCMEndpoint                           = "192.168.225.1:7580"
)

type voiceBackendConfig struct {
	kind     voiceBackendKind
	endpoint string
}

func loadVoiceBackend(getenv func(string) string) (voiceBackendConfig, error) {
	kind := voiceBackendKind(strings.TrimSpace(getenv("AIRSIM_VOICE_BACKEND")))
	if kind == "" {
		kind = voiceBackendSamsungAndroid
	}
	switch kind {
	case voiceBackendQDC507:
		return voiceBackendConfig{kind: kind, endpoint: qdc507PCMEndpoint}, nil
	case voiceBackendSamsungAndroid:
		endpoint := strings.TrimSpace(getenv("AIRSIM_SAMSUNG_PCM_ADDRESS"))
		if err := validateSamsungPCMEndpoint(endpoint); err != nil {
			return voiceBackendConfig{}, err
		}
		return voiceBackendConfig{kind: kind, endpoint: endpoint}, nil
	default:
		return voiceBackendConfig{}, fmt.Errorf("不支持的语音后端 %q", kind)
	}
}

func (config voiceBackendConfig) requiresLocalRuntime() bool {
	return config.kind == voiceBackendQDC507
}

func (a *agent) voicePCMEndpoint() (string, error) {
	if a.voiceBackendErr != nil {
		return "", a.voiceBackendErr
	}
	if a.voiceBackend.kind == "" && a.voiceBackend.endpoint == "" {
		return "", errors.New("AirSIM 三星 PCM 端点未配置")
	}
	if a.voiceBackend.endpoint == "" {
		return "", errors.New("语音 PCM 端点未配置")
	}
	if a.voiceBackend.kind == voiceBackendSamsungAndroid && a.profile.AndroidTelecom {
		readRoute := a.defaultRoute
		if readRoute == nil {
			readRoute = readDefaultRoute
		}
		if endpoint := samsungPCMEndpointForRoute(a.voiceBackend.endpoint, readRoute()); endpoint != "" {
			return endpoint, nil
		}
	}
	return a.voiceBackend.endpoint, nil
}

func samsungPCMEndpointForRoute(configured string, route map[string]string) string {
	_, port, err := net.SplitHostPort(configured)
	if err != nil {
		return ""
	}
	gateway := strings.TrimSpace(route["gateway"])
	ip := net.ParseIP(gateway)
	if ip == nil || ip.To4() == nil || ip.IsUnspecified() || ip.IsLoopback() || !ip.IsPrivate() {
		return ""
	}
	endpoint := net.JoinHostPort(ip.String(), port)
	if validateSamsungPCMEndpoint(endpoint) != nil {
		return ""
	}
	return endpoint
}

func (a *agent) usesLocalVoiceRuntime() bool {
	return a.voiceBackendErr == nil &&
		a.voiceBackend.requiresLocalRuntime()
}

func (a *agent) voiceBackendName() string {
	if a.voiceBackendErr != nil {
		return "invalid"
	}
	if a.voiceBackend.kind == "" {
		return "unconfigured"
	}
	return string(a.voiceBackend.kind)
}

func (a *agent) externalVoiceBackendConfigured() bool {
	return a.voiceBackendErr == nil && a.voiceBackend.kind == voiceBackendSamsungAndroid
}

func probeVoicePCMBackend(
	endpoint string,
	dial func(network, address string) (net.Conn, error),
) error {
	if err := validateSamsungPCMEndpoint(endpoint); err != nil {
		return err
	}
	connection, err := dial("tcp", endpoint)
	if err != nil {
		return err
	}
	defer connection.Close()
	return cloudPCMHandshake(connection)
}

func validateSamsungPCMEndpoint(endpoint string) error {
	if endpoint == "" {
		return errors.New("三星 PCM 端点不能为空")
	}
	host, portText, err := net.SplitHostPort(endpoint)
	if err != nil {
		return fmt.Errorf("三星 PCM 端点格式无效: %w", err)
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil || ip.IsUnspecified() || ip.IsLoopback() || !ip.IsPrivate() {
		return errors.New("三星 PCM 端点必须是非环回私有 IPv4 地址")
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1024 || port > 65535 {
		return errors.New("三星 PCM 端口必须是 1024..65535")
	}
	return nil
}
