package tunnel

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type relay struct{ user, host, port string }

var relayName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`)

func readRelays(input io.Reader) ([]relay, error) {
	var relays []relay
	seen := map[relay]bool{}
	scan := bufio.NewScanner(input)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		user, endpoint, _ := strings.Cut(line, "@")
		host, port, err := net.SplitHostPort(endpoint)
		n, numberErr := strconv.Atoi(port)
		if err != nil || numberErr != nil || n < 1 || n > 65535 || !relayName.MatchString(user) || !relayName.MatchString(host) {
			return nil, fmt.Errorf("中继配置格式无效，应为 用户@IPv4:端口")
		}
		item := relay{user, host, strconv.Itoa(n)}
		if !seen[item] {
			if len(relays) >= 16 {
				return nil, fmt.Errorf("最多配置 16 个中继端点")
			}
			seen[item] = true
			relays = append(relays, item)
		}
	}
	if err := scan.Err(); err != nil {
		return nil, err
	}
	if len(relays) == 0 {
		return nil, fmt.Errorf("没有已授权的中继端点")
	}
	return relays, nil
}

// Supervise retries only explicitly configured SSH endpoints. The caller keeps the TUN link alive.
func Supervise(ctx context.Context, ssh, config string, inventory io.Reader, output io.Writer) error {
	relays, err := readRelays(inventory)
	if err != nil {
		return err
	}
	logger := log.New(output, "", 0)
	backoff := 5 * time.Second
	for ctx.Err() == nil {
		for _, candidate := range relays {
			if ctx.Err() != nil {
				return nil
			}
			endpoint := net.JoinHostPort(candidate.host, candidate.port)
			dialer := net.Dialer{Timeout: 3 * time.Second}
			conn, err := dialer.DialContext(ctx, "tcp4", endpoint)
			if err != nil {
				logger.Printf("TCP 不可达 %s", endpoint)
				continue
			}
			conn.Close()
			logger.Printf("连接中继 %s", endpoint)
			if superviseRelay(ctx, ssh, config, candidate, logger, output) {
				backoff = 5 * time.Second
			}
		}
		if !sleepContext(ctx, backoff) {
			return nil
		}
		backoff = min(2*backoff, time.Minute)
	}
	return nil
}

func superviseRelay(ctx context.Context, ssh, config string, candidate relay, logger *log.Logger, output io.Writer) bool {
	childCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(childCtx, ssh, "-F", config, "-NT", "-o", "HostName="+candidate.host,
		"-p", candidate.port, "-l", candidate.user, "addipv6-relay")
	cmd.Stdout, cmd.Stderr = output, output
	if err := cmd.Start(); err != nil {
		logger.Printf("无法启动 SSH: %v", err)
		return false
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	healthy := false
	failures := 0
	delay := 3 * time.Second
	for {
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			cancel()
			<-done
			return healthy
		case err := <-done:
			timer.Stop()
			logger.Printf("SSH 已断开 %s:%s (%v)", candidate.host, candidate.port, err)
			return healthy
		case <-timer.C:
		}
		if relayIPv6Healthy(ctx) {
			if !healthy {
				logger.Printf("中继 IPv6 已连通 %s:%s", candidate.host, candidate.port)
			}
			healthy, failures, delay = true, 0, 15*time.Second
			continue
		}
		failures++
		if failures == 3 {
			logger.Printf("中继 IPv6 连续探测失败 %s:%s，换用下一端点", candidate.host, candidate.port)
			cancel()
			<-done
			return healthy
		}
	}
}

func relayIPv6Healthy(ctx context.Context) bool {
	for _, target := range []string{"2606:4700:4700::1111", "2001:4860:4860::8888"} {
		probe, cancel := context.WithTimeout(ctx, 3*time.Second)
		err := exec.CommandContext(probe, "ping", "-6", "-n", "-I", "tun64", "-c", "1", "-W", "2", target).Run()
		cancel()
		if err == nil {
			return true
		}
	}
	return false
}

func sleepContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
