// Package main wraps the upstream mihomo (Go) engine and exposes a small,
// stable cgo-exported API consumed by a JNI bridge in jni_bridge.c.
//
// This package is compiled with `go build -buildmode=c-shared` to produce
// libmihomo.so, which Kotlin loads via System.loadLibrary("mihomo").
package main

import (
	"errors"
	"path/filepath"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

var (
	engineMu      sync.Mutex
	engineRunning atomic.Bool

	lastErrorMu sync.Mutex
	lastError   string
)

func setLastError(msg string) {
	lastErrorMu.Lock()
	lastError = msg
	lastErrorMu.Unlock()
}

func getLastError() string {
	lastErrorMu.Lock()
	defer lastErrorMu.Unlock()
	return lastError
}

// setHomeDir points mihomo at the Kotlin-provided config directory so it
// loads config.yaml and any geoip / geosite assets from the correct place.
func setHomeDir(dir string) {
	constant.SetHomeDir(dir)
	// mihomo's Path.Config() returns configFile verbatim without joining
	// against HomeDir, so pass an absolute path.
	constant.SetConfig(filepath.Join(dir, "config.yaml"))
}

// startEngine parses $HOME_DIR/config.yaml and boots the mihomo hub. The
// controller address and secret override whatever the YAML says so the
// Kotlin side has a single source of truth for the RESTful API port.
func startEngine(controller, secret string) error {
	engineMu.Lock()
	defer engineMu.Unlock()

	if engineRunning.Load() {
		return errors.New("engine already running")
	}

	// Install the protect hook BEFORE ApplyConfig so every outbound dial
	// made during startup (e.g. provider fetches, URL tests) is protected.
	installProtectHook()

	opts := []hub.Option{
		hub.WithExternalController(controller),
		hub.WithSecret(secret),
	}

	// Passing nil tells hub.Parse to load from constant.Path.Config().
	if err := hub.Parse(nil, opts...); err != nil {
		return err
	}

	engineRunning.Store(true)
	log.Infoln("meow: mihomo engine started")
	return nil
}

func stopEngine() {
	engineMu.Lock()
	defer engineMu.Unlock()

	if !engineRunning.Load() {
		return
	}

	executor.Shutdown()
	engineRunning.Store(false)
	log.Infoln("meow: mihomo engine stopped")
}

func isRunning() bool {
	return engineRunning.Load()
}

// validateConfig parses a YAML config buffer without applying it. Returns
// nil on success; any error is surfaced via getLastError().
func validateConfig(yaml []byte) error {
	_, err := executor.ParseWithBytes(yaml)
	return err
}

func version() string {
	return "mihomo " + constant.Version
}
