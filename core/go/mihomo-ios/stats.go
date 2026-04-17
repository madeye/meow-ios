package main

import "github.com/metacubex/mihomo/tunnel/statistic"

// trafficUp and trafficDown return the cumulative upload/download byte
// counters that mihomo maintains in its default statistic manager. The
// Kotlin side polls these and derives rates.
func trafficUp() int64 {
	if statistic.DefaultManager == nil {
		return 0
	}
	up, _ := statistic.DefaultManager.Total()
	return up
}

func trafficDown() int64 {
	if statistic.DefaultManager == nil {
		return 0
	}
	_, down := statistic.DefaultManager.Total()
	return down
}
