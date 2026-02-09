package events

import "sync"

type Hub struct {
	mu     sync.RWMutex
	subs   map[chan string]struct{}
	closed bool
}

func NewHub() *Hub {
	return &Hub{
		subs: make(map[chan string]struct{}),
	}
}

func (h *Hub) Subscribe() (<-chan string, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()

	ch := make(chan string, 128)
	if h.closed {
		close(ch)
		return ch, func() {}
	}

	h.subs[ch] = struct{}{}
	return ch, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if _, ok := h.subs[ch]; ok {
			delete(h.subs, ch)
			close(ch)
		}
	}
}

func (h *Hub) Publish(line string) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for ch := range h.subs {
		select {
		case ch <- line:
		default:
		}
	}
}

func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	h.closed = true
	for ch := range h.subs {
		close(ch)
	}
	h.subs = nil
}
