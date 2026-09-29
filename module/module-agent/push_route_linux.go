//go:build linux

package main

import (
	"net"
	"syscall"
)

func configurePushDialer(dialer *net.Dialer) {
	dialer.Control = func(_, _ string, raw syscall.RawConn) error {
		interfaceName := detectPushWANInterface()
		if interfaceName == "" {
			return nil
		}
		var socketError error
		if err := raw.Control(func(fileDescriptor uintptr) {
			socketError = syscall.SetsockoptString(
				int(fileDescriptor), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, interfaceName,
			)
		}); err != nil {
			return err
		}
		return socketError
	}
}
