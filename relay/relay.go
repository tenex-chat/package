package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"github.com/fiatjaf/eventstore"
	evbadger "github.com/fiatjaf/eventstore/badger"
	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

// silentBadger suppresses BadgerDB's internal logging.
func silentBadger(opts badger.Options) badger.Options {
	return opts.WithLogger(nil)
}

// Relay wraps a Khatru relay with TENEX-specific configuration
type Relay struct {
	config *Config
	khatru *khatru.Relay
	server *http.Server
	db     eventstore.Store
	syncer *Syncer
	acl    *ACL

	mu        sync.RWMutex
	startTime time.Time
}

// NewRelay creates a new relay with the given configuration
func NewRelay(config *Config) (*Relay, error) {
	if err := config.EnsureDataDir(); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	dbImpl := &evbadger.BadgerBackend{
		Path:                  filepath.Join(config.DataDir, "badger"),
		BadgerOptionsModifier: silentBadger,
	}
	if err := dbImpl.Init(); err != nil {
		return nil, fmt.Errorf("failed to initialize storage: %w", err)
	}
	var db eventstore.Store = dbImpl

	relay := khatru.NewRelay()
	relay.MaxMessageSize = int64(config.Limits.MaxMessageLength)

	relay.Info.Name = config.NIP11.Name
	relay.Info.Description = config.NIP11.Description
	relay.Info.PubKey = config.NIP11.Pubkey
	relay.Info.Contact = config.NIP11.Contact
	supportedNIPs := make([]any, len(config.NIP11.SupportedNIPs))
	for i, nip := range config.NIP11.SupportedNIPs {
		supportedNIPs[i] = nip
	}
	relay.Info.SupportedNIPs = supportedNIPs
	relay.Info.Software = config.NIP11.Software
	relay.Info.Version = config.NIP11.Version

	relay.StoreEvent = append(relay.StoreEvent, db.SaveEvent)
	relay.QueryEvents = append(relay.QueryEvents, db.QueryEvents)
	relay.DeleteEvent = append(relay.DeleteEvent, db.DeleteEvent)
	relay.CountEvents = append(relay.CountEvents, dbImpl.CountEvents)

	// NIP-9: handle deletion events (kind 5)
	relay.OnEventSaved = append(relay.OnEventSaved, func(ctx context.Context, event *nostr.Event) {
		if event.Kind != 5 {
			return
		}
		for _, tag := range event.Tags {
			if len(tag) >= 2 && tag[0] == "e" {
				targetID := tag[1]
				ch, err := db.QueryEvents(ctx, nostr.Filter{IDs: []string{targetID}, Limit: 1})
				if err != nil {
					log.Printf("NIP-9: failed to query event %s: %v", targetID, err)
					continue
				}
				for targetEvent := range ch {
					if targetEvent.PubKey == event.PubKey {
						if err := db.DeleteEvent(ctx, targetEvent); err != nil {
							log.Printf("NIP-9: failed to delete event %s: %v", targetID, err)
						} else {
							log.Printf("NIP-9: deleted event %s (requested by %s...)", truncateForLog(targetID, 12), truncateForLog(event.PubKey, 12))
						}
					} else {
						log.Printf("NIP-9: ignoring deletion request for %s (pubkey mismatch)", truncateForLog(targetID, 12))
					}
				}
			}
		}
	})

	preventLargeTags := policies.PreventLargeTags(config.Limits.MaxEventTags)
	relay.RejectEvent = append(relay.RejectEvent,
		func(ctx context.Context, event *nostr.Event) (reject bool, msg string) {
			reject, msg = preventLargeTags(ctx, event)
			if reject {
				logRejectedEventWrite(ctx, event, msg)
			}
			return reject, msg
		},
		func(ctx context.Context, event *nostr.Event) (reject bool, msg string) {
			if len(event.Content) > config.Limits.MaxContentLength {
				msg := fmt.Sprintf("content too large: %d > %d bytes", len(event.Content), config.Limits.MaxContentLength)
				logRejectedEventWrite(ctx, event, msg)
				return true, msg
			}
			return false, ""
		},
	)

	relay.RejectConnection = append(relay.RejectConnection,
		func(r *http.Request) bool { return false },
	)

	relay.RejectFilter = append(relay.RejectFilter,
		func(ctx context.Context, filter nostr.Filter) (reject bool, msg string) {
			if khatru.GetAuthed(ctx) != "" {
				return false, ""
			}
			// Allow unauthenticated subscriptions for ephemeral-only filters
			if len(filter.Kinds) > 0 {
				allEphemeral := true
				for _, k := range filter.Kinds {
					if !isEphemeral(k) {
						allEphemeral = false
						break
					}
				}
				if allEphemeral {
					return false, ""
				}
			}
			khatru.RequestAuth(ctx)
			return true, "auth-required: authenticate to subscribe"
		},
	)

	acl := NewACL(config.AdminPubkeys, db)
	relay.OverwriteFilter = append(relay.OverwriteFilter, acl.OverwriteFilterHook)
	relay.PreventBroadcast = append(relay.PreventBroadcast, acl.PreventBroadcastHook)
	relay.OnEventSaved = append(relay.OnEventSaved, acl.OnEventSavedHook)

	return &Relay{
		config: config,
		khatru: relay,
		db:     db,
		acl:    acl,
	}, nil
}

// Start starts the relay server
func (r *Relay) Start(ctx context.Context) error {
	r.mu.Lock()
	r.startTime = time.Now()
	r.mu.Unlock()
	r.acl.StartWhitelistFileSync(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", r.handleHealth)
	mux.HandleFunc("/stats", r.handleStats)
	mux.Handle("/", r.khatru)

	addr := fmt.Sprintf("%s:%d", r.config.BindAddress, r.config.Port)
	r.server = &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("Starting TENEX relay on %s", addr)
	log.Printf("NIP-11 Info: %s - %s", r.config.NIP11.Name, r.config.NIP11.Description)

	errCh := make(chan error, 1)
	go func() {
		if err := r.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	if len(r.config.Sync.Relays) > 0 {
		r.syncer = NewSyncer(r.config.Sync, r.db)
		r.syncer.OnEventStored = func(event *nostr.Event) {
			if event.Kind == 14199 {
				r.acl.ProcessWhitelistEvent(event)
			}
		}
		r.syncer.Start(ctx)
	}

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		return r.Shutdown()
	}
}

// Shutdown gracefully shuts down the relay
func (r *Relay) Shutdown() error {
	log.Println("Shutting down relay...")

	if r.syncer != nil {
		r.syncer.Stop()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if r.server != nil {
		if err := r.server.Shutdown(ctx); err != nil {
			log.Printf("Server shutdown error: %v", err)
		}
	}

	if r.db != nil {
		r.db.Close()
	}

	log.Println("Relay shutdown complete")
	return nil
}

func (r *Relay) handleHealth(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "healthy",
		"relay":  r.config.NIP11.Name,
	})
}

func (r *Relay) handleStats(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	uptime := time.Since(r.startTime)
	r.mu.RUnlock()

	var count int64
	if counter, ok := r.db.(eventstore.Counter); ok {
		count, _ = counter.CountEvents(req.Context(), nostr.Filter{})
	}

	stats := map[string]interface{}{
		"uptime_seconds": int(uptime.Seconds()),
		"event_count":    count,
		"relay_info":     r.config.NIP11,
	}

	if r.syncer != nil {
		stats["sync"] = r.syncer.Stats()
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

func logRejectedEventWrite(ctx context.Context, event *nostr.Event, reason string) {
	eventID := truncateForLog(event.ID, 12)
	pubkey := truncateForLog(event.PubKey, 12)
	ip := khatru.GetIP(ctx)
	if ip == "" {
		ip = "unknown"
	}
	if reason == "" {
		reason = "blocked: no reason provided"
	}
	log.Printf("[relay] rejected EVENT id=%s kind=%d pubkey=%s ip=%s reason=%s", eventID, event.Kind, pubkey, ip, reason)
}

func truncateForLog(value string, max int) string {
	if value == "" {
		return "unknown"
	}
	if len(value) <= max {
		return value
	}
	return value[:max] + "..."
}

// WriteConfigTemplate writes a config template to the given path
func WriteConfigTemplate(path string) error {
	config := DefaultConfig()
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}
