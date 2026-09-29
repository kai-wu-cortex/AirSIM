package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestECMLinkPowerCycleDoesNotDisconnectUSBDevice(t *testing.T) {
	var commands []string
	run := func(name string, arguments ...string) error {
		commands = append(commands, name+" "+strings.Join(arguments, " "))
		return nil
	}
	if err := powerCycleECMLink(run, func(time.Duration) {}); err != nil {
		t.Fatalf("ECM 网卡下电重启失败: %v", err)
	}
	want := []string{"ifconfig ecm0 down", "ifconfig ecm0 up"}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("系统命令=%#v，期望 %#v；不得切换整个 USB gadget", commands, want)
	}
}

func TestMissingECMRecoveryRebindsOnlyExistingGadgetFunctions(t *testing.T) {
	type write struct {
		path  string
		value string
	}
	var writes []write
	err := rebindMissingECMGadget("1", "diag,ecm,ffs", func(path, value string) error {
		writes = append(writes, write{path: path, value: value})
		return nil
	}, func(time.Duration) {})
	if err != nil {
		t.Fatalf("ECM gadget 重绑失败: %v", err)
	}
	want := []write{
		{path: usbGadgetPath + "/enable", value: "0\n"},
		{path: usbGadgetPath + "/functions", value: "diag,ecm,ffs\n"},
		{path: usbGadgetPath + "/enable", value: "1\n"},
	}
	if !reflect.DeepEqual(writes, want) {
		t.Fatalf("gadget 写入=%#v，期望 %#v", writes, want)
	}
}

func TestMissingECMRecoveryRefusesFunctionSetWithoutECM(t *testing.T) {
	writes := 0
	err := rebindMissingECMGadget("1", "diag,ffs", func(string, string) error {
		writes++
		return nil
	}, func(time.Duration) {})
	if err == nil {
		t.Fatal("functions 不含 ECM 时必须拒绝自动重绑")
	}
	if writes != 0 {
		t.Fatalf("拒绝恢复前不应修改 gadget，写入次数=%d", writes)
	}
}

func TestMissingECMGadgetRecoveryAllowsExistingCompositeAfterCallIsIdle(t *testing.T) {
	if err := validateMissingECMGadgetRecovery(
		false,
		false,
		"diag,serial,ecm,ffs,audio",
	); err != nil {
		t.Fatalf("ECM 已消失且通话已结束时，应允许原组合重载: %v", err)
	}

	if err := validateMissingECMGadgetRecovery(
		true,
		false,
		"diag,serial,ecm,ffs,audio",
	); err == nil {
		t.Fatal("通话仍进行时不得重载整个 USB 组合")
	}

	if err := validateMissingECMGadgetRecovery(false, false, "diag,serial,ffs,audio"); err == nil {
		t.Fatal("原组合不含 ECM 时不得执行 ECM 恢复")
	}
}

func TestUSBReconnectRequiresContinuousCarrierOutage(t *testing.T) {
	recovered := make(chan struct{}, 1)
	debouncer := &usbReconnectDebouncer{
		agent:    &agent{},
		logger:   log.New(io.Discard, "", 0),
		debounce: 80 * time.Millisecond,
		reconnect: func() usbRebindOutcome {
			recovered <- struct{}{}
			return usbRebindOutcome{}
		},
	}

	debouncer.carrierChanged(true)
	time.Sleep(30 * time.Millisecond)
	debouncer.carrierChanged(false)
	select {
	case <-recovered:
		t.Fatal("短于门槛且已经恢复的 ECM 断线不应触发 USB 下电重启")
	case <-time.After(90 * time.Millisecond):
	}

	debouncer.carrierChanged(true)
	select {
	case <-recovered:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("连续超过门槛的 ECM 断线没有触发 USB 下电重启")
	}
}

func TestUSBReconnectUsesMissingInterfaceRecovery(t *testing.T) {
	recovered := make(chan ecmLinkState, 1)
	debouncer := &usbReconnectDebouncer{
		agent:    &agent{},
		logger:   log.New(io.Discard, "", 0),
		debounce: 20 * time.Millisecond,
		recover: func(state ecmLinkState) usbRebindOutcome {
			recovered <- state
			return usbRebindOutcome{}
		},
	}

	debouncer.linkStateChanged(ecmLinkMissing)
	select {
	case state := <-recovered:
		if state != ecmLinkMissing {
			t.Fatalf("恢复状态=%v，期望 missing", state)
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("ecm0 整个消失时没有触发恢复")
	}
}

func TestPollECMCarrierReportsChangesWithoutNetlink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var mu sync.Mutex
	reads := 0
	readCarrier := func() (bool, error) {
		mu.Lock()
		defer mu.Unlock()
		reads++
		return reads < 3, nil
	}
	states := make(chan bool, 4)
	go pollECMCarrier(ctx, 10*time.Millisecond, readCarrier, func(down bool) {
		states <- down
	})

	var got []bool
	deadline := time.After(200 * time.Millisecond)
	for len(got) < 2 {
		select {
		case state := <-states:
			got = append(got, state)
		case <-deadline:
			t.Fatalf("轮询未报告 ECM 状态变化，已收到 %#v", got)
		}
	}
	if !got[0] || got[1] {
		t.Fatalf("ECM 状态变化=%#v，期望 [断开, 恢复]", got)
	}
}

func TestPollECMLinkStateReportsMissingInterface(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var mu sync.Mutex
	reads := 0
	probe := func() ecmLinkState {
		mu.Lock()
		defer mu.Unlock()
		reads++
		if reads < 3 {
			return detectECMLinkState([]byte("1\n"), nil)
		}
		return detectECMLinkState(nil, os.ErrNotExist)
	}
	states := make(chan ecmLinkState, 4)
	go pollECMLinkState(ctx, 10*time.Millisecond, probe, func(state ecmLinkState) {
		states <- state
	})

	want := []ecmLinkState{ecmLinkUp, ecmLinkMissing}
	got := make([]ecmLinkState, 0, len(want))
	deadline := time.After(200 * time.Millisecond)
	for len(got) < len(want) {
		select {
		case state := <-states:
			got = append(got, state)
		case <-deadline:
			t.Fatalf("ECM 接口消失未被报告，已收到 %#v", got)
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ECM 状态变化=%#v，期望 %#v", got, want)
	}
}

func TestDetectECMLinkStateKeepsTransientReadErrorsUnknown(t *testing.T) {
	if got := detectECMLinkState(nil, errors.New("temporary I/O error")); got != ecmLinkUnknown {
		t.Fatalf("暂时读取错误状态=%v，期望 unknown", got)
	}
}
