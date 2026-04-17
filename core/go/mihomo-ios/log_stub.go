//go:build !ios && !darwin

package main

// installIOSLog is a no-op on non-Apple builds so `go vet` can run on a
// Linux/Android host without linking against the os_log bridge.
func installIOSLog() {}
