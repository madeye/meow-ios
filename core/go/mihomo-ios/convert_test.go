package main

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/hub/executor"
)

// synthNodelist returns a base64-wrapped nodelist with two ss:// entries
// pointing at 127.0.0.1:8388 using aes-256-gcm. No real endpoints, no real
// credentials — only used in tests.
func synthNodelist(t *testing.T) []byte {
	t.Helper()
	userinfo := base64.StdEncoding.EncodeToString([]byte("aes-256-gcm:testpassword123"))
	body := strings.Join([]string{
		"ss://" + userinfo + "@127.0.0.1:8388#test-node-1",
		"ss://" + userinfo + "@127.0.0.1:8388#test-node-2",
		"",
	}, "\n")
	return []byte(base64.StdEncoding.EncodeToString([]byte(body)))
}

func TestConvertSubscription_Base64Nodelist(t *testing.T) {
	yaml, err := convertSubscription(synthNodelist(t))
	if err != nil {
		t.Fatalf("convertSubscription: %v", err)
	}
	if !strings.Contains(yaml, "proxies:") {
		t.Fatalf("expected proxies: section, got:\n%s", yaml)
	}
	if !strings.Contains(yaml, "test-node-1") || !strings.Contains(yaml, "test-node-2") {
		t.Fatalf("expected both node names in output, got:\n%s", yaml)
	}
	if !strings.Contains(yaml, "MATCH,Proxy") {
		t.Fatalf("expected MATCH,Proxy rule, got:\n%s", yaml)
	}
	if _, perr := executor.ParseWithBytes([]byte(yaml)); perr != nil {
		t.Fatalf("mihomo refused converted yaml: %v\n---\n%s", perr, yaml)
	}
}

func TestConvertSubscription_Empty(t *testing.T) {
	if _, err := convertSubscription([]byte("")); err == nil {
		t.Fatal("expected error for empty body")
	}
}
