//go:build !linux

package main

import "log"

func startUSBLinkMonitor(agent *agent, logger *log.Logger) {}
