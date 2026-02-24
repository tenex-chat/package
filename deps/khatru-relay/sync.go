package main

import (
	"context"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// RelayStatus tracks the connection status for a single sync relay
type RelayStatus struct {
	URL       string `json:"url"`
	Connected bool   `json:"connected"`
	LastError string `json:"last_error,omitempty"`
}

// SyncStats holds sync statistics exposed via /stats
type SyncStats struct {
	mu           sync.RWMutex
	EventsSynced int64                 `json:"events_synced"`
	LastSyncTime *time.Time            `json:"last_sync_time,omitempty"`
	RelayStatus  map[string]RelayStatus `json:"relay_status"`
}

func (s *SyncStats) snapshot() map[string]interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()

	statuses := make(map[string]interface{})
	for url, rs := range s.RelayStatus {
		statuses[url] = map[string]interface{}{
			"connected":  rs.Connected,
			"last_error": rs.LastError,
		}
	}

	result := map[string]interface{}{
		"events_synced": s.EventsSynced,
		"relay_status":  statuses,
	}
	if s.LastSyncTime != nil {
		result["last_sync_time"] = s.LastSyncTime.Format(time.RFC3339)
	}
	return result
}

// Syncer manages event synchronization from remote relays
type Syncer struct {
	config  SyncConfig
	storage *Storage
	stats   SyncStats
	cancel  context.CancelFunc
	wg      sync.WaitGroup
}

// NewSyncer creates a new Syncer
func NewSyncer(config SyncConfig, storage *Storage) *Syncer {
	return &Syncer{
		config:  config,
		storage: storage,
		stats: SyncStats{
			RelayStatus: make(map[string]RelayStatus),
		},
	}
}

// Start launches a goroutine per sync relay
func (s *Syncer) Start(ctx context.Context) {
	ctx, s.cancel = context.WithCancel(ctx)

	for _, url := range s.config.Relays {
		s.stats.mu.Lock()
		s.stats.RelayStatus[url] = RelayStatus{URL: url}
		s.stats.mu.Unlock()

		s.wg.Add(1)
		go func(relayURL string) {
			defer s.wg.Done()
			s.syncRelay(ctx, relayURL)
		}(url)
	}

	log.Printf("[sync] started sync for %d relay(s), %d kind(s)", len(s.config.Relays), len(s.config.Kinds))
}

// Stop cancels all sync goroutines and waits for them to finish
func (s *Syncer) Stop() {
	if s.cancel != nil {
		s.cancel()
	}
	s.wg.Wait()
	log.Println("[sync] stopped")
}

// Stats returns the current sync stats snapshot
func (s *Syncer) Stats() map[string]interface{} {
	return s.stats.snapshot()
}

// syncRelay is the reconnection loop for a single relay with exponential backoff
func (s *Syncer) syncRelay(ctx context.Context, url string) {
	backoff := 5 * time.Second
	maxBackoff := 5 * time.Minute

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		err := s.runSync(ctx, url)
		if ctx.Err() != nil {
			return
		}

		s.setRelayStatus(url, false, err)

		log.Printf("[sync] %s disconnected (err: %v), reconnecting in %v", url, err, backoff)

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}

		// Exponential backoff capped at maxBackoff
		backoff = backoff * 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// runSync connects to a relay, subscribes to configured kinds, and streams events
func (s *Syncer) runSync(ctx context.Context, url string) error {
	connectCtx, connectCancel := context.WithTimeout(ctx, 10*time.Second)
	defer connectCancel()

	relay, err := nostr.RelayConnect(connectCtx, url)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer relay.Close()

	s.setRelayStatus(url, true, nil)
	log.Printf("[sync] connected to %s", url)

	// Subscribe to configured kinds
	filters := nostr.Filters{{
		Kinds: s.config.Kinds,
	}}

	sub, err := relay.Subscribe(ctx, filters)
	if err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}
	defer sub.Unsub()

	// Track authors for profile sync after EOSE
	var authorsMu sync.Mutex
	authors := make(map[string]struct{})
	var eoseDone atomic.Bool

	for {
		select {
		case evt, ok := <-sub.Events:
			if !ok {
				return fmt.Errorf("subscription closed")
			}

			if err := s.storeEvent(ctx, evt); err != nil {
				log.Printf("[sync] store error for %s: %v", evt.ID[:12], err)
				continue
			}

			atomic.AddInt64(&s.stats.EventsSynced, 1)
			s.stats.mu.Lock()
			now := time.Now()
			s.stats.LastSyncTime = &now
			s.stats.mu.Unlock()

			// Collect author for profile sync (before EOSE only, to avoid unbounded growth)
			if !eoseDone.Load() {
				authorsMu.Lock()
				authors[evt.PubKey] = struct{}{}
				authorsMu.Unlock()
			}

		case <-sub.EndOfStoredEvents:
			eoseDone.Store(true)
			authorsMu.Lock()
			authorList := make([]string, 0, len(authors))
			for a := range authors {
				authorList = append(authorList, a)
			}
			authors = nil // free memory
			authorsMu.Unlock()

			log.Printf("[sync] EOSE from %s, synced %d events so far, %d unique authors",
				url, atomic.LoadInt64(&s.stats.EventsSynced), len(authorList))

			// Sync profiles in background
			if len(authorList) > 0 {
				go s.syncProfiles(ctx, relay, authorList)
			}

		case reason := <-sub.ClosedReason:
			return fmt.Errorf("relay closed subscription: %s", reason)

		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// syncProfiles fetches kind:0 profiles for authors we don't already have
func (s *Syncer) syncProfiles(ctx context.Context, relay *nostr.Relay, authors []string) {
	// Filter out authors we already have profiles for
	missing := make([]string, 0, len(authors))
	for _, author := range authors {
		ch, err := s.storage.QueryEvents(ctx, nostr.Filter{
			Authors: []string{author},
			Kinds:   []int{0},
			Limit:   1,
		})
		if err != nil {
			continue
		}
		found := false
		for range ch {
			found = true
		}
		if !found {
			missing = append(missing, author)
		}
	}

	if len(missing) == 0 {
		log.Printf("[sync] all %d author profiles already cached", len(authors))
		return
	}

	log.Printf("[sync] fetching %d missing profiles (out of %d authors)", len(missing), len(authors))

	// Fetch in batches of 100
	batchSize := 100
	for i := 0; i < len(missing); i += batchSize {
		select {
		case <-ctx.Done():
			return
		default:
		}

		end := i + batchSize
		if end > len(missing) {
			end = len(missing)
		}
		batch := missing[i:end]

		events, err := relay.QuerySync(ctx, nostr.Filter{
			Authors: batch,
			Kinds:   []int{0},
		})
		if err != nil {
			log.Printf("[sync] profile batch query failed: %v", err)
			continue
		}

		stored := 0
		for _, evt := range events {
			if err := s.storeEvent(ctx, evt); err == nil {
				stored++
			}
		}
		log.Printf("[sync] stored %d/%d profiles (batch %d-%d)", stored, len(events), i, end)
	}
}

// storeEvent handles replaceable event semantics before storing
func (s *Syncer) storeEvent(ctx context.Context, event *nostr.Event) error {
	if isReplaceable(event.Kind) {
		return s.storeReplaceableEvent(ctx, event)
	}
	if isParameterizedReplaceable(event.Kind) {
		return s.storeParameterizedReplaceableEvent(ctx, event)
	}
	return s.storage.SaveEvent(ctx, event)
}

// storeReplaceableEvent handles kinds 0, 3, 10000-19999
func (s *Syncer) storeReplaceableEvent(ctx context.Context, event *nostr.Event) error {
	ch, err := s.storage.QueryEvents(ctx, nostr.Filter{
		Authors: []string{event.PubKey},
		Kinds:   []int{event.Kind},
		Limit:   1,
	})
	if err != nil {
		return s.storage.SaveEvent(ctx, event)
	}

	for existing := range ch {
		if existing.CreatedAt >= event.CreatedAt {
			return nil // existing is newer or same, skip
		}
		// Delete older event
		s.storage.DeleteEvent(ctx, existing)
	}

	return s.storage.SaveEvent(ctx, event)
}

// storeParameterizedReplaceableEvent handles kinds 30000-39999
func (s *Syncer) storeParameterizedReplaceableEvent(ctx context.Context, event *nostr.Event) error {
	dTag := getTagValue(event, "d")

	ch, err := s.storage.QueryEvents(ctx, nostr.Filter{
		Authors: []string{event.PubKey},
		Kinds:   []int{event.Kind},
		Tags:    nostr.TagMap{"d": {dTag}},
		Limit:   1,
	})
	if err != nil {
		return s.storage.SaveEvent(ctx, event)
	}

	for existing := range ch {
		if existing.CreatedAt >= event.CreatedAt {
			return nil // existing is newer or same, skip
		}
		s.storage.DeleteEvent(ctx, existing)
	}

	return s.storage.SaveEvent(ctx, event)
}

func (s *Syncer) setRelayStatus(url string, connected bool, err error) {
	s.stats.mu.Lock()
	defer s.stats.mu.Unlock()

	status := RelayStatus{URL: url, Connected: connected}
	if err != nil {
		status.LastError = err.Error()
	}
	s.stats.RelayStatus[url] = status
}

// isReplaceable returns true for kinds 0, 3, and 10000-19999
func isReplaceable(kind int) bool {
	return kind == 0 || kind == 3 || (kind >= 10000 && kind <= 19999)
}

// isParameterizedReplaceable returns true for kinds 30000-39999
func isParameterizedReplaceable(kind int) bool {
	return kind >= 30000 && kind <= 39999
}

// getTagValue returns the first value for a given tag name, or empty string
func getTagValue(event *nostr.Event, tagName string) string {
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == tagName {
			return tag[1]
		}
	}
	return ""
}
