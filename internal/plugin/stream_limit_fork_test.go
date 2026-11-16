package plugin

import (
	"errors"
	"math"
	"os"
	"testing"
)

// TestForkStreams: the count MAGPIE_PLUGIN_STREAMS asks for, the fork's
// default when it is unset or not a whole number of 1 or more, and capped.
func TestForkStreams(t *testing.T) {
	most := min(forkStreamsMost, math.MaxInt/streamWindow)
	for _, tc := range []struct {
		in   string
		want int
	}{
		{"", forkStreamsDefault},
		{"4096", 4096},
		{" 300 ", 300},
		{"1", 1},
		{"128", 128},
		{"0", forkStreamsDefault},
		{"-5", forkStreamsDefault},
		{"lots", forkStreamsDefault},
		{"2.5", forkStreamsDefault},
		{"99999999", most},
	} {
		if got := forkStreams(tc.in); got != tc.want {
			t.Errorf("forkStreams(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// TestForkHostTakesMoreThanUpstreamsStreams: with the fork's budget, a host
// admits forkStreamsDefault plugin fetches at once, where upstream's
// admitted 128 and failed the next, and the one past the default still
// fails clearly.
func TestForkHostTakesMoreThanUpstreamsStreams(t *testing.T) {
	if os.Getenv(forkStreamsEnv) != "" {
		t.Skipf("%s is set; this checks the default", forkStreamsEnv)
	}
	if got := streamLimit(); got != forkStreamsDefault {
		t.Fatalf("streamLimit() = %d, want the fork's %d (upstream's is 128)", got, forkStreamsDefault)
	}
	f := newFakeHost(t)
	for i := range forkStreamsDefault {
		if _, _, err := f.host.begin(true); err != nil {
			t.Fatalf("fetch %d of %d: %v", i+1, forkStreamsDefault, err)
		}
	}
	if _, _, err := f.host.begin(true); !errors.Is(err, errTooManyCalls) {
		t.Fatalf("the fetch past %d = %v, want errTooManyCalls", forkStreamsDefault, err)
	}
}
