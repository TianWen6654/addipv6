package tunnel

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

var publicIPv6 = netip.MustParsePrefix("2000::/3")

// RoutedAddress picks the first host of the first /64 of an assigned public prefix.
func RoutedAddress(routed string) (netip.Prefix, error) {
	prefix, err := netip.ParsePrefix(routed)
	if err != nil || !publicIPv6.Contains(prefix.Addr()) || prefix.Bits() < 3 || prefix.Bits() > 64 || prefix != prefix.Masked() {
		return netip.Prefix{}, fmt.Errorf("请输入服务商分配的公网路由前缀，例如面板里的 Routed /56 或 Routed /64")
	}
	return netip.PrefixFrom(prefix.Addr().Next(), 64), nil
}

// Import converts a single-peer tunnel broker profile into an IPv6-only wg-quick profile.
func Import(input io.Reader, routed string) (string, error) {
	address, err := RoutedAddress(routed)
	if err != nil {
		return "", err
	}
	prefix := netip.MustParsePrefix(routed)
	anchor := address.Addr()
	interfaceFields, peerFields, err := readProfile(input)
	if err != nil {
		return "", err
	}
	if !validKey(interfaceFields["privatekey"]) || !validKey(peerFields["publickey"]) {
		return "", fmt.Errorf("配置缺少有效的 WireGuard 私钥或对端公钥")
	}
	psk := peerFields["presharedkey"]
	if psk != "" && !validKey(psk) {
		return "", fmt.Errorf("WireGuard 预共享密钥格式错误")
	}
	endpoint := peerFields["endpoint"]
	host, port, err := net.SplitHostPort(endpoint)
	portNumber, portErr := strconv.Atoi(port)
	if err != nil || portErr != nil || portNumber < 1 || portNumber > 65535 || !validIPv4Endpoint(host) {
		return "", fmt.Errorf("Endpoint 必须是服务商的 IPv4 地址或可通过 IPv4 访问的域名，加 UDP 端口")
	}
	if !hasIPv6Default(peerFields["allowedips"]) {
		return "", fmt.Errorf("请使用支持整个 IPv6 互联网的配置（AllowedIPs 含 ::/0）")
	}

	var profile strings.Builder
	fmt.Fprintf(&profile, "# Managed by addipv6\n[Interface]\nPrivateKey = %s\n", interfaceFields["privatekey"])
	for _, item := range strings.Split(interfaceFields["address"], ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		address, err := netip.ParsePrefix(item)
		if err != nil {
			return "", fmt.Errorf("WireGuard Address 须使用有效的 CIDR")
		}
		if !address.Addr().Is6() || address.Addr().Is4In6() {
			continue
		}
		if prefix.Overlaps(address.Masked()) {
			return "", fmt.Errorf("路由前缀与隧道传输地址重叠，请使用服务商单独分配的 Routed 前缀")
		}
		// /128 keeps the provider's transfer network out of addipv6's batch choices.
		fmt.Fprintf(&profile, "Address = %s/128\n", address.Addr())
	}
	if mtu := interfaceFields["mtu"]; mtu != "" {
		size, err := strconv.Atoi(mtu)
		if err != nil || size < 1280 || size > 65535 {
			return "", fmt.Errorf("WireGuard MTU 必须在 1280 到 65535 之间")
		}
		fmt.Fprintf(&profile, "MTU = %d\n", size)
	}
	fmt.Fprintf(&profile, "Table = off\nPostUp = ip -6 addr add %s/64 dev %%i nodad\nPostUp = ip -6 route add default dev %%i src %s metric 4096\n", anchor, anchor)
	fmt.Fprintf(&profile, "\n[Peer]\nPublicKey = %s\n", peerFields["publickey"])
	if psk != "" {
		fmt.Fprintf(&profile, "PresharedKey = %s\n", psk)
	}
	fmt.Fprintf(&profile, "Endpoint = %s\nAllowedIPs = ::/0\nPersistentKeepalive = 25\n", net.JoinHostPort(host, strconv.Itoa(portNumber)))
	return profile.String(), nil
}

func readProfile(input io.Reader) (map[string]string, map[string]string, error) {
	interfaceFields := make(map[string]string)
	peerFields := make(map[string]string)
	var section map[string]string
	seenInterface, seenPeer := false, false
	scanner := bufio.NewScanner(input)
	for scanner.Scan() {
		line, _, _ := strings.Cut(scanner.Text(), "#")
		line = strings.TrimSpace(line)
		switch strings.ToLower(line) {
		case "":
			continue
		case "[interface]":
			if seenInterface || seenPeer {
				return nil, nil, fmt.Errorf("WireGuard 配置须包含一个 [Interface] 和一个 [Peer]")
			}
			seenInterface, section = true, interfaceFields
		case "[peer]":
			if !seenInterface || seenPeer {
				return nil, nil, fmt.Errorf("WireGuard 配置须包含一个 [Interface] 和一个 [Peer]")
			}
			seenPeer, section = true, peerFields
		default:
			name, value, ok := strings.Cut(line, "=")
			if !ok || section == nil || strings.HasPrefix(line, "[") {
				return nil, nil, fmt.Errorf("WireGuard 配置格式错误")
			}
			name = strings.ToLower(strings.TrimSpace(name))
			value = strings.TrimSpace(value)
			if old := section[name]; old != "" && (name == "address" || name == "allowedips") {
				value = old + "," + value
			}
			section[name] = value
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, nil, fmt.Errorf("无法读取 WireGuard 配置: %w", err)
	}
	if !seenPeer {
		return nil, nil, fmt.Errorf("WireGuard 配置缺少 [Peer]")
	}
	return interfaceFields, peerFields, nil
}

func validKey(key string) bool {
	b, err := base64.StdEncoding.Strict().DecodeString(key)
	return err == nil && len(b) == 32 && base64.StdEncoding.EncodeToString(b) == key
}

func validIPv4Endpoint(host string) bool {
	if addr, err := netip.ParseAddr(host); err == nil {
		return addr.Is4() && addr.IsGlobalUnicast()
	}
	if len(host) > 253 || !strings.Contains(host, ".") {
		return false
	}
	for _, label := range strings.Split(strings.TrimSuffix(host, "."), ".") {
		if len(label) == 0 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
		for _, ch := range strings.ToLower(label) {
			if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-') {
				return false
			}
		}
	}
	return true
}

func hasIPv6Default(allowed string) bool {
	defaultRoute := netip.PrefixFrom(netip.IPv6Unspecified(), 0)
	for _, item := range strings.Split(allowed, ",") {
		if p, err := netip.ParsePrefix(strings.TrimSpace(item)); err == nil && p.Masked() == defaultRoute {
			return true
		}
	}
	return false
}
