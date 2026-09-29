//go:build linux

package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"strings"
	"syscall"
	"time"
)

const netlinkRouteGroupLink = 1

func startUSBLinkMonitor(agent *agent, logger *log.Logger) {
	debouncer := newUSBReconnectDebouncer(agent, logger)
	go pollECMLinkState(context.Background(), usbCarrierPollInterval, func() ecmLinkState {
		carrier, err := os.ReadFile(usbCarrierPath)
		return detectECMLinkState(carrier, err)
	}, debouncer.linkStateChanged)
	go func() {
		for {
			if err := monitorUSBLinkEvents(debouncer); err != nil {
				agent.debug.add("usb", "event", "netlink monitor restarting", "", map[string]string{"error": err.Error()})
				logger.Printf("ecm0 netlink 监听恢复中: %v", err)
				time.Sleep(2 * time.Second)
			}
		}
	}()
}

func monitorUSBLinkEvents(debouncer *usbReconnectDebouncer) error {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	if err := syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK, Groups: netlinkRouteGroupLink}); err != nil {
		return err
	}
	if carrier, err := os.ReadFile(usbCarrierPath); err == nil {
		debouncer.carrierChanged(strings.TrimSpace(string(carrier)) == "0")
	}

	buffer := make([]byte, 16*1024)
	for {
		count, _, err := syscall.Recvfrom(fd, buffer, 0)
		if err != nil {
			return err
		}
		messages, err := syscall.ParseNetlinkMessage(buffer[:count])
		if err != nil {
			continue
		}
		for index := range messages {
			message := &messages[index]
			if message.Header.Type != syscall.RTM_NEWLINK && message.Header.Type != syscall.RTM_DELLINK {
				continue
			}
			attributes, err := syscall.ParseNetlinkRouteAttr(message)
			if err != nil {
				continue
			}
			interfaceName := ""
			for _, attribute := range attributes {
				if attribute.Attr.Type == syscall.IFLA_IFNAME {
					interfaceName = string(bytes.TrimRight(attribute.Value, "\x00"))
					break
				}
			}
			if interfaceName != "ecm0" {
				continue
			}
			if message.Header.Type == syscall.RTM_DELLINK {
				debouncer.linkStateChanged(ecmLinkMissing)
				continue
			}
			carrier, err := os.ReadFile(usbCarrierPath)
			debouncer.linkStateChanged(detectECMLinkState(carrier, err))
		}
	}
}
