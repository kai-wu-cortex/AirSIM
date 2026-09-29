package main

import (
	"bufio"
	"io"
	"os"
	"strconv"
	"strings"
)

// selectPushWANInterface selects a cellular/default uplink while deliberately
// excluding the iPhone-facing ECM link. An empty result means the caller should
// retain normal routing rather than binding to the wrong interface.
func selectPushWANInterface(reader io.Reader) string {
	scanner := bufio.NewScanner(reader)
	selected := ""
	bestMetric := int(^uint(0) >> 1)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 8 || fields[1] != "00000000" {
			continue
		}
		interfaceName := fields[0]
		if interfaceName == "ecm0" || interfaceName == "lo" {
			continue
		}
		flags, err := strconv.ParseUint(fields[3], 16, 32)
		if err != nil || flags&0x1 == 0 {
			continue
		}
		metric, err := strconv.Atoi(fields[6])
		if err != nil {
			metric = bestMetric
		}
		if selected == "" || metric < bestMetric {
			selected = interfaceName
			bestMetric = metric
		}
	}
	return selected
}

func detectPushWANInterface() string {
	file, err := os.Open("/proc/net/route")
	if err != nil {
		return ""
	}
	defer file.Close()
	return selectPushWANInterface(file)
}
