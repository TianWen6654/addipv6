package netif

import (
	"fmt"
	"net/netip"
)

var nonPublicIPv4 = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

func IsPublicIPv4(addr netip.Addr) bool {
	if !addr.Is4() || !addr.IsGlobalUnicast() || addr.IsPrivate() {
		return false
	}
	if addr == netip.AddrFrom4([4]byte{192, 0, 0, 9}) || addr == netip.AddrFrom4([4]byte{192, 0, 0, 10}) {
		return true
	}
	for _, prefix := range nonPublicIPv4 {
		if prefix.Contains(addr) {
			return false
		}
	}
	return true
}

// IPv4ToIPv6 embeds an address without changing any interface or route.
// An empty prefix selects the IPv4-mapped format; a /96 selects NAT64.
func IPv4ToIPv6(raw, prefix string) (string, error) {
	addr, err := netip.ParseAddr(raw)
	if err != nil || !addr.Is4() {
		return "", fmt.Errorf("请输入点分十进制 IPv4 地址")
	}
	if prefix == "" {
		return "::ffff:" + addr.String(), nil
	}
	network, err := netip.ParsePrefix(prefix)
	if err != nil || network.Bits() != 96 || !network.Addr().Is6() || network.Addr().Is4In6() || network != network.Masked() {
		return "", fmt.Errorf("请输入网关配置的 NAT64 /96 前缀")
	}
	if network == netip.MustParsePrefix("64:ff9b::/96") && !IsPublicIPv4(addr) {
		return "", fmt.Errorf("64:ff9b::/96 只适用于公网单播 IPv4")
	}
	out := network.Addr().As16()
	ipv4 := addr.As4()
	copy(out[12:], ipv4[:])
	return netip.AddrFrom16(out).String(), nil
}
