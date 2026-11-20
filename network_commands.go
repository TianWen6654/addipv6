package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/byJoey/addipv6/internal/cfapi"
	"github.com/byJoey/addipv6/internal/netif"
	"github.com/byJoey/addipv6/internal/store"
)

func runIPv4ToIPv6(args []string) int {
	var prefix string
	switch {
	case len(args) == 1:
	case len(args) == 2 && args[1] == "--nat64":
		prefix = "64:ff9b::/96"
	case len(args) == 3 && args[1] == "--nat64-prefix" && args[2] != "":
		prefix = args[2]
	default:
		fmt.Fprintln(os.Stderr, "用法：addipv6 ipv4-to-ipv6 <IPv4> [--nat64 | --nat64-prefix <IPv6/96>]")
		return 2
	}
	result, err := netif.IPv4ToIPv6(args[0], prefix)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(result)
	return 0
}

func runCloudflareWeb(args []string) int {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "用法：addipv6 cloudflare-web <配置目录> <完整域名模板> <公网IPv4> [--count N] [--ipv6-only]")
		return 2
	}
	flags := flag.NewFlagSet("cloudflare-web", flag.ContinueOnError)
	count := flags.Int("count", 1, "域名数量（1 至 1000）")
	ipv6Only := flags.Bool("ipv6-only", false, "边缘 DNS 只公布 AAAA")
	zone := flags.String("zone", "", "直接使用 ADDIPV6_CF_TOKEN 时的 Cloudflare 站点域名")
	zoneID := flags.String("zone-id", "", "直接使用 ADDIPV6_CF_TOKEN 时的 Cloudflare Zone ID")
	if err := flags.Parse(args[3:]); err != nil || flags.NArg() != 0 {
		return 2
	}
	if err := publishCloudflareWeb(args[0], args[1], args[2], *count, *ipv6Only, *zone, *zoneID); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func publishCloudflareWeb(configDir, template, ipv4 string, count int, ipv6Only bool, zone, zoneID string) error {
	addr, err := netip.ParseAddr(ipv4)
	if err != nil || !netif.IsPublicIPv4(addr) {
		return fmt.Errorf("源站需要可被 Cloudflare 访问的公网 IPv4")
	}
	cfg, err := cloudflareWebConfig(configDir, zone, zoneID)
	if err != nil {
		return err
	}
	cred := cfapi.Credential{Mode: cfg.AuthMode, Email: cfg.Email, Key: cfg.GlobalKey, Token: cfg.Token}.Normalize()
	if !cred.Valid() || cfg.ZoneID == "" || cfg.ZoneName == "" {
		return fmt.Errorf("请先在 addipv6 网页配置 Cloudflare 并选择站点")
	}
	names, err := cloudflareWebNames(template, cfg.ZoneName, count)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second+time.Duration(count)*time.Second)
	defer cancel()
	results, err := cfapi.NewWithCredential(cred).EnsureProxiedIPv4(ctx, cfg.ZoneID, names, addr, ipv6Only)
	for _, result := range results {
		switch {
		case result.Created:
			fmt.Printf("已创建 Cloudflare 代理 A 记录：%s → %s\n", result.Name, addr)
		case result.Updated:
			fmt.Printf("已恢复 Cloudflare 双栈入口：%s → %s\n", result.Name, addr)
		default:
			fmt.Printf("Cloudflare 代理 A 记录已存在：%s → %s\n", result.Name, addr)
		}
	}
	if err != nil {
		return err
	}
	if ipv6Only {
		fmt.Printf("完成 %d 个域名。Cloudflare 仅发布 IPv6 入口，源站仍使用 IPv4。\n", len(results))
	} else {
		fmt.Printf("完成 %d 个域名。Cloudflare 开启 IPv6 兼容时，访客可通过 IPv4 或 IPv6 访问，源站仍使用 IPv4。\n", len(results))
	}
	return nil
}

func cloudflareWebConfig(configDir, zone, zoneID string) (store.CloudflareConfig, error) {
	if zone != "" || zoneID != "" {
		token := strings.TrimSpace(os.Getenv("ADDIPV6_CF_TOKEN"))
		if zone == "" || zoneID == "" || token == "" {
			return store.CloudflareConfig{}, fmt.Errorf("直接连接需要设置 ADDIPV6_CF_TOKEN，并同时指定 --zone 和 --zone-id")
		}
		return store.CloudflareConfig{Token: token, ZoneName: zone, ZoneID: zoneID}, nil
	}
	raw, err := os.ReadFile(filepath.Join(configDir, "config.json"))
	if err != nil {
		return store.CloudflareConfig{}, fmt.Errorf("请先在网页配置 Cloudflare，或使用 ADDIPV6_CF_TOKEN、--zone 和 --zone-id: %w", err)
	}
	var config store.Config
	if err := json.Unmarshal(raw, &config); err != nil {
		return store.CloudflareConfig{}, fmt.Errorf("无法读取 Cloudflare 配置: %w", err)
	}
	return config.Cloudflare, nil
}

func cloudflareWebNames(template, zone string, count int) ([]string, error) {
	if count < 1 || count > 1000 {
		return nil, fmt.Errorf("域名数量必须在 1 到 1000 之间")
	}
	template = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(template), "."))
	zone = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(zone), "."))
	if zone == "" || (template != zone && !strings.HasSuffix(template, "."+zone)) || strings.ContainsAny(template, "*_") {
		return nil, fmt.Errorf("请输入已选站点 %s 下的完整网站域名或模板", zone)
	}
	if count > 1 && !cfapi.HasPlaceholder(template) {
		return nil, fmt.Errorf("批量创建需要序号占位符，例如 web-{n}.%s", zone)
	}
	return cfapi.ExpandNames(template, zone, count)
}
