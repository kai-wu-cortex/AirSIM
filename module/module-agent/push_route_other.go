//go:build !linux

package main

import "net"

func configurePushDialer(_ *net.Dialer) {}
