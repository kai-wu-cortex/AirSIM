package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type systemPowerStatus struct {
	Supported   bool                 `json:"supported"`
	Readings    []systemPowerReading `json:"readings"`
	SampledAtMS int64                `json:"sampled_at_ms"`
}

type systemPowerReading struct {
	Kind            string   `json:"kind"`
	Name            string   `json:"name"`
	Path            string   `json:"path"`
	VoltageV        *float64 `json:"voltage_v,omitempty"`
	CurrentA        *float64 `json:"current_a,omitempty"`
	PowerW          *float64 `json:"power_w,omitempty"`
	TemperatureC    *float64 `json:"temperature_c,omitempty"`
	CapacityPercent *int     `json:"capacity_percent,omitempty"`
	Online          *bool    `json:"online,omitempty"`
	Status          string   `json:"status,omitempty"`
}

func (a *agent) systemPower(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	writeJSON(response, http.StatusOK, readSystemPower("/"))
}

// readSystemPower scans only documented, read-only Linux sysfs measurements.
// root is injectable so the parser can be validated without depending on the host machine.
func readSystemPower(root string) systemPowerStatus {
	readings := make([]systemPowerReading, 0)
	thermalNames := make(map[string]bool)

	for _, path := range globUnderRoot(root, "sys/class/power_supply/*") {
		reading := systemPowerReading{
			Kind: "power_supply", Name: filepath.Base(path), Path: rootedDisplayPath(root, path),
		}
		reading.VoltageV = readPositiveScaledFloat(filepath.Join(path, "voltage_now"), 1_000_000)
		reading.CurrentA = readPositiveScaledFloat(filepath.Join(path, "current_now"), 1_000_000)
		reading.PowerW = readPositiveScaledFloat(filepath.Join(path, "power_now"), 1_000_000)
		if reading.PowerW == nil && reading.VoltageV != nil && reading.CurrentA != nil {
			power := *reading.VoltageV * *reading.CurrentA
			reading.PowerW = &power
		}
		reading.CapacityPercent = readInt(filepath.Join(path, "capacity"))
		if online := readInt(filepath.Join(path, "online")); online != nil {
			value := *online != 0
			reading.Online = &value
		}
		reading.Status = readText(filepath.Join(path, "status"))
		if hasPowerMetric(reading) {
			readings = append(readings, reading)
		}
	}

	// QDC507 (MDM9607/PM8019) does not publish a usable voltage_now value.
	// Its qpnp-vadc driver exposes calibrated values as
	// "Result:<micro-units> Raw:<hex>" instead. vbat_sns is the battery
	// voltage, while the product-specific vph_pwr value is presented as
	// power; current is derived as P / V.
	for _, devicePath := range globUnderRoot(root, "sys/devices/qpnp-vadc-*") {
		batteryPath := filepath.Join(devicePath, "vbat_sns")
		batteryVoltage := parseQPNPVADCResult(readText(batteryPath))
		if batteryVoltage != nil {
			readings = append(readings, systemPowerReading{
				Kind: "adc", Name: "vbat_sns", Path: rootedDisplayPath(root, batteryPath), VoltageV: batteryVoltage,
			})
		}

		powerPath := filepath.Join(devicePath, "vph_pwr")
		power := parseQPNPVADCResult(readText(powerPath))
		if power == nil {
			continue
		}
		reading := systemPowerReading{
			Kind: "adc", Name: "vph_pwr", Path: rootedDisplayPath(root, powerPath), PowerW: power,
		}
		if batteryVoltage != nil && *batteryVoltage > 0 {
			current := *power / *batteryVoltage
			reading.CurrentA = &current
		}
		readings = append(readings, reading)
	}

	for _, path := range globUnderRoot(root, "sys/class/thermal/thermal_zone*") {
		temperature := readTemperature(filepath.Join(path, "temp"))
		if temperature == nil {
			continue
		}
		name := readText(filepath.Join(path, "type"))
		if name == "" {
			name = filepath.Base(path)
		}
		readings = append(readings, systemPowerReading{
			Kind: "thermal", Name: name, Path: rootedDisplayPath(root, path), TemperatureC: temperature,
		})
		thermalNames[name] = true
	}

	for _, path := range globUnderRoot(root, "sys/class/hwmon/hwmon*") {
		reading := systemPowerReading{
			Kind: "hwmon", Name: readText(filepath.Join(path, "name")), Path: rootedDisplayPath(root, path),
		}
		if reading.Name == "" {
			reading.Name = filepath.Base(path)
		}
		// hwmon ABI: voltage/current inputs are milli-units, power is microwatts, temperature is millidegrees.
		reading.VoltageV = readPositiveScaledFloat(filepath.Join(path, "in1_input"), 1_000)
		reading.CurrentA = readPositiveScaledFloat(filepath.Join(path, "curr1_input"), 1_000)
		reading.PowerW = readPositiveScaledFloat(filepath.Join(path, "power1_input"), 1_000_000)
		reading.TemperatureC = readTemperature(filepath.Join(path, "temp1_input"))
		if thermalNames[reading.Name] {
			reading.TemperatureC = nil
		}
		if hasPowerMetric(reading) {
			readings = append(readings, reading)
		}
	}

	return systemPowerStatus{
		Supported: len(readings) > 0, Readings: readings, SampledAtMS: time.Now().UnixMilli(),
	}
}

func globUnderRoot(root, pattern string) []string {
	paths, _ := filepath.Glob(filepath.Join(root, filepath.FromSlash(pattern)))
	return paths
}

func rootedDisplayPath(root, path string) string {
	if root == "/" {
		return path
	}
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return path
	}
	return "/" + filepath.ToSlash(relative)
}

func readText(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func readScaledFloat(path string, divisor float64) *float64 {
	text := readText(path)
	if text == "" {
		return nil
	}
	value, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return nil
	}
	value /= divisor
	return &value
}

func readPositiveScaledFloat(path string, divisor float64) *float64 {
	value := readScaledFloat(path, divisor)
	if value == nil || *value <= 0 {
		return nil
	}
	return value
}

func parseQPNPVADCResult(text string) *float64 {
	for _, field := range strings.Fields(text) {
		if !strings.HasPrefix(field, "Result:") {
			continue
		}
		microvolts, err := strconv.ParseFloat(strings.TrimPrefix(field, "Result:"), 64)
		if err != nil || microvolts <= 0 {
			return nil
		}
		volts := microvolts / 1_000_000
		return &volts
	}
	return nil
}

// QDC507 的 3.18 内核直接返回摄氏度；常规 sysfs/hwmon 则返回毫摄氏度。
func readTemperature(path string) *float64 {
	value := readScaledFloat(path, 1)
	if value == nil {
		return nil
	}
	if *value > 1_000 || *value < -1_000 {
		*value /= 1_000
	}
	if *value < -100 || *value > 250 {
		return nil
	}
	return value
}

func readInt(path string) *int {
	text := readText(path)
	if text == "" {
		return nil
	}
	value, err := strconv.Atoi(text)
	if err != nil {
		return nil
	}
	return &value
}

func hasPowerMetric(reading systemPowerReading) bool {
	return reading.VoltageV != nil || reading.CurrentA != nil || reading.PowerW != nil ||
		reading.TemperatureC != nil || reading.CapacityPercent != nil || reading.Online != nil || reading.Status != ""
}
