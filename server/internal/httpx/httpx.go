package httpx

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"climate/server/internal/codex"
	"climate/server/internal/identity"
)

type Server struct {
	manager  *codex.Manager
	identity identity.Provider
}

func NewHandler(manager *codex.Manager, identity identity.Provider) http.Handler {
	server := &Server{manager: manager, identity: identity}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", server.handleHealthz)
	mux.HandleFunc("/rpc", server.handleRPC)
	mux.HandleFunc("/events", server.handleEvents)
	return withCORS(mux)
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte("ok"))
}

func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	clientKey, err := s.identity.ClientKey(r)
	if err != nil {
		writeJSONError(w, http.StatusUnauthorized, "unauthorized", err.Error())
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 10<<20))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "failed to read body")
		return
	}
	if len(body) == 0 {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "empty body")
		return
	}

	payload, err := decodeJSON(body)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid json")
		return
	}

	if method, ok := payload["method"].(string); ok {
		id := "-"
		if idValue, ok := payload["id"]; ok {
			id = fmt.Sprintf("%v", idValue)
		}
		log.Printf("[rpc] client=%s method=%s id=%s", clientKey, method, id)
	}

	session, err := s.manager.Ensure(clientKey)
	if err != nil {
		writeManagerError(w, err)
		return
	}

	response, err := session.SendRPC(r.Context(), payload)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "rpc_failed", err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(response)
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSONError(w, http.StatusInternalServerError, "streaming_unsupported", "streaming unsupported")
		return
	}

	clientKey, err := s.identity.ClientKey(r)
	if err != nil {
		writeJSONError(w, http.StatusUnauthorized, "unauthorized", err.Error())
		return
	}

	lastEventID := parseLastEventID(r)
	events := s.manager.Events(clientKey)
	ch, cancel := events.SubscribeFrom(lastEventID)
	defer cancel()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	log.Printf("[events] client=%s connected (from=%d)", clientKey, lastEventID)
	defer log.Printf("[events] client=%s disconnected", clientKey)

	snap := s.manager.Snapshot(clientKey)
	writeSSE(w, SSEEvent{
		Type: "session/snapshot",
		Data: snap,
	})
	flusher.Flush()

	keepAlive := time.NewTicker(15 * time.Second)
	defer keepAlive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-keepAlive.C:
			_, _ = w.Write([]byte(": ping\n\n"))
			flusher.Flush()
		case evt, ok := <-ch:
			if !ok {
				return
			}
			writeSSE(w, SSEEvent{
				ID:   evt.ID,
				Type: evt.Type,
				Data: evt.Data,
			})
			flusher.Flush()
		}
	}
}

func decodeJSON(body []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var payload map[string]any
	if err := decoder.Decode(&payload); err != nil {
		return nil, err
	}
	return payload, nil
}

type jsonErrorResponse struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func writeJSONError(w http.ResponseWriter, status int, code string, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	var resp jsonErrorResponse
	resp.Error.Code = code
	resp.Error.Message = message
	_ = json.NewEncoder(w).Encode(resp)
}

func writeManagerError(w http.ResponseWriter, err error) {
	if err == nil {
		writeJSONError(w, http.StatusInternalServerError, "internal_error", "unknown error")
		return
	}
	if errors.Is(err, codex.ErrMaxSessions) {
		writeJSONError(w, http.StatusTooManyRequests, "max_sessions", err.Error())
		return
	}
	writeJSONError(w, http.StatusInternalServerError, "internal_error", err.Error())
}

type SSEEvent struct {
	ID   uint64
	Type string
	Data any
}

func writeSSE(w io.Writer, evt SSEEvent) {
	if evt.ID != 0 {
		_, _ = fmt.Fprintf(w, "id: %d\n", evt.ID)
	}
	if strings.TrimSpace(evt.Type) != "" {
		_, _ = fmt.Fprintf(w, "event: %s\n", evt.Type)
	}
	data := evt.Data
	if data == nil {
		_, _ = w.Write([]byte("data: null\n\n"))
		return
	}
	switch v := data.(type) {
	case string:
		writeSSEDataLines(w, v)
	case []byte:
		writeSSEDataLines(w, string(v))
	default:
		b, err := json.Marshal(v)
		if err != nil {
			writeSSEDataLines(w, fmt.Sprintf(`{"error":"%s"}`, escapeJSONString(err.Error())))
		} else {
			writeSSEDataLines(w, string(b))
		}
	}
	_, _ = w.Write([]byte("\n"))
}

func writeSSEDataLines(w io.Writer, s string) {
	// SSE requires each line be prefixed by "data:".
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for _, line := range lines {
		_, _ = fmt.Fprintf(w, "data: %s\n", line)
	}
}

func escapeJSONString(s string) string {
	b, _ := json.Marshal(s)
	quoted := string(b)
	return strings.Trim(quoted, `"`)
}

func parseLastEventID(r *http.Request) uint64 {
	value := strings.TrimSpace(r.Header.Get("Last-Event-ID"))
	if value == "" {
		return 0
	}
	n, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
