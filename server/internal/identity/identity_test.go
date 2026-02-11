package identity

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
)

func TestHeaderIdentityUsesHeader(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/events", nil)
	req.RemoteAddr = "1.2.3.4:5555"
	req.Header.Set("X-Client-ID", "client-a")

	key, err := Header{HeaderName: "X-Client-ID"}.ClientKey(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "client-a" {
		t.Fatalf("got %q, want %q", key, "client-a")
	}
}

func TestHeaderIdentityFallsBackToRemoteIP(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/events", nil)
	req.RemoteAddr = "1.2.3.4:5555"

	key, err := Header{HeaderName: "X-Client-ID"}.ClientKey(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "1.2.3.4" {
		t.Fatalf("got %q, want %q", key, "1.2.3.4")
	}
}

type mockWhoIsClient struct {
	resp *apitype.WhoIsResponse
	err  error
}

func (m mockWhoIsClient) WhoIs(_ context.Context, _ string) (*apitype.WhoIsResponse, error) {
	return m.resp, m.err
}

func TestTSNetIdentityUsesStableID(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/events", nil)
	req.RemoteAddr = "100.64.0.1:1234"

	id := TSNet{
		Client: mockWhoIsClient{
			resp: &apitype.WhoIsResponse{
				Node: &tailcfg.Node{
					StableID: tailcfg.StableNodeID("stable-123"),
					ID:       tailcfg.NodeID(777),
				},
			},
		},
	}

	key, err := id.ClientKey(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "stable-123" {
		t.Fatalf("got %q, want %q", key, "stable-123")
	}
}

func TestTSNetIdentityFallsBackToNodeID(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/events", nil)
	req.RemoteAddr = "100.64.0.1:1234"

	id := TSNet{
		Client: mockWhoIsClient{
			resp: &apitype.WhoIsResponse{
				Node: &tailcfg.Node{
					ID: tailcfg.NodeID(777),
				},
			},
		},
	}

	key, err := id.ClientKey(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if key != "777" {
		t.Fatalf("got %q, want %q", key, "777")
	}
}
