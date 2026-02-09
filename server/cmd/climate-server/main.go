package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"climate/server/internal/app"
	"climate/server/internal/config"
)

func main() {
	loaded, err := config.Load(os.Args[1:])
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	cfg := app.Config{
		CodexBin:   loaded.Config.CodexBin,
		BindIP:     loaded.Config.BindIP,
		Port:       loaded.Config.Port,
		TSAuthKey:  loaded.Config.TSAuthKey,
		TSHostname: loaded.Config.TSHostname,
		TSStateDir: loaded.Config.TSStateDir,
	}

	flag.StringVar(&cfg.CodexBin, "codex-bin", valueOr(cfg.CodexBin, "codex"), "Path to codex binary")
	flag.StringVar(&cfg.BindIP, "bind-ip", valueOr(cfg.BindIP, "127.0.0.1"), "Local bind IP")
	flag.IntVar(&cfg.Port, "port", valueOrInt(cfg.Port, 4500), "Port to serve")
	flag.StringVar(&cfg.TSAuthKey, "ts-auth-key", valueOr(cfg.TSAuthKey, ""), "Tailscale auth key (tsnet)")
	flag.StringVar(&cfg.TSHostname, "ts-hostname", valueOr(cfg.TSHostname, "climate-server"), "Tailscale hostname")
	flag.StringVar(&cfg.TSStateDir, "ts-state-dir", cfg.TSStateDir, "State directory for tsnet (default ~/.climate/tsnet)")
	flag.String("config", loaded.ConfigFile, "Path to config file (yaml)")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := app.Run(ctx, cfg); err != nil {
		log.Fatalf("climate-server failed: %v", err)
	}
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func valueOrInt(value, fallback int) int {
	if value == 0 {
		return fallback
	}
	return value
}
