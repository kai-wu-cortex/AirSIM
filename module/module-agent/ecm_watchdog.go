package main

import (
	"fmt"
	"strings"
)

func ecmWatchdogFields(
	state ecmLinkState,
	phase string,
	reason string,
	driver string,
	interfaceName string,
	functions string,
	descriptor *cloudCallDescriptor,
) map[string]string {
	stateName := "unknown"
	switch state {
	case ecmLinkUp:
		stateName = "up"
	case ecmLinkCarrierDown:
		stateName = "carrier_down"
	case ecmLinkMissing:
		stateName = "missing"
	}
	fields := map[string]string{
		"state": stateName, "phase": phase, "reason": reason,
		"driver": driver, "interface": interfaceName,
		"usb_functions": strings.TrimSpace(functions),
	}
	if descriptor != nil {
		generation := descriptor.Generation
		if generation == 0 {
			generation = 1
		}
		fields["call_id"] = descriptor.CallID
		fields["call_uuid"] = strings.ToLower(descriptor.CallUUID)
		fields["generation"] = fmt.Sprintf("%d", generation)
	}
	return fields
}

func (a *agent) recordECMWatchdogEvent(state ecmLinkState, phase, reason string) {
	functions := readDebugFile(usbGadgetPath + "/functions")
	var descriptorPointer *cloudCallDescriptor
	if descriptor, ok := a.currentCloudCallDescriptor(); ok {
		descriptorCopy := descriptor
		descriptorPointer = &descriptorCopy
	}
	fields := ecmWatchdogFields(
		state, phase, reason, "qcom_ecm", "ecm0", functions, descriptorPointer,
	)
	a.debug.add("ecm-watchdog", "event", "ECM 状态变化", reason, fields)
}
