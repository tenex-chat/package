package main

import (
	"bufio"
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/fiatjaf/khatru"
	"github.com/nbd-wtf/go-nostr"
)

// ACL manages a pubkey whitelist for read access control.
// Admin pubkeys (from config) are always whitelisted. Publishing a kind 14199
// event with p-tags dynamically whitelists those tagged pubkeys. Whitelisting
// is transitive: if A whitelists B, and B has a 14199 tagging C, C also gets
// whitelisted.
type ACL struct {
	adminPubkeys map[string]bool
	whitelist    map[string]bool
	fileAllow    map[string]bool
	mu           sync.RWMutex

	storage eventstore.Store

	whitelistFilePath string
}

func NewACL(adminPubkeys []string, storage eventstore.Store) *ACL {
	admins := make(map[string]bool, len(adminPubkeys))
	for _, pk := range adminPubkeys {
		admins[pk] = true
	}

	acl := &ACL{
		adminPubkeys:      admins,
		whitelist:         make(map[string]bool),
		fileAllow:         make(map[string]bool),
		storage:           storage,
		whitelistFilePath: defaultDaemonWhitelistPath(),
	}

	acl.loadWhitelistFile()
	acl.buildWhitelistFromStorage()
	return acl
}

func (a *ACL) IsWhitelisted(pubkey string) bool {
	if pubkey == "" {
		return false
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.adminPubkeys[pubkey] || a.whitelist[pubkey] || a.fileAllow[pubkey]
}

func defaultDaemonWhitelistPath() string {
	if base := os.Getenv("TENEX_BASE_DIR"); base != "" {
		return filepath.Join(base, "daemon", "whitelist.txt")
	}
	return expandPath("~/.tenex/daemon/whitelist.txt")
}

// StartWhitelistFileSync polls daemon/whitelist.txt so newly added pubkeys
// become effective without restarting the relay.
func (a *ACL) StartWhitelistFileSync(ctx context.Context) {
	// Initial refresh on startup.
	a.loadWhitelistFile()

	ticker := time.NewTicker(2 * time.Second)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				a.loadWhitelistFile()
			}
		}
	}()
}

func (a *ACL) loadWhitelistFile() {
	path := a.whitelistFilePath
	if path == "" {
		return
	}

	fileAllow := make(map[string]bool)

	file, err := os.Open(path)
	if err != nil {
		// Missing file means no daemon whitelist entries.
		if !os.IsNotExist(err) {
			log.Printf("[acl] failed to open whitelist file %s: %v", path, err)
		}
	} else {
		defer file.Close()

		scanner := bufio.NewScanner(file)
		lineNo := 0
		for scanner.Scan() {
			lineNo++
			line := strings.TrimSpace(scanner.Text())
			if idx := strings.Index(line, "#"); idx >= 0 {
				line = strings.TrimSpace(line[:idx])
			}
			if line == "" {
				continue
			}
			if !nostr.IsValidPublicKey(line) {
				log.Printf("[acl] ignoring invalid pubkey in %s:%d", path, lineNo)
				continue
			}
			fileAllow[line] = true
		}
		if err := scanner.Err(); err != nil {
			log.Printf("[acl] failed reading whitelist file %s: %v", path, err)
		}
	}

	a.mu.Lock()
	prev := a.fileAllow
	changed := !samePubkeySet(prev, fileAllow)
	a.fileAllow = fileAllow
	a.mu.Unlock()

	if changed {
		log.Printf("[acl] loaded %d pubkey(s) from whitelist file %s", len(fileAllow), path)
	}
}

func samePubkeySet(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

// buildWhitelistFromStorage queries all stored 14199 events and iteratively
// resolves transitive whitelist chains (admin→B, B→C, etc.). Called once
// during initialization.
func (a *ACL) buildWhitelistFromStorage() {
	ch, err := a.storage.QueryEvents(context.Background(), nostr.Filter{
		Kinds: []int{14199},
	})
	if err != nil {
		log.Printf("[acl] failed to query stored 14199 events: %v", err)
		return
	}

	var events []*nostr.Event
	for evt := range ch {
		events = append(events, evt)
	}

	// Iteratively resolve transitive chains until no new entries are added
	changed := true
	for changed {
		changed = false
		for _, evt := range events {
			if !a.adminPubkeys[evt.PubKey] && !a.whitelist[evt.PubKey] {
				continue
			}
			for _, tag := range evt.Tags {
				if len(tag) >= 2 && tag[0] == "p" {
					pk := tag[1]
					if !a.adminPubkeys[pk] && !a.whitelist[pk] {
						a.whitelist[pk] = true
						changed = true
						log.Printf("[acl] whitelisted %s... (from stored 14199 by %s...)", truncatePubkey(pk), truncatePubkey(evt.PubKey))
					}
				}
			}
		}
	}

	log.Printf("[acl] built whitelist: %d admin(s), %d dynamic entries", len(a.adminPubkeys), len(a.whitelist))
}

// ProcessWhitelistEvent handles a kind 14199 event: if the author is
// whitelisted, all p-tagged pubkeys get whitelisted. Recursively resolves
// transitive chains for newly whitelisted pubkeys.
func (a *ACL) ProcessWhitelistEvent(event *nostr.Event) {
	if event.Kind != 14199 {
		return
	}

	if !a.IsWhitelisted(event.PubKey) {
		log.Printf("[acl] ignoring 14199 from non-whitelisted pubkey %s...", truncatePubkey(event.PubKey))
		return
	}

	var newlyWhitelisted []string

	a.mu.Lock()
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == "p" {
			pk := tag[1]
			if !a.adminPubkeys[pk] && !a.whitelist[pk] {
				a.whitelist[pk] = true
				newlyWhitelisted = append(newlyWhitelisted, pk)
				log.Printf("[acl] whitelisted %s... (14199 from %s...)", truncatePubkey(pk), truncatePubkey(event.PubKey))
			}
		}
	}
	a.mu.Unlock()

	// Resolve transitive chains: newly whitelisted pubkeys may have their own 14199 events
	for _, pk := range newlyWhitelisted {
		a.resolveTransitiveWhitelist(pk)
	}
}

func (a *ACL) resolveTransitiveWhitelist(pubkey string) {
	ch, err := a.storage.QueryEvents(context.Background(), nostr.Filter{
		Authors: []string{pubkey},
		Kinds:   []int{14199},
	})
	if err != nil {
		log.Printf("[acl] failed to query 14199 events for %s...: %v", truncatePubkey(pubkey), err)
		return
	}

	for evt := range ch {
		a.ProcessWhitelistEvent(evt)
	}
}

// Public readable kinds are available to authenticated non-whitelisted users.
// These are TENEX metadata streams that should be broadly visible.
func isPublicReadableKind(kind int) bool {
	return kind == 4199 || kind == 34199
}

// isEphemeral returns true for kinds 20000-29999
func isEphemeral(kind int) bool {
	return kind >= 20000 && kind <= 29999
}

func isNonRestrictedKind(kind int) bool {
	return isEphemeral(kind) || isPublicReadableKind(kind)
}

// OverwriteFilterHook defers subscriptions for authenticated but non-whitelisted
// pubkeys by setting LimitZero, which skips stored event queries but still
// registers the listener for live events.
//
// Exception: filters that request only public-readable kinds (4199, 34199) or
// ephemeral kinds are allowed for non-whitelisted users.
//
// Unauthenticated users are left unmodified so RejectFilter can send
// auth-required.
func (a *ACL) OverwriteFilterHook(ctx context.Context, filter *nostr.Filter) {
	// Filters that request only non-restricted kinds bypass ACL.
	if len(filter.Kinds) > 0 {
		allNonRestricted := true
		for _, k := range filter.Kinds {
			if !isNonRestrictedKind(k) {
				allNonRestricted = false
				break
			}
		}
		if allNonRestricted {
			return
		}
	}

	pubkey := khatru.GetAuthed(ctx)

	// Not authenticated: don't set LimitZero, let RejectFilter handle auth-required
	if pubkey == "" {
		return
	}

	// Authenticated and whitelisted: allow normally
	if a.IsWhitelisted(pubkey) {
		return
	}

	// Authenticated but not whitelisted: defer (skip stored events, register listener)
	filter.LimitZero = true
	log.Printf("[acl] deferred subscription for non-whitelisted pubkey %s...", truncatePubkey(pubkey))
}

// PreventBroadcastHook blocks live event delivery to non-whitelisted
// subscribers.
//
// Exceptions for non-whitelisted users:
// - Ephemeral events (20000-29999)
// - Public readable events (4199, 34199)
func (a *ACL) PreventBroadcastHook(ws *khatru.WebSocket, event *nostr.Event) bool {
	if isNonRestrictedKind(event.Kind) {
		return false
	}

	if a.IsWhitelisted(ws.AuthedPublicKey) {
		return false
	}

	return true
}

// OnEventSavedHook processes kind 14199 events to update the whitelist.
func (a *ACL) OnEventSavedHook(ctx context.Context, event *nostr.Event) {
	if event.Kind != 14199 {
		return
	}
	a.ProcessWhitelistEvent(event)
}

func truncatePubkey(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}
