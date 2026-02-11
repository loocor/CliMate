package httpx

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"climate/server/internal/codex"
	"climate/server/internal/events"
	"climate/server/internal/identity"
)

func TestEventsDoesNotEnsureCodex(t *testing.T) {
	manager := codex.NewManager("false")
	handler := NewHandler(manager, identity.Static{Key: "client-1"})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/events", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d, want %d", resp.StatusCode, http.StatusOK)
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	seenSnapshot := false
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "event: session/snapshot") {
			seenSnapshot = true
			break
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if !seenSnapshot {
		t.Fatalf("did not see snapshot event")
	}
	if manager.RunningSessions() != 0 {
		t.Fatalf("expected no codex sessions, got %d", manager.RunningSessions())
	}
}

func TestSSEReplayUsesLastEventIDHeader(t *testing.T) {
	manager := codex.NewManager("false")
	clientKey := "client-2"
	hub := manager.Events(clientKey)
	hub.Publish(events.Event{Type: "test", Data: "one"})
	hub.Publish(events.Event{Type: "test", Data: "two"})

	handler := NewHandler(manager, identity.Static{Key: clientKey})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/events", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Last-Event-ID", "1")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d, want %d", resp.StatusCode, http.StatusOK)
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	seenID := false
	seenData := false
	for scanner.Scan() {
		line := scanner.Text()
		if line == "id: 2" {
			seenID = true
			continue
		}
		if seenID && line == "data: two" {
			seenData = true
			break
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if !seenData {
		t.Fatalf("did not observe replayed event id=2 data=two (seenID=%v)", seenID)
	}
}
