package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const usbFaultHistoryLimit = 64

const usbFaultCoalesceWindow = time.Minute

type usbFaultSnapshot struct {
	Timestamp         time.Time         `json:"timestamp"`
	Phase             string            `json:"phase"`
	Trigger           string            `json:"trigger,omitempty"`
	Reason            string            `json:"reason,omitempty"`
	Diagnosis         string            `json:"diagnosis"`
	Carrier           string            `json:"ecm_carrier"`
	Operstate         string            `json:"ecm_operstate"`
	ECMAddresses      []string          `json:"ecm_addresses,omitempty"`
	HasECMPeer        bool              `json:"has_ecm_peer"`
	DefaultRoute      map[string]string `json:"default_route,omitempty"`
	GadgetFunctions   string            `json:"gadget_functions"`
	GadgetEnabled     string            `json:"gadget_enabled"`
	AgentPID          int               `json:"agent_pid"`
	AgentListening    bool              `json:"agent_listening_8575"`
	FactoryPID        string            `json:"ql_manager_server_pid,omitempty"`
	FactoryPIDChanged bool              `json:"ql_manager_server_pid_changed"`
	CallID            string            `json:"call_id,omitempty"`
	CallUUID          string            `json:"call_uuid,omitempty"`
	CallGeneration    uint64            `json:"call_generation,omitempty"`
}

type usbFaultStore struct {
	mu             sync.Mutex
	path           string
	limit          int
	history        []usbFaultSnapshot
	lastFactoryPID string
}

func newUSBFaultStore(path string, limit int) *usbFaultStore {
	if limit <= 0 {
		limit = usbFaultHistoryLimit
	}
	store := &usbFaultStore{path: path, limit: limit}
	data, err := os.ReadFile(path)
	if err == nil {
		_ = json.Unmarshal(data, &store.history)
	}
	if len(store.history) > limit {
		store.history = append([]usbFaultSnapshot(nil), store.history[len(store.history)-limit:]...)
	}
	for index := len(store.history) - 1; index >= 0; index-- {
		if store.history[index].FactoryPID != "" {
			store.lastFactoryPID = store.history[index].FactoryPID
			break
		}
	}
	return store
}

func (s *usbFaultStore) append(snapshot usbFaultSnapshot) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previousHistory := append([]usbFaultSnapshot(nil), s.history...)
	previousFactoryPID := s.lastFactoryPID
	if snapshot.Timestamp.IsZero() {
		snapshot.Timestamp = time.Now().UTC()
	}
	if snapshot.FactoryPID != "" {
		if s.lastFactoryPID != "" && s.lastFactoryPID != snapshot.FactoryPID {
			snapshot.FactoryPIDChanged = true
		}
		s.lastFactoryPID = snapshot.FactoryPID
	}
	snapshot.Diagnosis = classifyUSBFault(snapshot)
	if len(s.history) > 0 {
		previous := s.history[len(s.history)-1]
		age := snapshot.Timestamp.Sub(previous.Timestamp)
		if age >= 0 && age < usbFaultCoalesceWindow && usbFaultEquivalent(previous, snapshot) {
			return nil
		}
	}
	s.history = append(s.history, snapshot)
	if len(s.history) > s.limit {
		s.history = append([]usbFaultSnapshot(nil), s.history[len(s.history)-s.limit:]...)
	}
	if err := s.persistLocked(); err != nil {
		s.history = previousHistory
		s.lastFactoryPID = previousFactoryPID
		return err
	}
	return nil
}

func usbFaultEquivalent(left, right usbFaultSnapshot) bool {
	left.Timestamp = time.Time{}
	right.Timestamp = time.Time{}
	leftJSON, leftErr := json.Marshal(left)
	rightJSON, rightErr := json.Marshal(right)
	return leftErr == nil && rightErr == nil && string(leftJSON) == string(rightJSON)
}

func (s *usbFaultStore) records() []usbFaultSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]usbFaultSnapshot(nil), s.history...)
}

func (s *usbFaultStore) previousFactoryPID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastFactoryPID
}

func (s *usbFaultStore) persistLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(s.path), ".usb-faults-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		_ = temporary.Close()
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(s.history); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, s.path); err != nil {
		return err
	}
	removeTemporary = false
	return nil
}

func classifyUSBFault(snapshot usbFaultSnapshot) string {
	if strings.HasPrefix(snapshot.Carrier, "unavailable:") {
		return "ecm-interface-missing"
	}
	if snapshot.Carrier != "1" {
		return "usb-link-down"
	}
	if !snapshot.HasECMPeer {
		return "ios-address-or-route-missing"
	}
	if !snapshot.AgentListening {
		return "agent-listener-down"
	}
	if snapshot.FactoryPID == "" {
		return "factory-service-missing"
	}
	if snapshot.FactoryPIDChanged {
		return "factory-service-changed"
	}
	return "ready"
}

func (a *agent) captureUSBFaultSnapshot(phase, trigger, reason string) usbFaultSnapshot {
	snapshot := usbFaultSnapshot{
		Timestamp:       time.Now().UTC(),
		Phase:           phase,
		Trigger:         trigger,
		Reason:          reason,
		Carrier:         readDebugFile(usbCarrierPath),
		Operstate:       readDebugFile("/sys/class/net/ecm0/operstate"),
		ECMAddresses:    interfaceAddresses("ecm0"),
		HasECMPeer:      hasARPNeighbor("/proc/net/arp", "ecm0"),
		DefaultRoute:    readDefaultRoute(),
		GadgetFunctions: readDebugFile(usbGadgetPath + "/functions"),
		GadgetEnabled:   readDebugFile(usbGadgetPath + "/enable"),
		AgentPID:        os.Getpid(),
		AgentListening:  procTCPListening("/proc/net/tcp", 8575) || procTCPListening("/proc/net/tcp6", 8575),
		FactoryPID:      processIDsByName("ql_manager_server"),
	}
	if descriptor, ok := a.currentCloudCallDescriptor(); ok {
		snapshot.CallID = descriptor.CallID
		snapshot.CallUUID = strings.ToLower(descriptor.CallUUID)
		snapshot.CallGeneration = descriptor.Generation
		if snapshot.CallGeneration == 0 {
			snapshot.CallGeneration = 1
		}
	}
	if a.usbFaults != nil {
		previous := a.usbFaults.previousFactoryPID()
		if previous != "" && snapshot.FactoryPID != "" && previous != snapshot.FactoryPID {
			snapshot.FactoryPIDChanged = true
		}
	}
	snapshot.Diagnosis = classifyUSBFault(snapshot)
	return snapshot
}

func (a *agent) recordUSBFault(phase, trigger, reason string) {
	if a.usbFaults == nil {
		return
	}
	snapshot := a.captureUSBFaultSnapshot(phase, trigger, reason)
	if err := a.usbFaults.append(snapshot); err != nil {
		a.debug.add("usb", "diagnostic", "USB fault snapshot persist failed", err.Error(), nil)
	}
}

func interfaceAddresses(name string) []string {
	device, err := net.InterfaceByName(name)
	if err != nil {
		return nil
	}
	addresses, err := device.Addrs()
	if err != nil {
		return nil
	}
	result := make([]string, 0, len(addresses))
	for _, address := range addresses {
		result = append(result, address.String())
	}
	sort.Strings(result)
	return result
}

func hasARPNeighbor(path, interfaceName string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	first := true
	for scanner.Scan() {
		if first {
			first = false
			continue
		}
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 6 && fields[5] == interfaceName && fields[2] == "0x2" {
			return true
		}
	}
	return false
}

func procTCPListening(path string, port int) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	wanted := strings.ToUpper(fmt.Sprintf("%04X", port))
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 || fields[3] != "0A" {
			continue
		}
		parts := strings.Split(fields[1], ":")
		if len(parts) == 2 && strings.ToUpper(parts[1]) == wanted {
			return true
		}
	}
	return false
}

func processIDsByName(name string) string {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return ""
	}
	var identifiers []int
	for _, entry := range entries {
		identifier, err := strconv.Atoi(entry.Name())
		if err != nil || !entry.IsDir() {
			continue
		}
		comm, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "comm"))
		if err == nil && strings.TrimSpace(string(comm)) == name {
			identifiers = append(identifiers, identifier)
		}
	}
	sort.Ints(identifiers)
	values := make([]string, len(identifiers))
	for index, identifier := range identifiers {
		values[index] = strconv.Itoa(identifier)
	}
	return strings.Join(values, ",")
}

func (a *agent) usbFaultStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	current := a.captureUSBFaultSnapshot("current", "api", "")
	var history []usbFaultSnapshot
	if a.usbFaults != nil {
		history = a.usbFaults.records()
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"current": current,
		"history": history,
	})
}
