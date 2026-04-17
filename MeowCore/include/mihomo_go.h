// Generated stub — overwritten by `cgo -buildmode=c-archive` during
// `scripts/build-go.sh` with the canonical libmihomo_ios.h. Committed so
// Swift can import the symbols before the first Go build.
//
// Keep in sync with core/go/mihomo-ios/exports.go.
#pragma once
#ifndef MIHOMO_GO_H
#define MIHOMO_GO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One-time init of the Go runtime logger. Safe to call more than once.
void meowEngineInit(void);

/// Set the directory where mihomo looks for config.yaml and geo assets.
void meowSetHomeDir(const char *dir);

/// Start the mihomo engine bound to a local REST controller.
/// Returns 0 on success, -1 on failure (see meowGetLastError).
int meowStartEngine(const char *controller, const char *secret);

/// Stop the engine. Idempotent.
void meowStopEngine(void);

/// Returns 1 while the engine is running, 0 otherwise.
int meowIsRunning(void);

/// Cumulative upload/download byte counters from mihomo's default stats.
long long meowGetUploadTraffic(void);
long long meowGetDownloadTraffic(void);

/// Validate a YAML config without applying it. Returns 0 on success, -1 on
/// error. Error details via meowGetLastError.
int meowValidateConfig(const char *yaml, int length);

/// Convert a v2rayN-style (possibly base64-wrapped) subscription body into a
/// Clash YAML document. Writes up to `cap-1` bytes into `dst`, NUL-terminates,
/// and returns the length written. Returns -1 on error.
int meowConvertSubscription(const char *raw, int length, char *dst, int cap);

/// Last error message set by the most recent failing call on any goroutine.
/// Writes up to `cap-1` bytes into `dst`, NUL-terminates, returns length.
int meowGetLastError(char *dst, int cap);

/// mihomo version string (e.g. "mihomo 1.19.23").
int meowVersion(char *dst, int cap);

/// Diagnostics — each writes a human-readable result into `dst`.
int meowTestDirectTcp(const char *host, int port, char *dst, int cap);
int meowTestProxyHttp(const char *url, char *dst, int cap);
int meowTestDnsResolver(const char *addr, char *dst, int cap);

#ifdef __cplusplus
}
#endif

#endif /* MIHOMO_GO_H */
