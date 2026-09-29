package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	routerLANInterface         = "bridge0"
	routerLANSubnet            = "192.168.225.0/24"
	routerManagedNATChain      = "AIRSIM_DNAT"
	routerHistoryRetentionDays = 31
	routerHostsBegin           = "# AIRSIM WRT LITE BEGIN"
	routerHostsEnd             = "# AIRSIM WRT LITE END"
)

var errRouterRateShapingUnavailable = errors.New("当前 QDC507 内核未包含 TBF/HTB，无法启用速率整形")

type routerCapabilities struct {
	NAT               bool `json:"nat"`
	DHCP              bool `json:"dhcp"`
	DNS               bool `json:"dns"`
	TrafficAccounting bool `json:"traffic_accounting"`
	QuotaEnforcement  bool `json:"quota_enforcement"`
	RateShaping       bool `json:"rate_shaping"`
	PortForwarding    bool `json:"port_forwarding"`
	DNSOverrides      bool `json:"dns_overrides"`
	Schedules         bool `json:"schedules"`
	TrafficHistory    bool `json:"traffic_history"`
	StaticDHCP        bool `json:"static_dhcp"`
	VPN               bool `json:"vpn"`
	PerClientFirewall bool `json:"per_client_firewall"`
}

type routerSchedule struct {
	Name     string `json:"name"`
	Enabled  bool   `json:"enabled"`
	Weekdays []int  `json:"weekdays"`
	Start    string `json:"start"`
	End      string `json:"end"`
}

type routerPortForward struct {
	Name         string `json:"name"`
	Enabled      bool   `json:"enabled"`
	Protocol     string `json:"protocol"`
	ExternalPort int    `json:"external_port"`
	InternalIP   string `json:"internal_ip"`
	InternalPort int    `json:"internal_port"`
}

type routerDNSOverride struct {
	Hostname string `json:"hostname"`
	Address  string `json:"address"`
}

type routerConfig struct {
	InternetAccess         bool                `json:"internet_access"`
	NATEnabled             bool                `json:"nat_enabled"`
	MonthlyQuotaBytes      uint64              `json:"monthly_quota_bytes"`
	BlockWhenQuotaExceeded bool                `json:"block_when_quota_exceeded"`
	QuotaResetDay          int                 `json:"quota_reset_day"`
	DownloadLimitKbps      int                 `json:"download_limit_kbps"`
	UploadLimitKbps        int                 `json:"upload_limit_kbps"`
	Schedules              []routerSchedule    `json:"schedules,omitempty"`
	PortForwards           []routerPortForward `json:"port_forwards,omitempty"`
	DNSOverrides           []routerDNSOverride `json:"dns_overrides,omitempty"`
}

func defaultRouterConfig() routerConfig {
	return routerConfig{
		InternetAccess:         true,
		NATEnabled:             true,
		BlockWhenQuotaExceeded: true,
		QuotaResetDay:          1,
	}
}

func validateRouterConfig(config routerConfig, capabilities routerCapabilities) error {
	if config.QuotaResetDay < 1 || config.QuotaResetDay > 28 {
		return errors.New("quota_reset_day 必须在 1 到 28 之间")
	}
	if config.DownloadLimitKbps < 0 || config.UploadLimitKbps < 0 {
		return errors.New("速率限制不能为负数")
	}
	if !capabilities.RateShaping && (config.DownloadLimitKbps > 0 || config.UploadLimitKbps > 0) {
		return errRouterRateShapingUnavailable
	}
	for _, schedule := range config.Schedules {
		if !capabilities.Schedules {
			return errors.New("当前 Agent 不支持定时断网")
		}
		if _, ok := parseRouterClock(schedule.Start); !ok {
			return fmt.Errorf("定时计划 %q 的 start 无效", schedule.Name)
		}
		if _, ok := parseRouterClock(schedule.End); !ok {
			return fmt.Errorf("定时计划 %q 的 end 无效", schedule.Name)
		}
		for _, weekday := range schedule.Weekdays {
			if weekday < 0 || weekday > 6 {
				return fmt.Errorf("定时计划 %q 的 weekday 无效", schedule.Name)
			}
		}
	}
	lanNetwork := &net.IPNet{IP: net.IPv4(192, 168, 225, 0), Mask: net.CIDRMask(24, 32)}
	seenPorts := make(map[string]bool)
	for _, forward := range config.PortForwards {
		if !capabilities.PortForwarding {
			return errors.New("当前 Agent 不支持端口转发")
		}
		protocol := strings.ToLower(forward.Protocol)
		if protocol != "tcp" && protocol != "udp" {
			return fmt.Errorf("端口转发 %q 的 protocol 必须是 tcp 或 udp", forward.Name)
		}
		if forward.ExternalPort < 1 || forward.ExternalPort > 65535 || forward.InternalPort < 1 || forward.InternalPort > 65535 {
			return fmt.Errorf("端口转发 %q 的端口无效", forward.Name)
		}
		ip := net.ParseIP(forward.InternalIP)
		if ip == nil || ip.To4() == nil || !lanNetwork.Contains(ip) || forward.InternalIP == "192.168.225.1" {
			return fmt.Errorf("端口转发 %q 的目标必须位于模块 LAN", forward.Name)
		}
		key := fmt.Sprintf("%s:%d", protocol, forward.ExternalPort)
		if seenPorts[key] {
			return fmt.Errorf("端口转发外部端口重复: %s", key)
		}
		seenPorts[key] = true
	}
	for _, override := range config.DNSOverrides {
		if !capabilities.DNSOverrides {
			return errors.New("当前 Agent 不支持 DNS 覆盖")
		}
		if !validRouterHostname(override.Hostname) {
			return fmt.Errorf("DNS 主机名无效: %q", override.Hostname)
		}
		ip := net.ParseIP(override.Address)
		if ip == nil || ip.To4() == nil {
			return fmt.Errorf("DNS 地址无效: %q", override.Address)
		}
	}
	return nil
}

func parseRouterClock(value string) (int, bool) {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return 0, false
	}
	hour, hourErr := strconv.Atoi(parts[0])
	minute, minuteErr := strconv.Atoi(parts[1])
	if hourErr != nil || minuteErr != nil || hour < 0 || hour > 23 || minute < 0 || minute > 59 {
		return 0, false
	}
	return hour*60 + minute, true
}

func validRouterHostname(value string) bool {
	if len(value) < 1 || len(value) > 253 {
		return false
	}
	for _, label := range strings.Split(strings.ToLower(value), ".") {
		if len(label) < 1 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if (character < 'a' || character > 'z') && (character < '0' || character > '9') && character != '-' {
				return false
			}
		}
	}
	return true
}

type routerUsage struct {
	Period      string `json:"period"`
	UsedBytes   uint64 `json:"used_bytes"`
	LastRXBytes uint64 `json:"last_rx_bytes"`
	LastTXBytes uint64 `json:"last_tx_bytes"`
	UpdatedAt   string `json:"updated_at,omitempty"`
}

func (usage *routerUsage) advance(rx, tx uint64) {
	initialized := usage.Period != "" || usage.LastRXBytes > 0 || usage.LastTXBytes > 0
	if initialized {
		if rx >= usage.LastRXBytes {
			usage.UsedBytes += rx - usage.LastRXBytes
		} else {
			usage.UsedBytes += rx
		}
	}
	if initialized {
		if tx >= usage.LastTXBytes {
			usage.UsedBytes += tx - usage.LastTXBytes
		} else {
			usage.UsedBytes += tx
		}
	}
	usage.LastRXBytes = rx
	usage.LastTXBytes = tx
}

func routerBillingPeriod(now time.Time, resetDay int) string {
	if resetDay < 1 || resetDay > 28 {
		resetDay = 1
	}
	year, month, day := now.Date()
	if day < resetDay {
		month--
		if month < time.January {
			month = time.December
			year--
		}
	}
	return fmt.Sprintf("%04d-%02d-%02d", year, int(month), resetDay)
}

type routerForwardingDecision struct {
	Enabled         bool   `json:"enabled"`
	Reason          string `json:"reason"`
	BlockLocalAgent bool   `json:"block_local_agent"`
}

func evaluateRouterForwarding(config routerConfig, usage routerUsage) routerForwardingDecision {
	return evaluateRouterForwardingAt(config, usage, time.Now())
}

func evaluateRouterForwardingAt(config routerConfig, usage routerUsage, now time.Time) routerForwardingDecision {
	if !config.InternetAccess {
		return routerForwardingDecision{Reason: "disabled-by-user"}
	}
	if config.BlockWhenQuotaExceeded && config.MonthlyQuotaBytes > 0 && usage.UsedBytes >= config.MonthlyQuotaBytes {
		return routerForwardingDecision{Reason: "quota-exceeded"}
	}
	for _, schedule := range config.Schedules {
		if routerScheduleContains(schedule, now) {
			return routerForwardingDecision{Reason: "scheduled-offline"}
		}
	}
	return routerForwardingDecision{Enabled: true, Reason: "enabled"}
}

func routerScheduleContains(schedule routerSchedule, now time.Time) bool {
	if !schedule.Enabled {
		return false
	}
	start, startOK := parseRouterClock(schedule.Start)
	end, endOK := parseRouterClock(schedule.End)
	if !startOK || !endOK || start == end {
		return false
	}
	minute := now.Hour()*60 + now.Minute()
	weekday := int(now.Weekday())
	containsDay := func(day int) bool {
		for _, configured := range schedule.Weekdays {
			if configured == day {
				return true
			}
		}
		return false
	}
	if start < end {
		return containsDay(weekday) && minute >= start && minute < end
	}
	if minute >= start {
		return containsDay(weekday)
	}
	previous := (weekday + 6) % 7
	return minute < end && containsDay(previous)
}

type routerTrafficDay struct {
	Date    string `json:"date"`
	RXBytes uint64 `json:"rx_bytes"`
	TXBytes uint64 `json:"tx_bytes"`
}

type routerTrafficHistory struct {
	Days        []routerTrafficDay `json:"days"`
	LastRXBytes uint64             `json:"last_rx_bytes"`
	LastTXBytes uint64             `json:"last_tx_bytes"`
	Initialized bool               `json:"initialized"`
}

func (history *routerTrafficHistory) record(now time.Time, rx, tx uint64) {
	if !history.Initialized {
		history.LastRXBytes, history.LastTXBytes, history.Initialized = rx, tx, true
		return
	}
	rxDelta, txDelta := rx, tx
	if rx >= history.LastRXBytes {
		rxDelta = rx - history.LastRXBytes
	}
	if tx >= history.LastTXBytes {
		txDelta = tx - history.LastTXBytes
	}
	history.LastRXBytes, history.LastTXBytes = rx, tx
	date := now.Format("2006-01-02")
	if len(history.Days) == 0 || history.Days[len(history.Days)-1].Date != date {
		history.Days = append(history.Days, routerTrafficDay{Date: date})
	}
	last := &history.Days[len(history.Days)-1]
	last.RXBytes += rxDelta
	last.TXBytes += txDelta
	if len(history.Days) > routerHistoryRetentionDays {
		history.Days = append([]routerTrafficDay(nil), history.Days[len(history.Days)-routerHistoryRetentionDays:]...)
	}
}

type routerClient struct {
	IP                    string `json:"ip"`
	MAC                   string `json:"mac,omitempty"`
	Hostname              string `json:"hostname,omitempty"`
	Online                bool   `json:"online"`
	LeaseRemainingSeconds int64  `json:"lease_remaining_seconds,omitempty"`
}

func parseRouterClients(leases, arp io.Reader, now time.Time) []routerClient {
	clients := make(map[string]routerClient)
	leaseScanner := bufio.NewScanner(leases)
	for leaseScanner.Scan() {
		fields := strings.Fields(leaseScanner.Text())
		if len(fields) < 4 || net.ParseIP(fields[2]) == nil {
			continue
		}
		expires, _ := strconv.ParseInt(fields[0], 10, 64)
		remaining := expires - now.Unix()
		if remaining < 0 {
			remaining = 0
		}
		hostname := fields[3]
		if hostname == "*" {
			hostname = ""
		}
		clients[fields[2]] = routerClient{
			IP: fields[2], MAC: strings.ToLower(fields[1]), Hostname: hostname,
			LeaseRemainingSeconds: remaining,
		}
	}

	arpScanner := bufio.NewScanner(arp)
	for arpScanner.Scan() {
		fields := strings.Fields(arpScanner.Text())
		if len(fields) < 6 || net.ParseIP(fields[0]) == nil {
			continue
		}
		flags, err := strconv.ParseUint(strings.TrimPrefix(fields[2], "0x"), 16, 32)
		if err != nil || flags&0x2 == 0 || (fields[5] != routerLANInterface && fields[5] != "ecm0") {
			continue
		}
		client := clients[fields[0]]
		client.IP = fields[0]
		client.Online = true
		if client.MAC == "" {
			client.MAC = strings.ToLower(fields[3])
		}
		clients[fields[0]] = client
	}

	result := make([]routerClient, 0, len(clients))
	for _, client := range clients {
		result = append(result, client)
	}
	sort.Slice(result, func(i, j int) bool {
		left := net.ParseIP(result[i].IP).To4()
		right := net.ParseIP(result[j].IP).To4()
		if left == nil || right == nil {
			return result[i].IP < result[j].IP
		}
		for index := range left {
			if left[index] != right[index] {
				return left[index] < right[index]
			}
		}
		return false
	})
	return result
}

type routerNATRule struct {
	Source string `json:"source,omitempty"`
	Output string `json:"output"`
	Target string `json:"target"`
}

type routerSystemSnapshot struct {
	IPForward bool            `json:"ip_forward"`
	NATRules  []routerNATRule `json:"nat_rules"`
	WAN       string          `json:"wan_interface"`
	LAN       string          `json:"lan_interface"`
}

type routerAction struct {
	Kind      string   `json:"kind"`
	Key       string   `json:"key,omitempty"`
	Value     string   `json:"value,omitempty"`
	Arguments []string `json:"arguments,omitempty"`
}

func buildRouterRepairPlan(config routerConfig, snapshot routerSystemSnapshot) []routerAction {
	decision := evaluateRouterForwarding(config, routerUsage{})
	result := make([]routerAction, 0, 2)
	if decision.Enabled != snapshot.IPForward {
		value := "0"
		if decision.Enabled {
			value = "1"
		}
		result = append(result, routerAction{Kind: "sysctl", Key: "net.ipv4.ip_forward", Value: value})
	}
	if config.NATEnabled && snapshot.WAN != "" && !hasEffectiveRouterNAT(snapshot.NATRules, snapshot.WAN) {
		result = append(result, routerAction{Kind: "iptables", Arguments: []string{
			"-t", "nat", "-A", "POSTROUTING", "-s", routerLANSubnet,
			"-o", snapshot.WAN, "-j", "MASQUERADE",
		}})
	}
	return result
}

func buildPortForwardPlan(config routerConfig) []routerAction {
	result := []routerAction{
		{Kind: "iptables-ignore-exists", Arguments: []string{"-t", "nat", "-N", routerManagedNATChain}},
		{Kind: "iptables-check-or-add", Arguments: []string{"-t", "nat", "-A", "PREROUTING", "-j", routerManagedNATChain}},
		{Kind: "iptables", Arguments: []string{"-t", "nat", "-F", routerManagedNATChain}},
	}
	for _, forward := range config.PortForwards {
		if !forward.Enabled {
			continue
		}
		result = append(result, routerAction{Kind: "iptables", Arguments: []string{
			"-t", "nat", "-A", routerManagedNATChain, "-p", strings.ToLower(forward.Protocol),
			"--dport", strconv.Itoa(forward.ExternalPort), "-j", "DNAT", "--to-destination",
			fmt.Sprintf("%s:%d", forward.InternalIP, forward.InternalPort),
		}})
	}
	return result
}

func renderManagedHosts(existing string, overrides []routerDNSOverride) string {
	lines := strings.Split(strings.ReplaceAll(existing, "\r\n", "\n"), "\n")
	kept := make([]string, 0, len(lines)+len(overrides)+2)
	inManagedBlock := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == routerHostsBegin {
			inManagedBlock = true
			continue
		}
		if trimmed == routerHostsEnd {
			inManagedBlock = false
			continue
		}
		if !inManagedBlock && trimmed != "" {
			kept = append(kept, line)
		}
	}
	kept = append(kept, routerHostsBegin)
	sorted := append([]routerDNSOverride(nil), overrides...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Hostname < sorted[j].Hostname })
	for _, override := range sorted {
		kept = append(kept, fmt.Sprintf("%s %s", override.Address, strings.ToLower(override.Hostname)))
	}
	kept = append(kept, routerHostsEnd)
	return strings.Join(kept, "\n") + "\n"
}

func hasEffectiveRouterNAT(rules []routerNATRule, wan string) bool {
	for _, rule := range rules {
		if rule.Output == wan && rule.Target == "MASQUERADE" && (rule.Source == "" || rule.Source == routerLANSubnet) {
			return true
		}
	}
	return false
}

func routerActionsEqual(left, right []routerAction) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index].Kind != right[index].Kind || left[index].Key != right[index].Key || left[index].Value != right[index].Value || strings.Join(left[index].Arguments, "\x00") != strings.Join(right[index].Arguments, "\x00") {
			return false
		}
	}
	return true
}

type routerManager struct {
	mu                  sync.Mutex
	configPath          string
	usagePath           string
	historyPath         string
	hostsPath           string
	config              routerConfig
	usage               routerUsage
	history             routerTrafficHistory
	capabilities        routerCapabilities
	lastError           string
	lastApplied         time.Time
	lastPolicySignature string
}

func newRouterManager(dataDirectory string) *routerManager {
	manager := &routerManager{
		configPath:  filepath.Join(dataDirectory, "router.json"),
		usagePath:   filepath.Join(dataDirectory, "router-usage.json"),
		historyPath: filepath.Join(dataDirectory, "router-history.json"),
		hostsPath:   filepath.Join(dataDirectory, "router-hosts"),
		config:      defaultRouterConfig(),
		capabilities: routerCapabilities{
			NAT: true, DHCP: true, DNS: true, TrafficAccounting: true, QuotaEnforcement: true,
			PortForwarding: true, DNSOverrides: true, Schedules: true, TrafficHistory: true,
			StaticDHCP: false, VPN: false, PerClientFirewall: false,
		},
	}
	_ = readRouterJSON(manager.configPath, &manager.config)
	_ = readRouterJSON(manager.usagePath, &manager.usage)
	_ = readRouterJSON(manager.historyPath, &manager.history)
	if err := validateRouterConfig(manager.config, manager.capabilities); err != nil {
		manager.config = defaultRouterConfig()
		manager.lastError = "配置已恢复默认值: " + err.Error()
	}
	return manager
}

func readRouterJSON(path string, target any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, target)
}

func writeRouterJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".router-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func parseRouterNATRules(input string) []routerNATRule {
	var result []routerNATRule
	for _, line := range strings.Split(input, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		rule := routerNATRule{}
		for index := 0; index+1 < len(fields); index++ {
			switch fields[index] {
			case "-s":
				rule.Source = fields[index+1]
			case "-o":
				rule.Output = fields[index+1]
			case "-j":
				rule.Target = fields[index+1]
			}
		}
		if rule.Output != "" && rule.Target == "MASQUERADE" {
			result = append(result, rule)
		}
	}
	return result
}

func currentRouterSnapshot() (routerSystemSnapshot, error) {
	snapshot := routerSystemSnapshot{LAN: routerLANInterface}
	forward, err := os.ReadFile("/proc/sys/net/ipv4/ip_forward")
	if err != nil {
		return snapshot, err
	}
	snapshot.IPForward = strings.TrimSpace(string(forward)) == "1"
	routes, err := os.Open("/proc/net/route")
	if err != nil {
		return snapshot, err
	}
	snapshot.WAN = selectPushWANInterface(routes)
	routes.Close()
	if output, err := runRouterCommand("iptables-save", "-t", "nat"); err == nil {
		snapshot.NATRules = parseRouterNATRules(output)
	}
	return snapshot, nil
}

func runRouterCommand(name string, arguments ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, name, arguments...).CombinedOutput()
	if ctx.Err() != nil {
		return string(output), ctx.Err()
	}
	if err != nil {
		return string(output), fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

func applyRouterActions(actions []routerAction) error {
	for _, action := range actions {
		switch action.Kind {
		case "sysctl":
			if action.Key != "net.ipv4.ip_forward" || (action.Value != "0" && action.Value != "1") {
				return fmt.Errorf("拒绝未知 sysctl 动作: %#v", action)
			}
			if err := os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte(action.Value+"\n"), 0o644); err != nil {
				return err
			}
		case "iptables":
			if _, err := runRouterCommand("iptables", action.Arguments...); err != nil {
				return err
			}
		case "iptables-ignore-exists":
			_, _ = runRouterCommand("iptables", action.Arguments...)
		case "iptables-check-or-add":
			checkArguments := append([]string(nil), action.Arguments...)
			for index, value := range checkArguments {
				if value == "-A" {
					checkArguments[index] = "-C"
					break
				}
			}
			if _, err := runRouterCommand("iptables", checkArguments...); err != nil {
				existing, _ := runRouterCommand("iptables-save", "-t", "nat")
				needle := "-A PREROUTING -j " + routerManagedNATChain
				if !strings.Contains(existing, needle) {
					if _, addErr := runRouterCommand("iptables", action.Arguments...); addErr != nil {
						return addErr
					}
				}
			}
		default:
			return fmt.Errorf("拒绝未知路由动作: %s", action.Kind)
		}
	}
	return nil
}

func (manager *routerManager) recordUsage(rx, tx uint64, now time.Time) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	manager.history.record(now, rx, tx)
	period := routerBillingPeriod(now, manager.config.QuotaResetDay)
	if manager.usage.Period != period {
		manager.usage = routerUsage{Period: period, LastRXBytes: rx, LastTXBytes: tx, UpdatedAt: now.UTC().Format(time.RFC3339)}
		return
	}
	manager.usage.advance(rx, tx)
	manager.usage.UpdatedAt = now.UTC().Format(time.RFC3339)
}

func (manager *routerManager) sampleUsage(now time.Time) error {
	rx, tx, err := readInterfaceCounters(routerLANInterface)
	if err != nil {
		return err
	}
	manager.recordUsage(rx, tx, now)
	return nil
}

func (manager *routerManager) currentState() (routerConfig, routerUsage, routerCapabilities, string, time.Time) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	return manager.config, manager.usage, manager.capabilities, manager.lastError, manager.lastApplied
}

func (manager *routerManager) setConfig(config routerConfig) error {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if err := validateRouterConfig(config, manager.capabilities); err != nil {
		return err
	}
	if err := writeRouterJSON(manager.configPath, config); err != nil {
		return err
	}
	manager.config = config
	manager.lastPolicySignature = ""
	return nil
}

func routerPolicySignature(config routerConfig) string {
	data, _ := json.Marshal(struct {
		PortForwards []routerPortForward `json:"port_forwards"`
		DNSOverrides []routerDNSOverride `json:"dns_overrides"`
	}{config.PortForwards, config.DNSOverrides})
	return string(data)
}

func applyRouterDNSOverrides(managedPath string, overrides []routerDNSOverride) error {
	const hostsPath = "/etc/hosts"
	existing, err := os.ReadFile(hostsPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	content := renderManagedHosts(string(existing), overrides)
	if err := os.MkdirAll(filepath.Dir(managedPath), 0o700); err != nil {
		return err
	}
	// 使用原位写入而不是 rename；bind mount 已建立时必须保持同一个 inode。
	if err := os.WriteFile(managedPath, []byte(content), 0o644); err != nil {
		return err
	}
	mounts, _ := os.ReadFile("/proc/mounts")
	bound := false
	for _, line := range strings.Split(string(mounts), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[1] == hostsPath {
			bound = true
			break
		}
	}
	if !bound {
		if _, err := runRouterCommand("mount", "--bind", managedPath, hostsPath); err != nil {
			return err
		}
	}
	if output, err := runRouterCommand("pidof", "dnsmasq"); err == nil {
		for _, pid := range strings.Fields(output) {
			_, _ = runRouterCommand("kill", "-HUP", pid)
		}
	}
	return nil
}

func (manager *routerManager) resetQuota(now time.Time) error {
	rx, tx, err := readInterfaceCounters(routerLANInterface)
	if err != nil && runtime.GOOS == "linux" {
		return err
	}
	manager.mu.Lock()
	manager.usage = routerUsage{
		Period: routerBillingPeriod(now, manager.config.QuotaResetDay), LastRXBytes: rx, LastTXBytes: tx,
		UpdatedAt: now.UTC().Format(time.RFC3339),
	}
	usage := manager.usage
	manager.mu.Unlock()
	return writeRouterJSON(manager.usagePath, usage)
}

func (manager *routerManager) reconcile() ([]routerAction, error) {
	config, usage, _, _, _ := manager.currentState()
	snapshot, err := currentRouterSnapshot()
	if err != nil {
		return nil, err
	}
	decision := evaluateRouterForwarding(config, usage)
	effectiveConfig := config
	effectiveConfig.InternetAccess = decision.Enabled
	actions := buildRouterRepairPlan(effectiveConfig, snapshot)
	manager.mu.Lock()
	signature := routerPolicySignature(config)
	applyExtendedPolicy := signature != manager.lastPolicySignature
	manager.mu.Unlock()
	if applyExtendedPolicy {
		actions = append(actions, buildPortForwardPlan(config)...)
	}
	if err := applyRouterActions(actions); err != nil {
		manager.mu.Lock()
		manager.lastError = err.Error()
		manager.mu.Unlock()
		return actions, err
	}
	if applyExtendedPolicy {
		if err := applyRouterDNSOverrides(manager.hostsPath, config.DNSOverrides); err != nil {
			manager.mu.Lock()
			manager.lastError = err.Error()
			manager.mu.Unlock()
			return actions, err
		}
	}
	manager.mu.Lock()
	manager.lastError = ""
	manager.lastApplied = time.Now().UTC()
	manager.lastPolicySignature = signature
	manager.mu.Unlock()
	return actions, nil
}

func (manager *routerManager) monitorLoop(ctx context.Context, report func(string, string)) {
	if manager == nil {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	persistTicker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	defer persistTicker.Stop()
	run := func() {
		if err := manager.sampleUsage(time.Now()); err != nil {
			manager.mu.Lock()
			manager.lastError = "流量采样失败: " + err.Error()
			manager.mu.Unlock()
			return
		}
		actions, err := manager.reconcile()
		if err != nil {
			report("WRT Lite 路由校验失败", err.Error())
		} else if len(actions) > 0 {
			report("WRT Lite 已修复路由", fmt.Sprintf("actions=%d", len(actions)))
		}
	}
	run()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			run()
		case <-persistTicker.C:
			_, usage, _, _, _ := manager.currentState()
			if err := writeRouterJSON(manager.usagePath, usage); err != nil {
				report("WRT Lite 流量记录保存失败", err.Error())
			}
			manager.mu.Lock()
			history := manager.history
			manager.mu.Unlock()
			if err := writeRouterJSON(manager.historyPath, history); err != nil {
				report("WRT Lite 流量历史保存失败", err.Error())
			}
		}
	}
}

func (a *agent) routerStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	if a.router == nil {
		writeError(response, http.StatusServiceUnavailable, "WRT Lite 尚未初始化")
		return
	}
	config, usage, capabilities, lastError, lastApplied := a.router.currentState()
	decision := evaluateRouterForwarding(config, usage)
	payload := map[string]any{
		"mode": "wrt-lite", "config": config, "usage": usage, "capabilities": capabilities,
		"forwarding": decision, "last_error": lastError,
	}
	a.router.mu.Lock()
	payload["traffic_history"] = a.router.history
	a.router.mu.Unlock()
	if !lastApplied.IsZero() {
		payload["last_applied_at"] = lastApplied.Format(time.RFC3339)
	}
	if snapshot, err := currentRouterSnapshot(); err == nil {
		payload["system"] = snapshot
	}
	writeJSON(response, http.StatusOK, payload)
}

func (a *agent) routerConfig(response http.ResponseWriter, request *http.Request) {
	if a.router == nil {
		writeError(response, http.StatusServiceUnavailable, "WRT Lite 尚未初始化")
		return
	}
	switch request.Method {
	case http.MethodGet:
		config, _, capabilities, _, _ := a.router.currentState()
		writeJSON(response, http.StatusOK, map[string]any{"config": config, "capabilities": capabilities})
	case http.MethodPost:
		var config routerConfig
		if !decodeJSON(response, request, &config) {
			return
		}
		if err := a.router.setConfig(config); err != nil {
			writeError(response, http.StatusUnprocessableEntity, err.Error())
			return
		}
		applied := false
		warning := ""
		if runtime.GOOS == "linux" {
			_, err := a.router.reconcile()
			applied = err == nil
			if err != nil {
				warning = err.Error()
			}
		}
		writeJSON(response, http.StatusOK, map[string]any{"config": config, "applied": applied, "warning": warning})
	default:
		requireMethod(response, request, http.MethodGet, http.MethodPost)
	}
}

func (a *agent) routerInternet(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if a.router == nil {
		writeError(response, http.StatusServiceUnavailable, "WRT Lite 尚未初始化")
		return
	}
	var body struct {
		Enabled *bool `json:"enabled"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.Enabled == nil {
		writeError(response, http.StatusBadRequest, "缺少 enabled")
		return
	}
	config, _, _, _, _ := a.router.currentState()
	config.InternetAccess = *body.Enabled
	if err := a.router.setConfig(config); err != nil {
		writeError(response, http.StatusInternalServerError, err.Error())
		return
	}
	_, err := a.router.reconcile()
	if err != nil {
		writeError(response, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"internet_access": *body.Enabled})
}

func (a *agent) routerQuotaReset(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if a.router == nil {
		writeError(response, http.StatusServiceUnavailable, "WRT Lite 尚未初始化")
		return
	}
	if err := a.router.resetQuota(time.Now()); err != nil {
		writeError(response, http.StatusInternalServerError, err.Error())
		return
	}
	_, _ = a.router.reconcile()
	writeJSON(response, http.StatusOK, map[string]bool{"reset": true})
}

func (a *agent) routerRepair(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if a.router == nil {
		writeError(response, http.StatusServiceUnavailable, "WRT Lite 尚未初始化")
		return
	}
	actions, err := a.router.reconcile()
	if err != nil {
		writeError(response, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]any{"repaired": len(actions) > 0, "actions": actions})
}

func (a *agent) routerClients(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	leaseFile := openFirstRouterFile("/var/lib/misc/dnsmasq.leases", "/var/run/dnsmasq.leases", "/tmp/dnsmasq.leases")
	if leaseFile != nil {
		defer leaseFile.Close()
	} else {
		leaseFile = emptyRouterFile{}
	}
	arpFile, err := os.Open("/proc/net/arp")
	if err != nil {
		writeError(response, http.StatusServiceUnavailable, err.Error())
		return
	}
	defer arpFile.Close()
	writeJSON(response, http.StatusOK, map[string]any{"clients": parseRouterClients(leaseFile, arpFile, time.Now())})
}

type routerReadCloser interface {
	io.Reader
	io.Closer
}

type emptyRouterFile struct{}

func (emptyRouterFile) Read([]byte) (int, error) { return 0, io.EOF }
func (emptyRouterFile) Close() error             { return nil }

func openFirstRouterFile(paths ...string) routerReadCloser {
	for _, path := range paths {
		file, err := os.Open(path)
		if err == nil {
			return file
		}
	}
	return nil
}
