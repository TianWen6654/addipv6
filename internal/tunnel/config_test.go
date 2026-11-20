package tunnel

import (
	"encoding/base64"
	"strings"
	"testing"
)

func testProfile() string {
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	return "[Interface]\r\nPrivateKey = " + key + `
Address = 192.0.2.2/32, 2001:db8:1::2/64
DNS = 192.0.2.53
Table = 999
PostUp = echo untrusted
SaveConfig = true

[Peer]
PublicKey = ` + key + `
Endpoint = 192.0.2.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
`
}

func TestImportRoutedIPv6Only(t *testing.T) {
	profile, err := Import(strings.NewReader(testProfile()), "2001:db8:abcd:1200::/56")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"Address = 2001:db8:1::2/128",
		"Table = off",
		"PostUp = ip -6 addr add 2001:db8:abcd:1200::1/64 dev %i nodad",
		"PostUp = ip -6 route add default dev %i src 2001:db8:abcd:1200::1 metric 4096",
		"Endpoint = 192.0.2.1:51820",
		"AllowedIPs = ::/0",
		"PersistentKeepalive = 25",
	} {
		if !strings.Contains(profile, want) {
			t.Errorf("generated profile missing %q", want)
		}
	}
	for _, excluded := range []string{"192.0.2.2", "DNS =", "0.0.0.0/0", "echo untrusted", "SaveConfig"} {
		if strings.Contains(profile, excluded) {
			t.Errorf("imported undesired directive %q", excluded)
		}
	}
}

func TestImportRejectsInvalidTunnel(t *testing.T) {
	valid := testProfile()
	tests := []struct{ label, profile, prefix string }{
		{"private prefix", valid, "fd00::/64"},
		{"non-network prefix", valid, "2001:db8:2::1/64"},
		{"overlapping prefix", valid, "2001:db8:1::/64"},
		{"IPv6-only endpoint", strings.Replace(valid, "192.0.2.1:51820", "[2001:db8::1]:51820", 1), "2001:db8:2::/64"},
		{"narrow allowed IPs", strings.Replace(valid, "::/0", "2001:db8::/32", 1), "2001:db8:2::/64"},
		{"multiple peers", valid + "[Peer]\n", "2001:db8:2::/64"},
	}
	for _, tt := range tests {
		t.Run(tt.label, func(t *testing.T) {
			if _, err := Import(strings.NewReader(tt.profile), tt.prefix); err == nil {
				t.Fatal("invalid tunnel profile accepted")
			}
		})
	}
}
