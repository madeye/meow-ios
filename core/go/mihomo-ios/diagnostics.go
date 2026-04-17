package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"golang.org/x/net/proxy"
)

// testDirectTcp attempts a TCP connect to host:port without going through
// any proxy. Useful as a quick reachability probe from the UI.
func testDirectTcp(host string, port int) string {
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	start := time.Now()
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return fmt.Sprintf("FAIL %s: %v", addr, err)
	}
	_ = conn.Close()
	return fmt.Sprintf("OK %s (%dms)", addr, time.Since(start).Milliseconds())
}

// testProxyHttp fetches `target` through the local mihomo mixed listener
// on 127.0.0.1:7890. Used to confirm the proxy chain is routing.
func testProxyHttp(target string) string {
	proxyURL, err := url.Parse("socks5://127.0.0.1:7890")
	if err != nil {
		return fmt.Sprintf("FAIL proxy url: %v", err)
	}
	dialer, err := proxy.FromURL(proxyURL, proxy.Direct)
	if err != nil {
		return fmt.Sprintf("FAIL socks: %v", err)
	}
	transport := &http.Transport{
		Dial: dialer.Dial,
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}

	start := time.Now()
	resp, err := client.Get(target)
	if err != nil {
		return fmt.Sprintf("FAIL %s: %v", target, err)
	}
	defer resp.Body.Close()
	return fmt.Sprintf("OK %s %d (%dms)", target, resp.StatusCode, time.Since(start).Milliseconds())
}

// testDnsResolver performs a single-A-record lookup of example.com via the
// given DNS server. The server string is host:port (no protocol prefix).
func testDnsResolver(dnsAddr string) string {
	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			return d.DialContext(ctx, "udp", dnsAddr)
		},
	}
	start := time.Now()
	ips, err := r.LookupHost(context.Background(), "example.com")
	if err != nil {
		return fmt.Sprintf("FAIL %s: %v", dnsAddr, err)
	}
	return fmt.Sprintf("OK %s -> %v (%dms)", dnsAddr, ips, time.Since(start).Milliseconds())
}
