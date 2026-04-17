package main

import (
	"errors"
	"fmt"

	"github.com/metacubex/mihomo/common/convert"
	"gopkg.in/yaml.v3"
)

// convertSubscription parses a v2rayN-style proxy URI list (optionally
// base64-wrapped) into a minimal clash YAML config that mihomo will
// accept. The input is what the subscription endpoint returned as its
// body; ConvertsV2Ray handles both base64 and plain-text forms.
//
// The resulting YAML contains:
//   - proxies: one entry per successfully parsed URI
//   - proxy-groups: a single "Proxy" selector over all parsed proxies
//   - rules: [MATCH,Proxy]
//
// Any URIs mihomo does not recognize are silently skipped by ConvertsV2Ray;
// we treat a zero-length result as an error so the caller surfaces it.
func convertSubscription(raw []byte) (string, error) {
	if len(raw) == 0 {
		return "", errors.New("empty subscription body")
	}
	proxies, err := convert.ConvertsV2Ray(raw)
	if err != nil {
		return "", fmt.Errorf("convert nodelist: %w", err)
	}
	if len(proxies) == 0 {
		return "", errors.New("no recognizable proxies in subscription")
	}

	names := make([]string, 0, len(proxies))
	for i, p := range proxies {
		name, _ := p["name"].(string)
		if name == "" {
			name = fmt.Sprintf("Node-%d", i+1)
			p["name"] = name
		}
		names = append(names, name)
	}

	doc := map[string]any{
		"proxies": proxies,
		"proxy-groups": []map[string]any{
			{
				"name":    "Proxy",
				"type":    "select",
				"proxies": names,
			},
		},
		"rules": []string{"MATCH,Proxy"},
	}

	out, err := yaml.Marshal(doc)
	if err != nil {
		return "", fmt.Errorf("marshal yaml: %w", err)
	}
	return string(out), nil
}
