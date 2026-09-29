package main

import (
	"testing"
	"time"
)

func TestCellularRecoveryPolicyDoesNotResetUSBOrRadioForShortOutage(t *testing.T) {
	if action := chooseCellularRecoveryAction(2, 20*time.Second, cellularRecoveryIdle, time.Hour, false); action != cellularRecoveryNone {
		t.Fatalf("短暂搜索网络不应触发恢复: %v", action)
	}
	if action := chooseCellularRecoveryAction(1, time.Hour, cellularRecoveryIdle, time.Hour, false); action != cellularRecoveryNone {
		t.Fatalf("已注册网络不应触发恢复: %v", action)
	}
}

func TestCellularRecoveryPolicyUsesAutomaticSelectionBeforeRadioRestart(t *testing.T) {
	if action := chooseCellularRecoveryAction(2, 45*time.Second, cellularRecoveryIdle, time.Hour, false); action != cellularRecoveryAutomaticSelection {
		t.Fatalf("持续搜索应先自动选网: %v", action)
	}
	if action := chooseCellularRecoveryAction(0, 3*time.Minute, cellularRecoverySelectedNetwork, 2*time.Minute, false); action != cellularRecoveryRadioRestart {
		t.Fatalf("自动选网后仍未注册应软重启射频: %v", action)
	}
}

func TestCellularRecoveryPolicyNeverDisruptsAnActiveCallAndRespectsCooldown(t *testing.T) {
	if action := chooseCellularRecoveryAction(0, 10*time.Minute, cellularRecoveryIdle, time.Hour, true); action != cellularRecoveryNone {
		t.Fatalf("通话期间不得恢复射频: %v", action)
	}
	if action := chooseCellularRecoveryAction(0, 10*time.Minute, cellularRecoveryRestartedRadio, 5*time.Minute, false); action != cellularRecoveryNone {
		t.Fatalf("射频重启冷却期不得重复执行: %v", action)
	}
}

func TestRegistrationParserAcceptsQueryAndURCFormats(t *testing.T) {
	if got := parseRegistration("+CEREG: 1,5\r\nOK"); got != 5 {
		t.Fatalf("查询格式注册状态=%d", got)
	}
	if got := parseRegistration("+CEREG: 2"); got != 2 {
		t.Fatalf("URC 格式注册状态=%d", got)
	}
}
