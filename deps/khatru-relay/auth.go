package main

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// AuthManager handles NIP-42 authentication and pubkey authorization
type AuthManager struct {
	config *AuthConfig

	// Cached authorized agent pubkeys (from kind:24010 events)
	mu            sync.RWMutex
	agentPubkeys  map[string]struct{}
	lastRefreshed time.Time

	// Relay pool for subscribing to 24010 events
	pool *nostr.SimplePool
}

// NewAuthManager creates a new auth manager with the given configuration
func NewAuthManager(config *AuthConfig) *AuthManager {
	return &AuthManager{
		config:       config,
		agentPubkeys: make(map[string]struct{}),
	}
}

// IsAuthorized checks if a pubkey is authorized to access the relay.
// Authorization order:
// 1. Owner pubkey - always authorized
// 2. Whitelisted pubkeys - always authorized
// 3. Backend pubkey - always authorized
// 4. Agent pubkeys - from kind:24010 events
func (a *AuthManager) IsAuthorized(pubkey string) bool {
	if !a.config.Enabled {
		return true // Auth disabled, everyone allowed
	}

	if pubkey == "" {
		return false // No pubkey means not authenticated
	}

	// 1. Owner pubkey
	if a.config.OwnerPubkey != "" && pubkey == a.config.OwnerPubkey {
		return true
	}

	// 2. Whitelisted pubkeys
	for _, wp := range a.config.WhitelistedPubkeys {
		if pubkey == wp {
			return true
		}
	}

	// 3. Backend pubkey
	if a.config.BackendPubkey != "" && pubkey == a.config.BackendPubkey {
		return true
	}

	// 4. Agent pubkeys (from 24010 events)
	a.mu.RLock()
	_, isAgent := a.agentPubkeys[pubkey]
	a.mu.RUnlock()

	return isAgent
}

// Start begins monitoring for kind:24010 events to extract agent pubkeys
func (a *AuthManager) Start(ctx context.Context) {
	if !a.config.Enabled {
		return
	}

	if a.config.BackendPubkey == "" {
		log.Println("[Auth] No backend pubkey configured, skipping 24010 subscription")
		return
	}

	if len(a.config.SyncRelays) == 0 {
		log.Println("[Auth] No sync relays configured, skipping 24010 subscription")
		return
	}

	a.pool = nostr.NewSimplePool(ctx)

	// Initial fetch
	a.fetchAgentPubkeys(ctx)

	// Subscribe for updates
	go a.subscribeToAgentEvents(ctx)
}

// fetchAgentPubkeys fetches the latest 24010 events from sync relays
func (a *AuthManager) fetchAgentPubkeys(ctx context.Context) {
	if a.pool == nil {
		return
	}

	filter := nostr.Filter{
		Kinds:   []int{24010},
		Authors: []string{a.config.BackendPubkey},
		Limit:   100,
	}

	log.Printf("[Auth] Fetching 24010 events from %d relays for backend %s...",
		len(a.config.SyncRelays), truncatePubkey(a.config.BackendPubkey))

	timeoutCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	events := a.pool.SubManyEose(timeoutCtx, a.config.SyncRelays, nostr.Filters{filter})

	newAgents := make(map[string]struct{})
	eventCount := 0

	for relayEvent := range events {
		eventCount++
		a.extractAgentPubkeys(relayEvent.Event, newAgents)
	}

	a.mu.Lock()
	a.agentPubkeys = newAgents
	a.lastRefreshed = time.Now()
	a.mu.Unlock()

	log.Printf("[Auth] Loaded %d agent pubkeys from %d events", len(newAgents), eventCount)
}

// subscribeToAgentEvents subscribes to live 24010 events for updates
func (a *AuthManager) subscribeToAgentEvents(ctx context.Context) {
	if a.pool == nil {
		return
	}

	now := nostr.Now()
	filter := nostr.Filter{
		Kinds:   []int{24010},
		Authors: []string{a.config.BackendPubkey},
		Since:   &now,
	}

	log.Printf("[Auth] Subscribing to 24010 events...")

	events := a.pool.SubMany(ctx, a.config.SyncRelays, nostr.Filters{filter})

	for relayEvent := range events {
		a.mu.Lock()
		a.extractAgentPubkeys(relayEvent.Event, a.agentPubkeys)
		a.mu.Unlock()

		log.Printf("[Auth] Updated agent pubkeys from new 24010 event, total: %d", len(a.agentPubkeys))
	}
}

// extractAgentPubkeys extracts agent pubkeys from a 24010 event's tags
// Tags format: ["agent", "<pubkey>", ...]
// SECURITY: Only extracts from events that pass signature and pubkey verification
func (a *AuthManager) extractAgentPubkeys(event *nostr.Event, dest map[string]struct{}) {
	// CRITICAL SECURITY: Verify event is from trusted backend
	if event.PubKey != a.config.BackendPubkey {
		log.Printf("[Auth] SECURITY: Rejecting 24010 event from untrusted pubkey %s (expected %s)",
			truncatePubkey(event.PubKey), truncatePubkey(a.config.BackendPubkey))
		return
	}

	// CRITICAL SECURITY: Verify event signature
	ok, err := event.CheckSignature()
	if err != nil {
		log.Printf("[Auth] SECURITY: Failed to verify 24010 event signature: %v", err)
		return
	}
	if !ok {
		log.Printf("[Auth] SECURITY: Rejecting 24010 event with invalid signature from %s",
			truncatePubkey(event.PubKey))
		return
	}

	// Event is verified, extract agent pubkeys
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == "agent" {
			pubkey := tag[1]
			if pubkey != "" && len(pubkey) == 64 {
				dest[pubkey] = struct{}{}
			}
		}
	}
}

// Stop stops the auth manager
func (a *AuthManager) Stop() {
	if a.pool != nil {
		// SimplePool doesn't have a Close method, just let it be garbage collected
		a.pool = nil
	}
}

// Stats returns current auth manager statistics
func (a *AuthManager) Stats() map[string]interface{} {
	a.mu.RLock()
	defer a.mu.RUnlock()

	return map[string]interface{}{
		"enabled":        a.config.Enabled,
		"agent_count":    len(a.agentPubkeys),
		"last_refreshed": a.lastRefreshed,
	}
}

func truncatePubkey(pubkey string) string {
	if len(pubkey) > 12 {
		return pubkey[:12] + "..."
	}
	return pubkey
}
