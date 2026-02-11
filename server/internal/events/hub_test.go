package events

import (
	"testing"
	"time"
)

func TestHubReplaySubscribeFrom(t *testing.T) {
	h := NewHub(16)
	h.Publish(Event{Type: "t", Data: "a"})
	h.Publish(Event{Type: "t", Data: "b"})
	h.Publish(Event{Type: "t", Data: "c"})

	ch, cancel := h.SubscribeFrom(1)
	defer cancel()

	want := []string{"b", "c"}
	for i := range want {
		select {
		case evt := <-ch:
			if evt.Data != want[i] {
				t.Fatalf("event %d: got %q, want %q", i, evt.Data, want[i])
			}
		case <-time.After(500 * time.Millisecond):
			t.Fatalf("timed out waiting for replay event %d", i)
		}
	}
}

func TestHubHighWaterMark(t *testing.T) {
	h := NewHub(4)
	if got := h.HighWaterMark(); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
	h.Publish(Event{Type: "t", Data: "x"})
	h.Publish(Event{Type: "t", Data: "y"})
	if got := h.HighWaterMark(); got != 2 {
		t.Fatalf("got %d, want 2", got)
	}
}
