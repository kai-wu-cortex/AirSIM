package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestUSBRecoveryRetriesWhenRebindCooldownHasNotExpired(t *testing.T) {
	outcome := usbCooldownOutcome(1_000, 900, 5*time.Minute)
	if !outcome.Retry {
		t.Fatal("命中重绑冷却时必须保留后续恢复任务")
	}
	if outcome.RetryAfter != 200*time.Second {
		t.Fatalf("冷却剩余时间=%s，期望 200s", outcome.RetryAfter)
	}
}

func TestUSBRecoveryRetriesTemporarySafetyBlocks(t *testing.T) {
	for _, reason := range []string{"通话进行中", "媒体路由运行中", "USB 组合暂不可重绑"} {
		outcome := usbBlockedOutcome(reason)
		if !outcome.Retry || outcome.RetryAfter <= 0 {
			t.Fatalf("临时阻塞 %q 不应永久放弃恢复: %#v", reason, outcome)
		}
	}
}

func TestUSBFaultStorePersistsBoundedHistoryAcrossRestart(t *testing.T) {
	path := t.TempDir() + "/usb-faults.json"
	store := newUSBFaultStore(path, 2)
	for _, phase := range []string{"carrier-down", "rebind-start", "rebind-complete"} {
		if err := store.append(usbFaultSnapshot{Timestamp: time.Now().UTC(), Phase: phase}); err != nil {
			t.Fatal(err)
		}
	}

	reloaded := newUSBFaultStore(path, 2)
	records := reloaded.records()
	if len(records) != 2 {
		t.Fatalf("持久快照数量=%d，期望 2", len(records))
	}
	if records[0].Phase != "rebind-start" || records[1].Phase != "rebind-complete" {
		t.Fatalf("持久快照顺序或裁剪错误: %#v", records)
	}
}

func TestUSBFaultStoreCoalescesRepeatedIdenticalFaults(t *testing.T) {
	path := t.TempDir() + "/usb-faults.json"
	store := newUSBFaultStore(path, 8)
	first := usbFaultSnapshot{
		Timestamp:       time.Date(2026, 8, 21, 1, 0, 0, 0, time.UTC),
		Phase:           "rebind-deferred",
		Trigger:         "netlink-carrier-down",
		Reason:          "通话进行中",
		Carrier:         "0",
		FactoryPID:      "12",
		AgentListening:  true,
		GadgetFunctions: "diag,ecm,ffs",
	}
	if err := store.append(first); err != nil {
		t.Fatal(err)
	}
	second := first
	second.Timestamp = first.Timestamp.Add(10 * time.Second)
	if err := store.append(second); err != nil {
		t.Fatal(err)
	}
	if got := len(store.records()); got != 1 {
		t.Fatalf("相同故障在一分钟内应合并，实际记录=%d", got)
	}

	changed := second
	changed.Timestamp = first.Timestamp.Add(20 * time.Second)
	changed.Reason = "媒体路由运行中"
	if err := store.append(changed); err != nil {
		t.Fatal(err)
	}
	if got := len(store.records()); got != 2 {
		t.Fatalf("故障原因变化必须立即记录，实际记录=%d", got)
	}
}

func TestUSBFaultStoreRollsBackMemoryWhenPersistenceFails(t *testing.T) {
	directory := t.TempDir()
	blocker := directory + "/not-a-directory"
	if err := os.WriteFile(blocker, []byte("block"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := newUSBFaultStore(blocker+"/usb-faults.json", 8)
	err := store.append(usbFaultSnapshot{
		Timestamp:  time.Now().UTC(),
		Phase:      "carrier-down",
		Carrier:    "0",
		FactoryPID: "12",
	})
	if err == nil {
		t.Fatal("不可写路径必须返回持久化错误")
	}
	if got := len(store.records()); got != 0 {
		t.Fatalf("持久化失败后内存状态必须回滚，实际记录=%d", got)
	}
	if got := store.previousFactoryPID(); got != "" {
		t.Fatalf("持久化失败后原厂 PID 基线必须回滚，实际=%q", got)
	}
}

func TestClassifyUSBFaultMatchesFieldDiagnosticTree(t *testing.T) {
	tests := []struct {
		name string
		in   usbFaultSnapshot
		want string
	}{
		{"interface missing", usbFaultSnapshot{Carrier: "unavailable: no such file", GadgetFunctions: "diag,ecm,ffs", GadgetEnabled: "1", AgentListening: true, FactoryPID: "12"}, "ecm-interface-missing"},
		{"carrier down", usbFaultSnapshot{Carrier: "0", AgentListening: true, FactoryPID: "12"}, "usb-link-down"},
		{"host missing", usbFaultSnapshot{Carrier: "1", HasECMPeer: false, AgentListening: true, FactoryPID: "12"}, "ios-address-or-route-missing"},
		{"agent listener", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: false, FactoryPID: "12"}, "agent-listener-down"},
		{"factory missing", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: true}, "factory-service-missing"},
		{"factory changed", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: true, FactoryPID: "13", FactoryPIDChanged: true}, "factory-service-changed"},
		{"healthy", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: true, FactoryPID: "12"}, "ready"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := classifyUSBFault(test.in); got != test.want {
				t.Fatalf("分类=%q，期望 %q", got, test.want)
			}
		})
	}
}

func TestSelectPushWANInterfaceAvoidsECMDefaultRoute(t *testing.T) {
	routes := "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" +
		"ecm0\t00000000\t0168A8C0\t0003\t0\t0\t0\t00000000\n" +
		"rmnet_data0\t00000000\t00000000\t0003\t0\t0\t100\t00000000\n"
	if got := selectPushWANInterface(strings.NewReader(routes)); got != "rmnet_data0" {
		t.Fatalf("公网推送接口=%q，期望 rmnet_data0", got)
	}
	if got := selectPushWANInterface(strings.NewReader(strings.Split(routes, "rmnet_data0")[0])); got != "" {
		t.Fatalf("只有 ECM 时不应强绑公网推送接口: %q", got)
	}
}
