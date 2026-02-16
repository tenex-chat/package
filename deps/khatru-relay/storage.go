package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Storage implements Khatru storage using a simple JSON file
// This is a pure Go implementation with no CGO requirements
type Storage struct {
	path   string
	mu     sync.RWMutex
	events map[string]*nostr.Event // id -> event

	// Indexes for efficient querying
	byKind       map[int][]string              // kind -> event IDs
	byAuthor     map[string][]string           // pubkey -> event IDs
	byAuthorKind map[string][]string           // pubkey:kind -> event IDs
	byTag        map[string]map[string][]string // tagName -> tagValue -> event IDs

	dirty bool // Track if we need to persist
}

// NewStorage creates a new file-backed storage
func NewStorage(path string) (*Storage, error) {
	s := &Storage{
		path:         path,
		events:       make(map[string]*nostr.Event),
		byKind:       make(map[int][]string),
		byAuthor:     make(map[string][]string),
		byAuthorKind: make(map[string][]string),
		byTag:        make(map[string]map[string][]string),
	}

	// Try to load existing data
	if err := s.load(); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to load storage: %w", err)
	}

	// Start periodic persistence
	go s.persistLoop()

	return s, nil
}

// Close closes the storage and persists data
func (s *Storage) Close() error {
	return s.persist()
}

// SaveEvent stores an event
func (s *Storage) SaveEvent(ctx context.Context, event *nostr.Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if event already exists
	if _, exists := s.events[event.ID]; exists {
		return nil
	}

	// Store event
	s.events[event.ID] = event
	s.dirty = true

	// Update indexes
	s.byKind[event.Kind] = append(s.byKind[event.Kind], event.ID)
	s.byAuthor[event.PubKey] = append(s.byAuthor[event.PubKey], event.ID)

	akKey := fmt.Sprintf("%s:%d", event.PubKey, event.Kind)
	s.byAuthorKind[akKey] = append(s.byAuthorKind[akKey], event.ID)

	// Index tags (supports any tag name length, not just single character)
	for _, tag := range event.Tags {
		if len(tag) >= 2 && len(tag[0]) > 0 {
			tagName := tag[0]
			tagValue := tag[1]

			if s.byTag[tagName] == nil {
				s.byTag[tagName] = make(map[string][]string)
			}
			s.byTag[tagName][tagValue] = append(s.byTag[tagName][tagValue], event.ID)
		}
	}

	return nil
}

// QueryEvents queries events matching the filter
func (s *Storage) QueryEvents(ctx context.Context, filter nostr.Filter) (chan *nostr.Event, error) {
	ch := make(chan *nostr.Event)

	go func() {
		defer close(ch)

		// Collect results while holding lock, then release before streaming
		results := s.collectMatchingEvents(ctx, filter, false)

		// Stream results without holding the lock (prevents slow subscribers from blocking writes)
		for _, event := range results {
			select {
			case ch <- event:
			case <-ctx.Done():
				return
			}
		}
	}()

	return ch, nil
}

// collectMatchingEvents collects and returns matching events while holding the read lock.
// If noLimit is true, the default 500 limit is bypassed (used for counting).
func (s *Storage) collectMatchingEvents(ctx context.Context, filter nostr.Filter, noLimit bool) []*nostr.Event {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Collect candidate IDs
	var candidates []string

	switch {
	case len(filter.IDs) > 0:
		// ID lookup with prefix support
		for _, filterID := range filter.IDs {
			if len(filterID) == 64 {
				// Exact ID - direct lookup
				if _, exists := s.events[filterID]; exists {
					candidates = append(candidates, filterID)
				}
			} else {
				// Prefix match - scan all events
				for id := range s.events {
					if strings.HasPrefix(id, filterID) {
						candidates = append(candidates, id)
					}
				}
			}
		}

	case len(filter.Authors) > 0 && len(filter.Kinds) > 0:
		// Use author+kind index with prefix support
		for _, author := range filter.Authors {
			if len(author) == 64 {
				// Exact author - use index
				for _, kind := range filter.Kinds {
					akKey := fmt.Sprintf("%s:%d", author, kind)
					candidates = append(candidates, s.byAuthorKind[akKey]...)
				}
			} else {
				// Prefix match - scan index keys
				for akKey, ids := range s.byAuthorKind {
					for _, kind := range filter.Kinds {
						suffix := fmt.Sprintf(":%d", kind)
						if strings.HasSuffix(akKey, suffix) {
							pubkey := strings.TrimSuffix(akKey, suffix)
							if strings.HasPrefix(pubkey, author) {
								candidates = append(candidates, ids...)
							}
						}
					}
				}
			}
		}

	case len(filter.Authors) > 0:
		// Author lookup with prefix support
		for _, author := range filter.Authors {
			if len(author) == 64 {
				// Exact author - direct lookup
				candidates = append(candidates, s.byAuthor[author]...)
			} else {
				// Prefix match - scan index keys
				for pubkey, ids := range s.byAuthor {
					if strings.HasPrefix(pubkey, author) {
						candidates = append(candidates, ids...)
					}
				}
			}
		}

	case len(filter.Kinds) > 0:
		for _, kind := range filter.Kinds {
			candidates = append(candidates, s.byKind[kind]...)
		}

	case len(filter.Tags) > 0:
		// Use tag index
		for tagName, tagValues := range filter.Tags {
			if tagIndex, ok := s.byTag[tagName]; ok {
				for _, tagValue := range tagValues {
					candidates = append(candidates, tagIndex[tagValue]...)
				}
			}
		}

	default:
		// Return all events
		for id := range s.events {
			candidates = append(candidates, id)
		}
	}

	// Collect matching events
	var matching []*nostr.Event
	seen := make(map[string]bool)

	for _, id := range candidates {
		select {
		case <-ctx.Done():
			return matching
		default:
		}

		if seen[id] {
			continue
		}
		seen[id] = true

		event, ok := s.events[id]
		if !ok {
			continue
		}

		if matchesFilter(event, filter) {
			matching = append(matching, event)
		}
	}

	// Sort by created_at descending (newest first)
	sort.Slice(matching, func(i, j int) bool {
		return matching[i].CreatedAt > matching[j].CreatedAt
	})

	// Apply limit (unless noLimit is set for counting)
	if !noLimit {
		limit := filter.Limit
		if limit == 0 {
			limit = 500
		}

		if len(matching) > limit {
			matching = matching[:limit]
		}
	}

	return matching
}

// DeleteEvent deletes an event by ID
func (s *Storage) DeleteEvent(ctx context.Context, event *nostr.Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	storedEvent, exists := s.events[event.ID]
	if !exists {
		return nil
	}

	// Clean up indexes to prevent unbounded growth
	s.removeFromIndex(s.byKind[storedEvent.Kind], event.ID, func(ids []string) {
		if len(ids) == 0 {
			delete(s.byKind, storedEvent.Kind)
		} else {
			s.byKind[storedEvent.Kind] = ids
		}
	})

	s.removeFromIndex(s.byAuthor[storedEvent.PubKey], event.ID, func(ids []string) {
		if len(ids) == 0 {
			delete(s.byAuthor, storedEvent.PubKey)
		} else {
			s.byAuthor[storedEvent.PubKey] = ids
		}
	})

	akKey := fmt.Sprintf("%s:%d", storedEvent.PubKey, storedEvent.Kind)
	s.removeFromIndex(s.byAuthorKind[akKey], event.ID, func(ids []string) {
		if len(ids) == 0 {
			delete(s.byAuthorKind, akKey)
		} else {
			s.byAuthorKind[akKey] = ids
		}
	})

	// Clean up tag indexes
	for _, tag := range storedEvent.Tags {
		if len(tag) >= 2 && len(tag[0]) > 0 {
			tagName := tag[0]
			tagValue := tag[1]
			if tagIndex, ok := s.byTag[tagName]; ok {
				s.removeFromIndex(tagIndex[tagValue], event.ID, func(ids []string) {
					if len(ids) == 0 {
						delete(tagIndex, tagValue)
						if len(tagIndex) == 0 {
							delete(s.byTag, tagName)
						}
					} else {
						tagIndex[tagValue] = ids
					}
				})
			}
		}
	}

	delete(s.events, event.ID)
	s.dirty = true
	return nil
}

// removeFromIndex removes an ID from an index slice and calls the callback with the result
func (s *Storage) removeFromIndex(ids []string, idToRemove string, update func([]string)) {
	for i, id := range ids {
		if id == idToRemove {
			// Remove by swapping with last element and truncating
			ids[i] = ids[len(ids)-1]
			update(ids[:len(ids)-1])
			return
		}
	}
}

// CountEvents counts events matching the filter (NIP-45)
func (s *Storage) CountEvents(ctx context.Context, filter nostr.Filter) (int64, error) {
	// Pass noLimit=true to count ALL matching events per NIP-45 semantics
	matching := s.collectMatchingEvents(ctx, filter, true)
	return int64(len(matching)), nil
}

// persistLoop periodically persists data to disk
func (s *Storage) persistLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		s.mu.RLock()
		dirty := s.dirty
		s.mu.RUnlock()

		if dirty {
			if err := s.persist(); err != nil {
				// Log error but continue
				fmt.Printf("Failed to persist storage: %v\n", err)
			}
		}
	}
}

// persist writes all events to disk
func (s *Storage) persist() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.dirty && len(s.events) == 0 {
		return nil
	}

	// Create parent directory if needed
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	// Collect all events
	events := make([]*nostr.Event, 0, len(s.events))
	for _, event := range s.events {
		events = append(events, event)
	}

	// Write to temp file then rename (atomic)
	tmpPath := s.path + ".tmp"
	data, err := json.Marshal(events)
	if err != nil {
		return err
	}

	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return err
	}

	if err := os.Rename(tmpPath, s.path); err != nil {
		return err
	}

	s.dirty = false
	return nil
}

// load reads events from disk
func (s *Storage) load() error {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return err
	}

	var events []*nostr.Event
	if err := json.Unmarshal(data, &events); err != nil {
		return err
	}

	// Rebuild storage and indexes
	for _, event := range events {
		s.events[event.ID] = event

		s.byKind[event.Kind] = append(s.byKind[event.Kind], event.ID)
		s.byAuthor[event.PubKey] = append(s.byAuthor[event.PubKey], event.ID)

		akKey := fmt.Sprintf("%s:%d", event.PubKey, event.Kind)
		s.byAuthorKind[akKey] = append(s.byAuthorKind[akKey], event.ID)

		for _, tag := range event.Tags {
			if len(tag) >= 2 && len(tag[0]) > 0 {
				tagName := tag[0]
				tagValue := tag[1]

				if s.byTag[tagName] == nil {
					s.byTag[tagName] = make(map[string][]string)
				}
				s.byTag[tagName][tagValue] = append(s.byTag[tagName][tagValue], event.ID)
			}
		}
	}

	return nil
}

// matchesFilter checks if an event matches a filter
func matchesFilter(event *nostr.Event, filter nostr.Filter) bool {
	// Check IDs
	if len(filter.IDs) > 0 {
		found := false
		for _, id := range filter.IDs {
			if strings.HasPrefix(event.ID, id) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}

	// Check authors
	if len(filter.Authors) > 0 {
		found := false
		for _, author := range filter.Authors {
			if strings.HasPrefix(event.PubKey, author) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}

	// Check kinds
	if len(filter.Kinds) > 0 {
		found := false
		for _, kind := range filter.Kinds {
			if event.Kind == kind {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}

	// Check time bounds
	if filter.Since != nil && event.CreatedAt < *filter.Since {
		return false
	}
	if filter.Until != nil && event.CreatedAt > *filter.Until {
		return false
	}

	// Check tags
	for tagName, tagValues := range filter.Tags {
		if len(tagValues) == 0 {
			continue
		}

		// Find matching tag in event
		found := false
		for _, tag := range event.Tags {
			if len(tag) >= 2 && tag[0] == tagName {
				for _, v := range tagValues {
					if tag[1] == v {
						found = true
						break
					}
				}
			}
			if found {
				break
			}
		}
		if !found {
			return false
		}
	}

	return true
}
