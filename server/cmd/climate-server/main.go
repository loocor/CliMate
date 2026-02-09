package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"climate/server/internal/app"
)

func main() {
	cfg := app.Config{}
	flag.StringVar(&cfg.CodexBin, "codex-bin", "codex", "Path to codex binary")
	flag.StringVar(&cfg.BindIP, "bind-ip", "127.0.0.1", "Local bind IP")
	flag.IntVar(&cfg.Port, "port", 4500, "Port to serve")
	flag.StringVar(&cfg.TSAuthKey, "ts-auth-key", os.Getenv("TS_AUTHKEY"), "Tailscale auth key (tsnet)")
	flag.StringVar(&cfg.TSHostname, "ts-hostname", "climate-server", "Tailscale hostname")
	flag.StringVar(&cfg.TSStateDir, "ts-state-dir", "", "State directory for tsnet (default ~/.climate/tsnet)")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := app.Run(ctx, cfg); err != nil {
		log.Fatalf("climate-server failed: %v", err)
	}
}
