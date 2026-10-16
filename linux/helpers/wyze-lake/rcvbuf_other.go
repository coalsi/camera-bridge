// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

//go:build !linux

package main

import "net"

// setReceiveBuffer asks for size bytes of receive buffer (development builds; the appliance is Linux).
func setReceiveBuffer(c *net.UDPConn, size int) int {
	if c.SetReadBuffer(size) != nil {
		return 0
	}
	return size
}
