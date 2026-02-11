package tailnet

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

type Config struct {
	AuthKey  string
	Hostname string
	StateDir string
	Port     int
}

type Instance struct {
	Server      *tsnet.Server
	LocalClient *local.Client
	Listener    net.Listener
	ConnectHint string
}

func Start(ctx context.Context, cfg Config) (*Instance, error) {
	authKey := strings.TrimSpace(cfg.AuthKey)
	if authKey == "" {
		return nil, fmt.Errorf("tsnet auth key is required")
	}
	if strings.TrimSpace(cfg.Hostname) == "" {
		cfg.Hostname = "climate-server"
	}
	if strings.TrimSpace(cfg.StateDir) == "" {
		return nil, fmt.Errorf("tsnet state dir is required")
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		return nil, fmt.Errorf("failed to create tsnet state dir: %w", err)
	}

	server := &tsnet.Server{
		AuthKey:  authKey,
		Hostname: cfg.Hostname,
		Dir:      cfg.StateDir,
		Logf:     log.Printf,
	}

	listener, err := server.Listen("tcp", fmt.Sprintf(":%d", cfg.Port))
	if err != nil {
		_ = server.Close()
		return nil, fmt.Errorf("tsnet listen failed: %w", err)
	}

	localClient, _ := server.LocalClient()

	inst := &Instance{
		Server:      server,
		LocalClient: localClient,
		Listener:    listener,
		ConnectHint: bestEffortConnectHint(ctx, server, cfg.Port),
	}

	// bestEffortConnectHint can be empty during early startup; update it later once
	// tailscale status is available, to reduce client-side confusion about the URL.
	if inst.ConnectHint == "" {
		go inst.updateConnectHint(ctx, cfg.Port)
	}

	return inst, nil
}

func (i *Instance) Close() error {
	if i == nil || i.Server == nil {
		return nil
	}
	return i.Server.Close()
}

func bestEffortConnectHint(ctx context.Context, server *tsnet.Server, port int) string {
	client, err := server.LocalClient()
	if err != nil {
		return ""
	}
	status, err := client.Status(ctx)
	if err != nil || status == nil || status.Self == nil {
		return ""
	}

	name := strings.TrimSuffix(status.Self.DNSName, ".")
	if name == "" && status.Self.HostName != "" && status.MagicDNSSuffix != "" {
		name = status.Self.HostName + "." + status.MagicDNSSuffix
	}
	if name == "" {
		return ""
	}
	return fmt.Sprintf("http://%s:%d", name, port)
}

func (i *Instance) updateConnectHint(ctx context.Context, port int) {
	if i == nil || i.LocalClient == nil {
		return
	}

	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			return
		case <-ticker.C:
			status, err := i.LocalClient.Status(ctx)
			if err != nil || status == nil || status.Self == nil {
				continue
			}

			name := strings.TrimSuffix(status.Self.DNSName, ".")
			if name == "" && status.Self.HostName != "" && status.MagicDNSSuffix != "" {
				name = status.Self.HostName + "." + status.MagicDNSSuffix
			}
			if name == "" {
				continue
			}

			hint := fmt.Sprintf("http://%s:%d", name, port)
			i.ConnectHint = hint
			log.Printf("[tsnet] connect hint: %s", hint)
			return
		}
	}
}
