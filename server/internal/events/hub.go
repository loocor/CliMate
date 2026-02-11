package events

import "sync"

type Event struct {
	ID   uint64 `json:"id"`
	Type string `json:"type,omitempty"`
	Data string `json:"data"`
}

type Hub struct {
	mu       sync.RWMutex
	subs     map[chan Event]struct{}
	closed   bool
	capacity int

	nextID uint64
	buf    []Event
}

func NewHub(capacity int) *Hub {
	if capacity <= 0 {
		capacity = 256
	}
	return &Hub{
		subs:     make(map[chan Event]struct{}),
		capacity: capacity,
		buf:      make([]Event, 0, capacity),
	}
}

func (h *Hub) HighWaterMark() uint64 {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if h.nextID == 0 {
		return 0
	}
	return h.nextID
}

func (h *Hub) SubscribeFrom(lastEventID uint64) (<-chan Event, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()

	ch := make(chan Event, h.capacity+16)
	if h.closed {
		close(ch)
		return ch, func() {}
	}

	// Replay buffered events first (contiguous ordering).
	for _, evt := range h.buf {
		if evt.ID > lastEventID {
			ch <- evt
		}
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

func (h *Hub) Publish(evt Event) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.nextID++
	evt.ID = h.nextID

	if len(h.buf) < h.capacity {
		h.buf = append(h.buf, evt)
	} else if h.capacity > 0 {
		copy(h.buf, h.buf[1:])
		h.buf[h.capacity-1] = evt
	}

	for ch := range h.subs {
		select {
		case ch <- evt:
		default:
		}
	}
	h.mu.Unlock()
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
	h.buf = nil
}
