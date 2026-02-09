package app

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"climate/server/internal/codex"
	"climate/server/internal/httpx"
	"climate/server/internal/tailnet"
	"golang.org/x/sync/errgroup"
)

type Config struct {
	CodexBin   string
	BindIP     string
	Port       int
	TSAuthKey  string
	TSHostname string
	TSStateDir string
}

func Run(ctx context.Context, cfg Config) error {
	cfg = normalizeConfig(cfg)

	manager := codex.NewManager(cfg.CodexBin)
	handler := httpx.NewHandler(manager)

	localAddr := fmt.Sprintf("%s:%d", cfg.BindIP, cfg.Port)
	localBase := fmt.Sprintf("http://%s", localAddr)

	localLn, err := net.Listen("tcp", localAddr)
	if err != nil {
		return fmt.Errorf("failed to bind %s: %w", localBase, err)
	}

	var tail *tailnet.Instance
	if cfg.TSAuthKey != "" {
		tail, err = tailnet.Start(ctx, tailnet.Config{
			AuthKey:  cfg.TSAuthKey,
			Hostname: cfg.TSHostname,
			StateDir: cfg.TSStateDir,
			Port:     cfg.Port,
		})
		if err != nil {
			return err
		}
	}

	log.Printf("CliMate server is up.")
	log.Printf("- local http: %s", localBase)
	if tail != nil {
		if tail.ConnectHint != "" {
			log.Printf("- iOS base URL: %s", tail.ConnectHint)
		} else {
			log.Printf("- iOS base URL: http://100.x.y.z:%d", cfg.Port)
		}
		log.Printf("- publish: embedded tailnet (tsnet)")
	} else {
		log.Printf("- publish: local only (tsnet disabled)")
	}
	log.Printf("Press Ctrl+C to stop.")

	localServer := &http.Server{Handler: handler}
	var tailServer *http.Server

	group, groupCtx := errgroup.WithContext(ctx)
	group.Go(func() error {
		return serveHTTP(localServer, localLn)
	})
	if tail != nil {
		tailServer = &http.Server{Handler: handler}
		group.Go(func() error {
			return serveHTTP(tailServer, tail.Listener)
		})
	}

	go func() {
		<-groupCtx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = localServer.Shutdown(shutdownCtx)
		if tailServer != nil {
			_ = tailServer.Shutdown(shutdownCtx)
		}
		if tail != nil {
			_ = tail.Close()
		}
	}()

	return group.Wait()
}

func serveHTTP(server *http.Server, listener net.Listener) error {
	err := server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func normalizeConfig(cfg Config) Config {
	if strings.TrimSpace(cfg.CodexBin) == "" {
		cfg.CodexBin = "codex"
	}
	if strings.TrimSpace(cfg.BindIP) == "" {
		cfg.BindIP = "127.0.0.1"
	}
	if cfg.Port == 0 {
		cfg.Port = 4500
	}
	cfg.TSAuthKey = strings.TrimSpace(cfg.TSAuthKey)
	if strings.TrimSpace(cfg.TSHostname) == "" {
		cfg.TSHostname = "climate-server"
	}
	if strings.TrimSpace(cfg.TSStateDir) == "" {
		cfg.TSStateDir = defaultStateDir()
	}
	cfg.TSStateDir = expandHomeDir(cfg.TSStateDir)
	return cfg
}

func defaultStateDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".climate", "tsnet")
	}
	return filepath.Join(home, ".climate", "tsnet")
}

func expandHomeDir(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return path
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return path
		}
		if path == "~" {
			return home
		}
		return filepath.Join(home, strings.TrimPrefix(path, "~/"))
	}
	return path
}
