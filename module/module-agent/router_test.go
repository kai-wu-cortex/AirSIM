package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRouterConfigRejectsUnsupportedKernelRateShaping(t *testing.T) {
	config := defaultRouterConfig()
	config.DownloadLimitKbps = 10_000

	err := validateRouterConfig(config, routerCapabilities{RateShaping: false})
	if !errors.Is(err, errRouterRateShapingUnavailable) {
		t.Fatalf("缺少 TBF/HTB 时设置限速应返回能力错误，实际=%v", err)
	}
}

func TestRouterUsageAccumulatorSurvivesInterfaceCounterReset(t *testing.T) {
	usage := routerUsage{LastRXBytes: 1_000, LastTXBytes: 2_000, UsedBytes: 500}
	usage.advance(1_400, 2_600)
	if usage.UsedBytes != 1_500 {
		t.Fatalf("正常采样累计=%d，期望 1500", usage.UsedBytes)
	}

	// 模块重启或网卡重建后内核计数归零；新计数应作为新流量累计，不能发生 uint64 下溢。
	usage.advance(25, 40)
	if usage.UsedBytes != 1_565 {
		t.Fatalf("计数器归零后的累计=%d，期望 1565", usage.UsedBytes)
	}
}

func TestRouterUsageCountsTrafficAfterZeroBaseline(t *testing.T) {
	usage := routerUsage{Period: "2026-08-01", LastRXBytes: 0, LastTXBytes: 0}
	usage.advance(100, 50)
	if usage.UsedBytes != 150 {
		t.Fatalf("零基线后的首批流量=%d，期望 150", usage.UsedBytes)
	}
}

func TestRouterQuotaBlocksOnlyForwardingAfterLimit(t *testing.T) {
	config := defaultRouterConfig()
	config.MonthlyQuotaBytes = 1_000
	config.BlockWhenQuotaExceeded = true

	decision := evaluateRouterForwarding(config, routerUsage{UsedBytes: 1_001})
	if decision.Enabled || decision.Reason != "quota-exceeded" {
		t.Fatalf("超额决策错误: %#v", decision)
	}
	if decision.BlockLocalAgent {
		t.Fatal("流量超额只能关闭转发，不能阻断模块本机 Push/Agent 公网连接")
	}
}

func TestParseRouterClientsMergesDHCPLeaseAndARPState(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	leases := strings.NewReader("1800000300 aa:bb:cc:dd:ee:ff 192.168.225.20 iPhone 01:aa\n")
	arp := strings.NewReader("IP address       HW type     Flags       HW address            Mask     Device\n" +
		"192.168.225.20  0x1         0x2         aa:bb:cc:dd:ee:ff     *        bridge0\n" +
		"192.168.225.21  0x1         0x2         11:22:33:44:55:66     *        ecm0\n")

	clients := parseRouterClients(leases, arp, now)
	if len(clients) != 2 {
		t.Fatalf("客户端数量=%d，期望 2: %#v", len(clients), clients)
	}
	if clients[0].IP != "192.168.225.20" || clients[0].Hostname != "iPhone" || !clients[0].Online || clients[0].LeaseRemainingSeconds != 300 {
		t.Fatalf("DHCP+ARP 合并结果错误: %#v", clients[0])
	}
	if clients[1].IP != "192.168.225.21" || clients[1].Hostname != "" || !clients[1].Online {
		t.Fatalf("仅 ARP 客户端解析错误: %#v", clients[1])
	}
}

func TestBuildRouterRepairPlanIsIdempotentAndNeverRebindsUSB(t *testing.T) {
	config := defaultRouterConfig()
	snapshot := routerSystemSnapshot{
		IPForward: false,
		NATRules:  nil,
		WAN:       "rmnet_data0",
		LAN:       "bridge0",
	}
	plan := buildRouterRepairPlan(config, snapshot)
	want := []routerAction{
		{Kind: "sysctl", Key: "net.ipv4.ip_forward", Value: "1"},
		{Kind: "iptables", Arguments: []string{"-t", "nat", "-A", "POSTROUTING", "-s", "192.168.225.0/24", "-o", "rmnet_data0", "-j", "MASQUERADE"}},
	}
	if !routerActionsEqual(plan, want) {
		t.Fatalf("修复计划=%#v，期望 %#v", plan, want)
	}
	for _, action := range plan {
		if strings.Contains(strings.Join(action.Arguments, " ")+action.Key, "android_usb") || action.Kind == "usb-rebind" {
			t.Fatalf("路由修复不得触发 USB gadget 重枚举: %#v", action)
		}
	}

	healthy := snapshot
	healthy.IPForward = true
	healthy.NATRules = []routerNATRule{{Source: "192.168.225.0/24", Output: "rmnet_data0", Target: "MASQUERADE"}}
	if second := buildRouterRepairPlan(config, healthy); len(second) != 0 {
		t.Fatalf("健康状态重复修复不应产生动作: %#v", second)
	}
}

func TestRouterBillingPeriodChangesOnConfiguredResetDay(t *testing.T) {
	before := routerBillingPeriod(time.Date(2026, 8, 14, 23, 59, 0, 0, time.Local), 15)
	after := routerBillingPeriod(time.Date(2026, 8, 15, 0, 0, 0, 0, time.Local), 15)
	if before != "2026-07-15" || after != "2026-08-15" {
		t.Fatalf("计费周期边界错误: before=%q after=%q", before, after)
	}
}

func TestRouterManagerResetsUsageAtBillingBoundary(t *testing.T) {
	manager := newRouterManager(t.TempDir())
	manager.config.QuotaResetDay = 15
	manager.usage = routerUsage{Period: "2026-07-15", UsedBytes: 9_000, LastRXBytes: 100, LastTXBytes: 200}

	manager.recordUsage(150, 260, time.Date(2026, 8, 15, 0, 1, 0, 0, time.Local))

	if manager.usage.Period != "2026-08-15" || manager.usage.UsedBytes != 0 {
		t.Fatalf("新周期未清零: %#v", manager.usage)
	}
	if manager.usage.LastRXBytes != 150 || manager.usage.LastTXBytes != 260 {
		t.Fatalf("新周期基线错误: %#v", manager.usage)
	}
}

func TestRouterConfigEndpointPersistsValidatedConfiguration(t *testing.T) {
	directory := t.TempDir()
	a := &agent{router: newRouterManager(directory)}
	request := httptest.NewRequest(http.MethodPost, "/api/router/config", strings.NewReader(`{
		"internet_access":true,
		"nat_enabled":true,
		"monthly_quota_bytes":1073741824,
		"block_when_quota_exceeded":true,
		"quota_reset_day":15,
		"download_limit_kbps":0,
		"upload_limit_kbps":0
	}`))
	response := httptest.NewRecorder()

	a.routerConfig(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("保存路由配置状态=%d，响应=%s", response.Code, response.Body.String())
	}
	var persisted routerConfig
	if err := readRouterJSON(filepath.Join(directory, "router.json"), &persisted); err != nil {
		t.Fatal(err)
	}
	if persisted.MonthlyQuotaBytes != 1_073_741_824 || persisted.QuotaResetDay != 15 {
		t.Fatalf("持久配置错误: %#v", persisted)
	}
}

func TestRouterStatusExposesWRTLiteCapabilities(t *testing.T) {
	a := &agent{router: newRouterManager(t.TempDir())}
	request := httptest.NewRequest(http.MethodGet, "/api/router/status", nil)
	response := httptest.NewRecorder()

	a.routerStatus(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("路由状态=%d，响应=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Mode         string             `json:"mode"`
		Capabilities routerCapabilities `json:"capabilities"`
		Config       routerConfig       `json:"config"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Mode != "wrt-lite" || !payload.Capabilities.NAT || !payload.Capabilities.QuotaEnforcement || payload.Capabilities.RateShaping {
		t.Fatalf("WRT Lite 能力状态错误: %#v", payload)
	}
}

func TestParseRouterNATRulesRecognizesVendorRandomMasquerade(t *testing.T) {
	rules := parseRouterNATRules("-A POSTROUTING -o rmnet_data0 -j MASQUERADE --random\n")
	if len(rules) != 1 || rules[0].Output != "rmnet_data0" || rules[0].Target != "MASQUERADE" {
		t.Fatalf("厂商 NAT 规则未识别: %#v", rules)
	}
}

func TestRouterScheduleBlocksForwardingInsideConfiguredWindow(t *testing.T) {
	config := defaultRouterConfig()
	config.Schedules = []routerSchedule{{
		Name: "夜间断网", Enabled: true, Weekdays: []int{0, 1, 2, 3, 4, 5, 6},
		Start: "23:00", End: "06:30",
	}}

	inside := time.Date(2026, 8, 24, 1, 15, 0, 0, time.FixedZone("CST", 8*60*60)) // Monday
	decision := evaluateRouterForwardingAt(config, routerUsage{}, inside)
	if decision.Enabled || decision.Reason != "scheduled-offline" {
		t.Fatalf("夜间跨日计划未阻断转发: %#v", decision)
	}

	outside := time.Date(2026, 8, 24, 12, 0, 0, 0, inside.Location())
	if decision := evaluateRouterForwardingAt(config, routerUsage{}, outside); !decision.Enabled {
		t.Fatalf("计划外不应断网: %#v", decision)
	}
}

func TestRouterHistoryAccumulatesDailyDeltasAndCapsRetention(t *testing.T) {
	history := routerTrafficHistory{}
	now := time.Date(2026, 8, 22, 10, 0, 0, 0, time.UTC)
	history.record(now, 400, 250)
	history.record(now.Add(time.Minute), 650, 410)
	if len(history.Days) != 1 || history.Days[0].RXBytes != 250 || history.Days[0].TXBytes != 160 {
		t.Fatalf("每日流量历史累计错误: %#v", history.Days)
	}
	for day := 1; day <= 40; day++ {
		history.record(now.AddDate(0, 0, day), uint64(650+day), uint64(410+day))
	}
	if len(history.Days) != routerHistoryRetentionDays {
		t.Fatalf("历史保留天数=%d，期望=%d", len(history.Days), routerHistoryRetentionDays)
	}
}

func TestRouterConfigValidatesPortForwardsAndDNSOverrides(t *testing.T) {
	config := defaultRouterConfig()
	config.PortForwards = []routerPortForward{{
		Name: "Web", Enabled: true, Protocol: "tcp", ExternalPort: 8443,
		InternalIP: "192.168.225.20", InternalPort: 443,
	}}
	config.DNSOverrides = []routerDNSOverride{{Hostname: "ads.example.com", Address: "0.0.0.0"}}
	capabilities := routerCapabilities{PortForwarding: true, DNSOverrides: true}
	if err := validateRouterConfig(config, capabilities); err != nil {
		t.Fatalf("有效 WRT Lite 配置被拒绝: %v", err)
	}

	config.PortForwards[0].InternalIP = "8.8.8.8"
	if err := validateRouterConfig(config, capabilities); err == nil {
		t.Fatal("端口转发目标必须位于模块 LAN")
	}
	config.PortForwards[0].InternalIP = "192.168.225.20"
	config.DNSOverrides[0].Hostname = "bad host; reboot"
	if err := validateRouterConfig(config, capabilities); err == nil {
		t.Fatal("DNS 主机名必须拒绝命令注入字符")
	}
}

func TestBuildPortForwardPlanUsesOwnedNATChainOnly(t *testing.T) {
	config := defaultRouterConfig()
	config.PortForwards = []routerPortForward{{
		Name: "Camera", Enabled: true, Protocol: "tcp", ExternalPort: 9443,
		InternalIP: "192.168.225.20", InternalPort: 443,
	}}
	plan := buildPortForwardPlan(config)
	joined := make([]string, 0, len(plan))
	for _, action := range plan {
		joined = append(joined, strings.Join(action.Arguments, " "))
	}
	all := strings.Join(joined, "\n")
	if !strings.Contains(all, "-A AIRSIM_DNAT -p tcp --dport 9443 -j DNAT --to-destination 192.168.225.20:443") {
		t.Fatalf("缺少受控 DNAT 规则:\n%s", all)
	}
	if strings.Contains(all, "-F PREROUTING") || strings.Contains(all, "-F POSTROUTING") {
		t.Fatalf("不得清空厂商 NAT 链:\n%s", all)
	}
}

func TestRenderManagedHostsPreservesVendorEntries(t *testing.T) {
	input := "127.0.0.1 localhost\n192.168.225.1 module.local\n"
	overrides := []routerDNSOverride{
		{Hostname: "ads.example.com", Address: "0.0.0.0"},
		{Hostname: "nas.home", Address: "192.168.225.20"},
	}
	result := renderManagedHosts(input, overrides)
	for _, expected := range []string{"127.0.0.1 localhost", "192.168.225.1 module.local", "0.0.0.0 ads.example.com", "192.168.225.20 nas.home"} {
		if !strings.Contains(result, expected) {
			t.Fatalf("受管 hosts 缺少 %q:\n%s", expected, result)
		}
	}
	second := renderManagedHosts(result, overrides)
	if second != result {
		t.Fatalf("hosts 管理块必须幂等:\nfirst=%s\nsecond=%s", result, second)
	}
}
