// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

//go:build linux

package main

import (
	"net"
	"syscall"
)

// setReceiveBuffer asks for size bytes of kernel receive buffer. SO_RCVBUFFORCE (root or CAP_NET_ADMIN) ignores
// net.core.rmem_max; otherwise SO_RCVBUF is capped at it (208 KiB on a stock Debian kernel; raise it with
// sysctl -w net.core.rmem_max=8388608). Returns what the kernel granted (Linux reports double the request).
func setReceiveBuffer(c *net.UDPConn, size int) int {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0
	}
	got := 0
	_ = raw.Control(func(fd uintptr) {
		if syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUFFORCE, size) != nil {
			_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, size)
		}
		got, _ = syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF)
	})
	return got
}
