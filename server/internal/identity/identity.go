package identity

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"

	"tailscale.com/client/tailscale/apitype"
)

// Provider extracts a stable per-client key from an HTTP request.
//
// When the server is published via tsnet, implementations should derive the key
// from tailscale identity (WhoIs), not a client-supplied header.
type Provider interface {
	ClientKey(r *http.Request) (string, error)
}

type Static struct {
	Key string
}

func (s Static) ClientKey(_ *http.Request) (string, error) {
	if strings.TrimSpace(s.Key) == "" {
		return "", fmt.Errorf("missing client identity")
	}
	return s.Key, nil
}

type Header struct {
	HeaderName string
}

func (h Header) ClientKey(r *http.Request) (string, error) {
	name := strings.TrimSpace(h.HeaderName)
	if name == "" {
		name = "X-Client-ID"
	}
	if v := strings.TrimSpace(r.Header.Get(name)); v != "" {
		return v, nil
	}

	// Best-effort fallback: stable per-source IP (drops port).
	host := strings.TrimSpace(r.RemoteAddr)
	if parsedHost, _, err := net.SplitHostPort(host); err == nil && parsedHost != "" {
		host = parsedHost
	}
	host = strings.TrimSpace(host)
	if host == "" {
		return "", fmt.Errorf("missing client identity")
	}
	return host, nil
}

type WhoIsClient interface {
	WhoIs(ctx context.Context, remoteAddr string) (*apitype.WhoIsResponse, error)
}

type TSNet struct {
	Client WhoIsClient
}

func (t TSNet) ClientKey(r *http.Request) (string, error) {
	if t.Client == nil {
		return "", fmt.Errorf("tailscale local client unavailable")
	}

	whois, err := t.Client.WhoIs(r.Context(), r.RemoteAddr)
	if err != nil {
		return "", fmt.Errorf("tailscale whois failed: %w", err)
	}
	if whois == nil || whois.Node == nil {
		return "", fmt.Errorf("tailscale whois returned no node identity")
	}

	if stable := strings.TrimSpace(string(whois.Node.StableID)); stable != "" {
		return stable, nil
	}
	return strconv.FormatUint(uint64(whois.Node.ID), 10), nil
}
