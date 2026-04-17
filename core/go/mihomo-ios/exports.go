package main

// This file declares the C-callable entry points that jni_bridge.c
// wraps. They are invoked from JNI_OnLoad-registered Java_... functions.
// The rule: keep the cgo surface small and type-plain (no Go strings,
// slices, or error values cross the boundary — everything is char*,
// int, int64, or pre-allocated buffers).

/*
#include <stdlib.h>
#include <string.h>

// meow_fill_string copies up to cap-1 bytes of src into dst and NUL
// terminates. Helper used by the exports below to return strings via a
// caller-provided buffer (avoids the Go runtime owning C memory).
static inline int meow_fill_string(char *dst, int cap, const char *src) {
    if (dst == NULL || cap <= 0) { return 0; }
    int n = (int)strlen(src);
    if (n >= cap) { n = cap - 1; }
    memcpy(dst, src, n);
    dst[n] = 0;
    return n;
}
*/
import "C"

import "unsafe"

// main is required by -buildmode=c-shared but never executes.
func main() {}

//export meowEngineInit
func meowEngineInit() {
	installIOSLog()
}

//export meowSetHomeDir
func meowSetHomeDir(cdir *C.char) {
	setHomeDir(C.GoString(cdir))
}

//export meowStartEngine
func meowStartEngine(caddr, csecret *C.char) C.int {
	addr := C.GoString(caddr)
	secret := C.GoString(csecret)
	if err := startEngine(addr, secret); err != nil {
		setLastError(err.Error())
		return -1
	}
	return 0
}

//export meowStopEngine
func meowStopEngine() {
	stopEngine()
	clearProtectHook()
}

//export meowIsRunning
func meowIsRunning() C.int {
	if isRunning() {
		return 1
	}
	return 0
}

//export meowGetUploadTraffic
func meowGetUploadTraffic() C.longlong {
	return C.longlong(trafficUp())
}

//export meowGetDownloadTraffic
func meowGetDownloadTraffic() C.longlong {
	return C.longlong(trafficDown())
}

//export meowValidateConfig
func meowValidateConfig(cyaml *C.char, length C.int) C.int {
	buf := C.GoBytes(unsafe.Pointer(cyaml), length)
	if err := validateConfig(buf); err != nil {
		setLastError(err.Error())
		return -1
	}
	return 0
}

//export meowConvertSubscription
func meowConvertSubscription(craw *C.char, length C.int, dst *C.char, cap C.int) C.int {
	buf := C.GoBytes(unsafe.Pointer(craw), length)
	yaml, err := convertSubscription(buf)
	if err != nil {
		setLastError(err.Error())
		return -1
	}
	cmsg := C.CString(yaml)
	defer C.free(unsafe.Pointer(cmsg))
	return C.meow_fill_string(dst, cap, cmsg)
}

//export meowGetLastError
func meowGetLastError(dst *C.char, cap C.int) C.int {
	msg := getLastError()
	cmsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cmsg))
	return C.meow_fill_string(dst, cap, cmsg)
}

//export meowVersion
func meowVersion(dst *C.char, cap C.int) C.int {
	v := version()
	cv := C.CString(v)
	defer C.free(unsafe.Pointer(cv))
	return C.meow_fill_string(dst, cap, cv)
}

//export meowTestDirectTcp
func meowTestDirectTcp(chost *C.char, port C.int, dst *C.char, cap C.int) C.int {
	msg := testDirectTcp(C.GoString(chost), int(port))
	cmsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cmsg))
	return C.meow_fill_string(dst, cap, cmsg)
}

//export meowTestProxyHttp
func meowTestProxyHttp(curl *C.char, dst *C.char, cap C.int) C.int {
	msg := testProxyHttp(C.GoString(curl))
	cmsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cmsg))
	return C.meow_fill_string(dst, cap, cmsg)
}

//export meowTestDnsResolver
func meowTestDnsResolver(caddr *C.char, dst *C.char, cap C.int) C.int {
	msg := testDnsResolver(C.GoString(caddr))
	cmsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cmsg))
	return C.meow_fill_string(dst, cap, cmsg)
}
