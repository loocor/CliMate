package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"climate/server/internal/events"
)

type Manager struct {
	mu       sync.Mutex
	codexBin string
	session  *Session
}

func NewManager(codexBin string) *Manager {
	return &Manager{codexBin: codexBin}
}

func (m *Manager) Ensure() (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.session != nil && !m.session.Dead() {
		return m.session, nil
	}

	session, err := spawnSession(m.codexBin)
	if err != nil {
		return nil, err
	}
	m.session = session
	return session, nil
}

type Session struct {
	stdinMu   sync.Mutex
	stdin     io.WriteCloser
	pending   map[string]chan []byte
	pendingMu sync.Mutex
	events    *events.Hub
	cmd       *exec.Cmd
	dead      atomic.Bool
}

func (s *Session) Dead() bool {
	return s.dead.Load()
}

func (s *Session) Events() *events.Hub {
	return s.events
}

func (s *Session) SendRPC(ctx context.Context, payload map[string]any) ([]byte, error) {
	if s.Dead() {
		return nil, fmt.Errorf("codex app-server process is not running")
	}
	if ctx == nil {
		ctx = context.Background()
	}

	idKey, hasID := jsonIDKey(payload["id"])
	_, hasMethod := payload["method"]
	isRequest := hasMethod && hasID

	var respCh chan []byte
	if isRequest {
		respCh = make(chan []byte, 1)
		s.pendingMu.Lock()
		s.pending[idKey] = respCh
		s.pendingMu.Unlock()
	}

	line, err := json.Marshal(payload)
	if err != nil {
		if isRequest {
			s.pendingMu.Lock()
			delete(s.pending, idKey)
			s.pendingMu.Unlock()
		}
		return nil, fmt.Errorf("failed to serialize rpc payload: %w", err)
	}

	s.stdinMu.Lock()
	_, err = s.stdin.Write(append(line, '\n'))
	s.stdinMu.Unlock()
	if err != nil {
		if isRequest {
			s.pendingMu.Lock()
			delete(s.pending, idKey)
			s.pendingMu.Unlock()
		}
		return nil, fmt.Errorf("failed to write to codex app-server stdin: %w", err)
	}

	if !isRequest {
		return []byte(`{"ok":true}`), nil
	}

	timeoutCtx, cancel := withTimeout(ctx, 30*time.Second)
	defer cancel()

	select {
	case resp := <-respCh:
		return resp, nil
	case <-timeoutCtx.Done():
		s.pendingMu.Lock()
		delete(s.pending, idKey)
		s.pendingMu.Unlock()
		return nil, fmt.Errorf("rpc timed out: %w", timeoutCtx.Err())
	}
}

func spawnSession(codexBin string) (*Session, error) {
	cmd := exec.Command(codexBin, "app-server")
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = os.Stderr

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("codex app-server stdin unavailable: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("codex app-server stdout unavailable: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start `%s app-server`: %w", codexBin, err)
	}

	session := &Session{
		stdin:   stdin,
		pending: make(map[string]chan []byte),
		events:  events.NewHub(),
		cmd:     cmd,
	}

	go session.readStdoutLoop(stdout)
	go func() {
		if err := cmd.Wait(); err != nil {
			log.Printf("[codex] app-server exited: %v", err)
		}
		session.dead.Store(true)
		session.events.Close()
	}()

	return session, nil
}

func (s *Session) readStdoutLoop(stdout io.ReadCloser) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		s.events.Publish(string(line))
		idKey, ok := extractIDKey(line)
		if !ok {
			continue
		}
		s.pendingMu.Lock()
		respCh := s.pending[idKey]
		delete(s.pending, idKey)
		s.pendingMu.Unlock()
		if respCh != nil {
			respCh <- append([]byte(nil), line...)
			close(respCh)
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("[codex] stdout read error: %v", err)
	}
}

func extractIDKey(line []byte) (string, bool) {
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.UseNumber()
	var payload map[string]any
	if err := decoder.Decode(&payload); err != nil {
		return "", false
	}
	return jsonIDKey(payload["id"])
}

func jsonIDKey(value any) (string, bool) {
	switch id := value.(type) {
	case string:
		return id, true
	case json.Number:
		return id.String(), true
	case float64:
		return strconv.FormatFloat(id, 'f', -1, 64), true
	default:
		return "", false
	}
}

func withTimeout(ctx context.Context, duration time.Duration) (context.Context, context.CancelFunc) {
	if _, ok := ctx.Deadline(); ok {
		return context.WithCancel(ctx)
	}
	return context.WithTimeout(ctx, duration)
}
