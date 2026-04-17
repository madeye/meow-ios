//go:build ios || darwin

package main

/*
#cgo darwin LDFLAGS: -framework Foundation
#include <os/log.h>
#include <stdlib.h>

// Wrapper so Go code doesn't have to deal with the os_log macro expansion
// inside an import "C" preamble. Uses the default os_log destination; the
// host process's subsystem is inherited via the extension's Info.plist.
static inline void meow_oslog(int level, const char *msg) {
    os_log_type_t t = OS_LOG_TYPE_DEFAULT;
    switch (level) {
        case 1: t = OS_LOG_TYPE_DEBUG;   break;
        case 2: t = OS_LOG_TYPE_INFO;    break;
        case 3: t = OS_LOG_TYPE_DEFAULT; break;
        case 4: t = OS_LOG_TYPE_ERROR;   break;
        case 5: t = OS_LOG_TYPE_FAULT;   break;
    }
    os_log_with_type(OS_LOG_DEFAULT, t, "%{public}s", msg);
}
*/
import "C"

import (
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/log"
)

var iosLogOnce sync.Once

func mihomoToOSLogType(lv log.LogLevel) C.int {
	switch lv {
	case log.DEBUG:
		return 1
	case log.INFO, log.SILENT:
		return 2
	case log.WARNING:
		return 3
	case log.ERROR:
		return 4
	}
	return 2
}

// installIOSLog drains mihomo's log stream into the Apple unified logging
// system. Safe to call multiple times.
func installIOSLog() {
	iosLogOnce.Do(func() {
		log.SetLevel(log.INFO)
		sub := log.Subscribe()
		go func() {
			for evt := range sub {
				cmsg := C.CString(evt.Payload)
				C.meow_oslog(mihomoToOSLogType(evt.LogLevel), cmsg)
				C.free(unsafe.Pointer(cmsg))
			}
		}()
	})
}
