# Test Fixtures

Synthetic inputs shared across unit, integration, and E2E tests. Nothing in
this directory represents a real server, credential, or subscription — all
addresses are in `192.0.2.0/24` (RFC 5737 TEST-NET-1), UUIDs are zeros, and
passwords are the same `testpassword123` used by the Android e2e script.

## Files

- `yaml/clash_minimal.yaml` — single SS node; baseline parser input.
- `yaml/clash_full.yaml` — one node per MVP protocol; used by §6.3 protocol
  matrix tests.
- `yaml/clash_malformed.yaml` — broken indentation + unknown scalar — error
  path coverage.
- `yaml/clash_empty.yaml` — empty arrays — `noProxies` error path.
- `nodelist/v2rayn_ss_pair.txt` — base64-wrapped pair of `ss://` URIs
  (shape per `meow-go/test-e2e.sh` step 3). Conversion path coverage.

## Regenerating the v2rayN fixture

```sh
SS_USERINFO_B64=$(printf 'aes-256-gcm:testpassword123' | base64 | tr -d '\n')
printf 'ss://%s@192.0.2.1:8388#test-node-1\nss://%s@192.0.2.1:8388#test-node-2\n' \
    "$SS_USERINFO_B64" "$SS_USERINFO_B64" | base64 | tr -d '\n'
```
