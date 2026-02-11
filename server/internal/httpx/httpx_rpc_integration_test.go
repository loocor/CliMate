package httpx

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"climate/server/internal/codex"
	"climate/server/internal/identity"
)

func buildFakeCodex(t *testing.T) string {
	t.Helper()

	dir := t.TempDir()
	srcPath := filepath.Join(dir, "main.go")
	binPath := filepath.Join(dir, "codex")

	const src = `package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

type Msg struct {
	Method string          ` + "`json:\"method\"`" + `
	ID     json.RawMessage ` + "`json:\"id\"`" + `
	Params json.RawMessage ` + "`json:\"params\"`" + `
}

func main() {
	if len(os.Args) < 2 || os.Args[1] != "app-server" {
		os.Exit(2)
	}
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		var msg Msg
		if err := json.Unmarshal(line, &msg); err != nil {
			continue
		}
		if msg.Method == "crash" {
			os.Exit(1)
		}
		if len(msg.ID) == 0 {
			continue
		}
		fmt.Printf("{\"id\":%s,\"result\":{\"ok\":true,\"pid\":%d}}\n", string(msg.ID), os.Getpid())
	}
}
`

	if err := os.WriteFile(srcPath, []byte(src), 0o600); err != nil {
		t.Fatalf("write fake codex source: %v", err)
	}

	cmd := exec.Command("go", "build", "-o", binPath, srcPath)
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("build fake codex: %v\n%s", err, out)
	}
	return binPath
}

func postRPC(t *testing.T, baseURL string, clientID string, payload any) (int, []byte) {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/rpc", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Client-ID", clientID)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

func TestTwoClientsSpawnTwoCodex(t *testing.T) {
	fakeCodex := buildFakeCodex(t)
	manager := codex.NewManager(fakeCodex)
	handler := NewHandler(manager, identity.Header{HeaderName: "X-Client-ID"})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	type rpcResp struct {
		Result struct {
			Pid int `json:"pid"`
		} `json:"result"`
	}

	call := func(clientID string) int {
		status, body := postRPC(t, srv.URL, clientID, map[string]any{
			"method": "ping",
			"id":     1,
			"params": map[string]any{},
		})
		if status != http.StatusOK {
			t.Fatalf("rpc status: got %d, want 200; body=%s", status, body)
		}
		var resp rpcResp
		if err := json.Unmarshal(body, &resp); err != nil {
			t.Fatalf("unmarshal rpc: %v; body=%s", err, body)
		}
		if resp.Result.Pid == 0 {
			t.Fatalf("missing pid in response: %s", body)
		}
		return resp.Result.Pid
	}

	pidA := call("client-a")
	pidB := call("client-b")
	if pidA == pidB {
		t.Fatalf("expected different pids for different clients; got %d and %d", pidA, pidB)
	}
}

func TestSameClientReusesCodexUntilDeath(t *testing.T) {
	fakeCodex := buildFakeCodex(t)
	manager := codex.NewManager(fakeCodex)
	handler := NewHandler(manager, identity.Header{HeaderName: "X-Client-ID"})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	type rpcResp struct {
		Result struct {
			Pid int `json:"pid"`
		} `json:"result"`
	}

	call := func(method string, id int) (int, int) {
		status, body := postRPC(t, srv.URL, "client-a", map[string]any{
			"method": method,
			"id":     id,
		})
		if status != http.StatusOK {
			return status, 0
		}
		var resp rpcResp
		if err := json.Unmarshal(body, &resp); err != nil {
			t.Fatalf("unmarshal rpc: %v; body=%s", err, body)
		}
		return status, resp.Result.Pid
	}

	status1, pid1 := call("ping", 1)
	if status1 != http.StatusOK || pid1 == 0 {
		t.Fatalf("first ping failed: status=%d pid=%d", status1, pid1)
	}
	status2, pid2 := call("ping", 2)
	if status2 != http.StatusOK || pid2 == 0 {
		t.Fatalf("second ping failed: status=%d pid=%d", status2, pid2)
	}
	if pid1 != pid2 {
		t.Fatalf("expected same pid for same client; got %d then %d", pid1, pid2)
	}
}

func TestCrashRecoveryRestartsCodex(t *testing.T) {
	fakeCodex := buildFakeCodex(t)
	manager := codex.NewManager(fakeCodex)
	handler := NewHandler(manager, identity.Header{HeaderName: "X-Client-ID"})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	type rpcResp struct {
		Result struct {
			Pid int `json:"pid"`
		} `json:"result"`
	}

	// Start session.
	status, body := postRPC(t, srv.URL, "client-a", map[string]any{"method": "ping", "id": 1})
	if status != http.StatusOK {
		t.Fatalf("ping status: got %d, want 200; body=%s", status, body)
	}
	var r1 rpcResp
	if err := json.Unmarshal(body, &r1); err != nil {
		t.Fatalf("unmarshal ping: %v; body=%s", err, body)
	}
	if r1.Result.Pid == 0 {
		t.Fatalf("missing pid: %s", body)
	}

	// Crash session (no response expected).
	status, body = postRPC(t, srv.URL, "client-a", map[string]any{"method": "crash", "id": 2})
	if status == http.StatusOK {
		t.Fatalf("expected crash to fail; body=%s", body)
	}

	// Next request should restart with a new process.
	status, body = postRPC(t, srv.URL, "client-a", map[string]any{"method": "ping", "id": 3})
	if status != http.StatusOK {
		t.Fatalf("ping after crash status: got %d, want 200; body=%s", status, body)
	}
	var r2 rpcResp
	if err := json.Unmarshal(body, &r2); err != nil {
		t.Fatalf("unmarshal ping2: %v; body=%s", err, body)
	}
	if r2.Result.Pid == 0 {
		t.Fatalf("missing pid after restart: %s", body)
	}
	if r2.Result.Pid == r1.Result.Pid {
		t.Fatalf("expected restart pid to differ; got %d then %d", r1.Result.Pid, r2.Result.Pid)
	}
}
