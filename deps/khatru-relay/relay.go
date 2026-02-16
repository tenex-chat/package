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

	"github.com/fiatjaf/khatru"
	"github.com/fiatjaf/khatru/policies"
	"github.com/nbd-wtf/go-nostr"
)

// Relay wraps a Khatru relay with TENEX-specific configuration
type Relay struct {
	config       *Config
	khatru       *khatru.Relay
	server       *http.Server
	storage      *Storage
	pushService  *PushNotifyService  // NIP-97 push notifications
	eventWatcher *EventWatcherService // NIP-97 event watcher

	mu        sync.RWMutex
	startTime time.Time
	eventCount int64
}

// NewRelay creates a new relay with the given configuration
func NewRelay(config *Config) (*Relay, error) {
	// Ensure data directory exists
	if err := config.EnsureDataDir(); err != nil {
		return nil, fmt.Errorf("failed to create data directory: %w", err)
	}

	// Initialize storage
	dbPath := filepath.Join(config.DataDir, "events.json")
	storage, err := NewStorage(dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize storage: %w", err)
	}

	// Initialize NIP-97 push notification service
	pushService := NewPushNotifyService(config.PushNotify)

	// Create Khatru relay
	relay := khatru.NewRelay()

	// Configure NIP-11 relay information
	relay.Info.Name = config.NIP11.Name
	relay.Info.Description = config.NIP11.Description
	relay.Info.PubKey = config.NIP11.Pubkey
	relay.Info.Contact = config.NIP11.Contact
	// Convert []int to []any for SupportedNIPs
	supportedNIPs := make([]any, len(config.NIP11.SupportedNIPs))
	for i, nip := range config.NIP11.SupportedNIPs {
		supportedNIPs[i] = nip
	}
	relay.Info.SupportedNIPs = supportedNIPs
	relay.Info.Software = config.NIP11.Software
	relay.Info.Version = config.NIP11.Version

	// Set up storage handlers
	relay.StoreEvent = append(relay.StoreEvent, storage.SaveEvent)
	relay.QueryEvents = append(relay.QueryEvents, storage.QueryEvents)
	relay.DeleteEvent = append(relay.DeleteEvent, storage.DeleteEvent)
	relay.CountEvents = append(relay.CountEvents, storage.CountEvents)

	// NIP-9: Handle deletion events (kind 5)
	// When a kind 5 event is stored, delete the referenced events
	relay.OnEventSaved = append(relay.OnEventSaved, func(ctx context.Context, event *nostr.Event) {
		if event.Kind != 5 {
			return
		}

		// Process each 'e' tag (event IDs to delete)
		for _, tag := range event.Tags {
			if len(tag) >= 2 && tag[0] == "e" {
				targetID := tag[1]

				// Query the target event to verify pubkey matches
				ch, err := storage.QueryEvents(ctx, nostr.Filter{
					IDs:   []string{targetID},
					Limit: 1,
				})
				if err != nil {
					log.Printf("NIP-9: failed to query event %s: %v", targetID, err)
					continue
				}

				// Check if event exists and pubkey matches
				for targetEvent := range ch {
					if targetEvent.PubKey == event.PubKey {
						// Same author - delete the event
						if err := storage.DeleteEvent(ctx, targetEvent); err != nil {
							log.Printf("NIP-9: failed to delete event %s: %v", targetID, err)
						} else {
							log.Printf("NIP-9: deleted event %s (requested by %s...)", targetID[:12], event.PubKey[:12])
						}
					} else {
						log.Printf("NIP-9: ignoring deletion request for %s (pubkey mismatch)", targetID[:12])
					}
				}
			}
		}
	})

	// NIP-97: Create event watcher service for push notifications
	eventWatcher := NewEventWatcherService(pushService)

	// NIP-97: Handle push notifications for incoming events
	relay.OnEventSaved = append(relay.OnEventSaved, func(ctx context.Context, event *nostr.Event) {
		// Don't notify for deletion events or internal event types
		if event.Kind == 5 {
			return
		}
		eventWatcher.OnEventSaved(ctx, event)
	})

	// Apply default policies
	relay.RejectEvent = append(relay.RejectEvent,
		policies.PreventLargeTags(config.Limits.MaxEventTags),
		policies.RestrictToSpecifiedKinds(
			false, // Not restrictive - allow all kinds
		),
	)

	// Allow all connections (local relay, trust local network)
	relay.RejectConnection = append(relay.RejectConnection,
		func(r *http.Request) bool {
			return false // Accept all connections
		},
	)

	r := &Relay{
		config:       config,
		khatru:       relay,
		storage:      storage,
		pushService:  pushService,
		eventWatcher: eventWatcher,
	}

	return r, nil
}

// Start starts the relay server
func (r *Relay) Start(ctx context.Context) error {
	r.mu.Lock()
	r.startTime = time.Now()
	r.mu.Unlock()

	// Create HTTP mux
	mux := http.NewServeMux()

	// Health endpoint
	mux.HandleFunc("/health", r.handleHealth)

	// Stats endpoint
	mux.HandleFunc("/stats", r.handleStats)

	// NIP-97: Push notification registration endpoint
	mux.HandleFunc("/register", r.pushService.HandleRegister)

	// NIP-97: Push notification unregister endpoint
	mux.HandleFunc("/unregister", r.pushService.HandleUnregister)

	// NIP-97: Push notification stats endpoint
	mux.HandleFunc("/push/stats", r.handlePushStats)

	// NIP-11 info endpoint (served at root for Accept: application/nostr+json)
	// Khatru handles this automatically at the WebSocket endpoint

	// WebSocket endpoint (Khatru relay)
	mux.Handle("/", r.khatru)

	// Create server
	addr := fmt.Sprintf("127.0.0.1:%d", r.config.Port)
	r.server = &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("Starting TENEX relay on %s", addr)
	log.Printf("NIP-11 Info: %s - %s", r.config.NIP11.Name, r.config.NIP11.Description)

	// Start server in goroutine
	errCh := make(chan error, 1)
	go func() {
		if err := r.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	// Wait for context cancellation or error
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

	// Shutdown HTTP server with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if r.server != nil {
		if err := r.server.Shutdown(ctx); err != nil {
			log.Printf("Server shutdown error: %v", err)
		}
	}

	// Close storage
	if r.storage != nil {
		if err := r.storage.Close(); err != nil {
			log.Printf("Storage close error: %v", err)
		}
	}

	log.Println("Relay shutdown complete")
	return nil
}

// handleHealth responds to health check requests
func (r *Relay) handleHealth(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "healthy",
		"relay":  r.config.NIP11.Name,
	})
}

// handleStats responds with relay statistics
func (r *Relay) handleStats(w http.ResponseWriter, req *http.Request) {
	r.mu.RLock()
	uptime := time.Since(r.startTime)
	r.mu.RUnlock()

	count, _ := r.storage.CountEvents(context.Background(), nostr.Filter{})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"uptime_seconds": int(uptime.Seconds()),
		"event_count":    count,
		"relay_info":     r.config.NIP11,
	})
}

// handlePushStats responds with NIP-97 push notification statistics
func (r *Relay) handlePushStats(w http.ResponseWriter, req *http.Request) {
	stats := r.pushService.Stats()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

// WriteConfigTemplate writes a config template to the given path
func WriteConfigTemplate(path string) error {
	config := DefaultConfig()
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}

	// Ensure parent directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}
