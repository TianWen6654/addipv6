package tunnel

import (
	"context"
	"io"
	"strings"
	"testing"
)

func TestReadRelays(t *testing.T) {
	input := "# Primary\nrelay@192.0.2.10:443\nrelay@192.0.2.10:443\nrelay@192.0.2.20:22\n"
	relays, err := readRelays(strings.NewReader(input))
	if err != nil || len(relays) != 2 || relays[0].port != "443" || relays[1].host != "192.0.2.20" {
		t.Fatalf("unexpected relay inventory: %+v, %v", relays, err)
	}
	for _, invalid := range []string{"", "relay@192.0.2.10:65536", "-o@192.0.2.10:22", "relay@some host:22"} {
		if _, err := readRelays(strings.NewReader(invalid)); err == nil {
			t.Errorf("accepted invalid inventory %q", invalid)
		}
	}
}

func TestCancelledSupervisorDoesNotConnect(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Supervise(ctx, "ssh", "unused", strings.NewReader("relay@192.0.2.10:443"), io.Discard); err != nil {
		t.Fatal(err)
	}
}
