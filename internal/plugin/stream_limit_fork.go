package plugin

import (
	"math"
	"os"
	"strconv"
	"strings"
)

// This file is the private fork's only change to the plugin host: how many
// plugin fetches the Bun host takes at once. Upstream's budget
// (streamBudget/streamWindow, 64MB/512KB) allows 128, shared by every
// plugin provider, and a fetch past it waits up to streamWait and then
// fails. That caps a gateway at 128 × 60 ÷ (average seconds a request
// lasts) RPM, about 256 RPM for 30s agent turns, so this raises it.
//
// Only the budget changes. streamWindow, one call's credit, stays the same,
// so a single reply streams as before and host.js is untouched: it takes
// the window from each fetch's params. The budget bounds what queued frames
// may hold, not what is allocated, so a larger one costs memory only while
// readers fall behind.

// forkStreamsEnv sets the number of plugin fetches in flight at once.
const forkStreamsEnv = "MAGPIE_PLUGIN_STREAMS"

// forkStreamsDefault is the fork's count when forkStreamsEnv is unset or
// isn't a whole number from 1 up: 16 times upstream's, a budget of 1GB.
const forkStreamsDefault = 2048

// forkStreamsMost caps forkStreamsEnv: 65536 windows is a 32GB budget,
// beyond any host's memory.
const forkStreamsMost = 65536

func init() {
	streamBudget = forkStreams(os.Getenv(forkStreamsEnv)) * streamWindow
}

// forkStreams is the count forkStreamsEnv asks for: forkStreamsDefault
// when v is empty or not a whole number of 1 or more, at most
// forkStreamsMost, and never so many that the budget overflows an int
// (a 32-bit build).
func forkStreams(v string) int {
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < 1 {
		n = forkStreamsDefault
	}
	most := min(forkStreamsMost, math.MaxInt/streamWindow)
	return min(n, most)
}
