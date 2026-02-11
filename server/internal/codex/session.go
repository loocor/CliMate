package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"climate/server/internal/events"
)

var (
	ErrMaxSessions     = errors.New("max sessions reached")
	ErrCodexNotRunning = errors.New("codex app-server process is not running")
)

const (
	defaultMaxSessions = 16
	defaultIdleTTL     = 10 * time.Minute
)

type Manager struct {
	mu          sync.Mutex
	codexBin    string
	sessions    map[string]*clientEntry
	maxSessions int
	idleTTL     time.Duration

	janitorOnce sync.Once

	running atomic.Int64
}

func NewManager(codexBin string) *Manager {
	if strings.TrimSpace(codexBin) == "" {
		codexBin = "codex"
	}
	m := &Manager{
		codexBin:    codexBin,
		sessions:    make(map[string]*clientEntry),
		maxSessions: defaultMaxSessions,
		idleTTL:     defaultIdleTTL,
	}
	m.startJanitor()
	return m
}

func (m *Manager) Ensure(clientKey string) (*Session, error) {
	clientKey = strings.TrimSpace(clientKey)
	if clientKey == "" {
		return nil, fmt.Errorf("missing client key")
	}

	entry := m.getOrCreate(clientKey)
	return entry.ensure(m)
}

func (m *Manager) Events(clientKey string) *events.Hub {
	clientKey = strings.TrimSpace(clientKey)
	if clientKey == "" {
		// Avoid panics in handler code; caller is expected to validate identity.
		return events.NewHub(256)
	}
	return m.getOrCreate(clientKey).hub
}

type SessionSnapshot struct {
	ClientKey    string    `json:"clientKey"`
	CodexRunning bool      `json:"codexRunning"`
	LastActivity time.Time `json:"lastActivity,omitempty"`
	LastEventID  uint64    `json:"lastEventId"`
	HasEverRun   bool      `json:"hasEverRun"`
}

func (m *Manager) Snapshot(clientKey string) SessionSnapshot {
	clientKey = strings.TrimSpace(clientKey)
	if clientKey == "" {
		return SessionSnapshot{}
	}

	m.mu.Lock()
	entry := m.sessions[clientKey]
	m.mu.Unlock()

	if entry == nil {
		return SessionSnapshot{ClientKey: clientKey, CodexRunning: false}
	}

	entry.mu.Lock()
	defer entry.mu.Unlock()

	snap := SessionSnapshot{
		ClientKey:    clientKey,
		HasEverRun:   entry.hasEverRun,
		LastEventID:  entry.hub.HighWaterMark(),
		CodexRunning: entry.session != nil && !entry.session.Dead(),
	}
	if entry.session != nil {
		snap.LastActivity = entry.session.LastActivity()
	}
	return snap
}

func (m *Manager) RunningSessions() int {
	return int(m.running.Load())
}

func (m *Manager) getOrCreate(clientKey string) *clientEntry {
	m.mu.Lock()
	defer m.mu.Unlock()

	entry := m.sessions[clientKey]
	if entry != nil {
		return entry
	}
	entry = &clientEntry{
		key: clientKey,
		hub: events.NewHub(1024),
	}
	m.sessions[clientKey] = entry
	return entry
}

func (m *Manager) startJanitor() {
	m.janitorOnce.Do(func() {
		go func() {
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for range ticker.C {
				m.sweepIdle()
			}
		}()
	})
}

func (m *Manager) sweepIdle() {
	ttl := m.idleTTL
	if ttl <= 0 {
		return
	}
	now := time.Now()

	m.mu.Lock()
	entries := make([]*clientEntry, 0, len(m.sessions))
	for _, entry := range m.sessions {
		entries = append(entries, entry)
	}
	m.mu.Unlock()

	for _, entry := range entries {
		entry.mu.Lock()
		s := entry.session
		entry.mu.Unlock()
		if s == nil || s.Dead() {
			continue
		}
		last := s.LastActivity()
		if last.IsZero() {
			continue
		}
		if now.Sub(last) < ttl {
			continue
		}

		entry.mu.Lock()
		if entry.session != nil && !entry.session.Dead() {
			_ = entry.session.Kill()
			entry.session = nil
		}
		entry.mu.Unlock()
	}
}

type clientEntry struct {
	key string
	hub *events.Hub

	mu         sync.Mutex
	session    *Session
	hasEverRun bool
}

func (e *clientEntry) ensure(m *Manager) (*Session, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.session != nil && !e.session.Dead() {
		return e.session, nil
	}

	if err := m.acquireSlot(); err != nil {
		return nil, err
	}

	session, err := spawnSession(m.codexBin, e.hub, func() {
		m.running.Add(-1)
	})
	if err != nil {
		m.running.Add(-1)
		return nil, err
	}
	e.session = session
	e.hasEverRun = true
	return session, nil
}

func (m *Manager) acquireSlot() error {
	for {
		cur := m.running.Load()
		if int(cur) >= m.maxSessions {
			return ErrMaxSessions
		}
		if m.running.CompareAndSwap(cur, cur+1) {
			return nil
		}
	}
}

type Session struct {
	stdinMu sync.Mutex
	stdin   io.WriteCloser

	pending   map[string]chan []byte
	pendingMu sync.Mutex

	cmd  *exec.Cmd
	dead atomic.Bool

	deadCh    chan struct{}
	deadOnce  sync.Once
	lastNanos atomic.Int64

	events *events.Hub

	onDead func()

	initMu          sync.Mutex
	initialized     bool
	initializeReply json.RawMessage
}

func (s *Session) Dead() bool {
	return s.dead.Load()
}

func (s *Session) LastActivity() time.Time {
	nanos := s.lastNanos.Load()
	if nanos == 0 {
		return time.Time{}
	}
	return time.Unix(0, nanos)
}

func (s *Session) touch() {
	s.lastNanos.Store(time.Now().UnixNano())
}

func (s *Session) markDead() {
	s.deadOnce.Do(func() {
		s.dead.Store(true)
		close(s.deadCh)
		s.pendingMu.Lock()
		for id, ch := range s.pending {
			delete(s.pending, id)
			close(ch)
		}
		s.pendingMu.Unlock()
		if s.onDead != nil {
			s.onDead()
		}
	})
}

func (s *Session) Kill() error {
	if s.cmd == nil || s.cmd.Process == nil {
		s.markDead()
		return nil
	}
	err := s.cmd.Process.Kill()
	s.markDead()
	return err
}

func (s *Session) SendRPC(ctx context.Context, payload map[string]any) ([]byte, error) {
	if s.Dead() {
		return nil, ErrCodexNotRunning
	}
	if ctx == nil {
		ctx = context.Background()
	}

	if method, _ := payload["method"].(string); method == "initialize" {
		if id, ok := payload["id"]; ok {
			s.initMu.Lock()
			if s.initialized && len(s.initializeReply) > 0 {
				cached := append([]byte(nil), s.initializeReply...)
				s.initMu.Unlock()
				resp := struct {
					JSONRPC string          `json:"jsonrpc"`
					ID      any             `json:"id"`
					Result  json.RawMessage `json:"result"`
				}{
					JSONRPC: "2.0",
					ID:      id,
					Result:  cached,
				}
				out, err := json.Marshal(resp)
				if err != nil {
					return nil, err
				}
				return out, nil
			}
			s.initMu.Unlock()
		}
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
	s.touch()

	if !isRequest {
		return []byte(`{"ok":true}`), nil
	}

	timeoutCtx, cancel := withTimeout(ctx, 30*time.Second)
	defer cancel()

	select {
	case resp, ok := <-respCh:
		if !ok {
			return nil, ErrCodexNotRunning
		}
		if method, _ := payload["method"].(string); method == "initialize" {
			var decoded struct {
				Result json.RawMessage `json:"result"`
				Error  json.RawMessage `json:"error"`
			}
			if err := json.Unmarshal(resp, &decoded); err == nil && len(decoded.Error) == 0 && len(decoded.Result) > 0 {
				s.initMu.Lock()
				s.initialized = true
				s.initializeReply = append([]byte(nil), decoded.Result...)
				s.initMu.Unlock()
			}
		}
		return resp, nil
	case <-s.deadCh:
		s.pendingMu.Lock()
		delete(s.pending, idKey)
		s.pendingMu.Unlock()
		return nil, ErrCodexNotRunning
	case <-timeoutCtx.Done():
		s.pendingMu.Lock()
		delete(s.pending, idKey)
		s.pendingMu.Unlock()
		return nil, fmt.Errorf("rpc timed out: %w", timeoutCtx.Err())
	}
}

func spawnSession(codexBin string, hub *events.Hub, onDead func()) (*Session, error) {
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

	if hub == nil {
		hub = events.NewHub(1024)
	}

	session := &Session{
		stdin:   stdin,
		pending: make(map[string]chan []byte),
		cmd:     cmd,
		deadCh:  make(chan struct{}),
		events:  hub,
		onDead:  onDead,
	}
	session.touch()

	go session.readStdoutLoop(stdout)
	go func() {
		if err := cmd.Wait(); err != nil {
			log.Printf("[codex] app-server exited: %v", err)
		}
		session.markDead()
	}()

	return session, nil
}

func (s *Session) readStdoutLoop(stdout io.ReadCloser) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		s.events.Publish(events.Event{Type: "codex/stdout", Data: string(line)})
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
