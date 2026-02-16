package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// NIP-97: Push Notification Event Watcher API
// This implements a push notification service that allows clients to register
// push tokens and receive notifications when events matching their filters arrive.

const (
	// Push notification system types
	PushSystemGoogle      = "google"
	PushSystemApple       = "apple"
	PushSystemUnifiedPush = "unifiedpush"

	// Kind for event watcher preference list (NIP-97)
	KindEventWatcherList = 10097
)

// PushToken represents a registered push notification token
type PushToken struct {
	Pubkey       string    `json:"pubkey"`
	System       string    `json:"system"`       // google, apple, unifiedpush
	Token        string    `json:"token"`        // The push token
	Relays       []string  `json:"relays"`       // Inbox relays to watch
	RegisteredAt time.Time `json:"registered_at"`
	LastUsed     time.Time `json:"last_used"`
	FailureCount int       `json:"failure_count"`
}

// PushRegistrationResponse represents the registration response
type PushRegistrationResponse struct {
	Results []PushRegistrationResult `json:"results"`
}

// PushRegistrationResult represents the result for a single pubkey registration
type PushRegistrationResult struct {
	Pubkey string `json:"pubkey"`
	Status string `json:"status"` // added, replaced, error
	Error  string `json:"error,omitempty"`
}

// PushNotifyService manages push notification registrations and delivery
type PushNotifyService struct {
	mu           sync.RWMutex
	tokens       map[string][]*PushToken // pubkey -> tokens
	config       *PushNotifyConfig

	// Callbacks for actual push delivery (to be set by integrators)
	deliverAPNS       func(token string, payload []byte) error
	deliverFCM        func(token string, payload []byte) error
	deliverUnifiedPush func(endpoint string, payload []byte) error
}

// PushNotifyConfig contains push notification service configuration
type PushNotifyConfig struct {
	Enabled           bool   `json:"enabled"`
	MaxTokensPerPubkey int   `json:"max_tokens_per_pubkey"`
	MaxFailureCount   int    `json:"max_failure_count"`

	// APNS configuration (for Apple push)
	APNSEnabled     bool   `json:"apns_enabled"`
	APNSTopic       string `json:"apns_topic"`        // App bundle ID
	APNSKeyPath     string `json:"apns_key_path"`     // Path to .p8 key file
	APNSKeyID       string `json:"apns_key_id"`
	APNSTeamID      string `json:"apns_team_id"`
	APNSProduction  bool   `json:"apns_production"`   // false = sandbox

	// FCM configuration (for Google/Android push)
	FCMEnabled      bool   `json:"fcm_enabled"`
	FCMCredentials  string `json:"fcm_credentials"`   // Path to service account JSON

	// UnifiedPush configuration
	UnifiedPushEnabled bool `json:"unified_push_enabled"`
}

// DefaultPushNotifyConfig returns default push notification configuration
func DefaultPushNotifyConfig() *PushNotifyConfig {
	return &PushNotifyConfig{
		Enabled:            false, // Disabled by default
		MaxTokensPerPubkey: 5,
		MaxFailureCount:    3,
		APNSEnabled:        false,
		APNSProduction:     false,
		FCMEnabled:         false,
		UnifiedPushEnabled: false,
	}
}

// NewPushNotifyService creates a new push notification service
func NewPushNotifyService(config *PushNotifyConfig) *PushNotifyService {
	if config == nil {
		config = DefaultPushNotifyConfig()
	}

	// Validate configuration
	if config.MaxFailureCount <= 0 {
		// Default to 3 to prevent immediate token eviction on first failure
		config.MaxFailureCount = 3
	}
	if config.MaxTokensPerPubkey <= 0 {
		config.MaxTokensPerPubkey = 5
	}

	return &PushNotifyService{
		tokens: make(map[string][]*PushToken),
		config: config,
	}
}

// RegisterToken registers a push token for a pubkey
func (s *PushNotifyService) RegisterToken(pubkey, system, token string, relays []string) (string, error) {
	if !s.config.Enabled {
		return "", fmt.Errorf("push notifications are disabled")
	}

	// Validate system type
	switch system {
	case PushSystemGoogle:
		if !s.config.FCMEnabled {
			return "", fmt.Errorf("FCM push notifications are not configured")
		}
	case PushSystemApple:
		if !s.config.APNSEnabled {
			return "", fmt.Errorf("APNS push notifications are not configured")
		}
	case PushSystemUnifiedPush:
		if !s.config.UnifiedPushEnabled {
			return "", fmt.Errorf("UnifiedPush notifications are not configured")
		}
	default:
		return "", fmt.Errorf("unsupported push system: %s", system)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if token already exists for this pubkey
	existingTokens := s.tokens[pubkey]
	for i, t := range existingTokens {
		if t.Token == token && t.System == system {
			// Update existing token
			existingTokens[i].Relays = relays
			existingTokens[i].LastUsed = time.Now()
			existingTokens[i].FailureCount = 0
			return "replaced", nil
		}
	}

	// Check max tokens limit
	if len(existingTokens) >= s.config.MaxTokensPerPubkey && s.config.MaxTokensPerPubkey > 0 {
		// Remove oldest token
		oldest := 0
		for i, t := range existingTokens {
			if t.RegisteredAt.Before(existingTokens[oldest].RegisteredAt) {
				oldest = i
			}
		}
		// Safe slice removal
		if oldest == len(existingTokens)-1 {
			existingTokens = existingTokens[:oldest]
		} else {
			existingTokens = append(existingTokens[:oldest], existingTokens[oldest+1:]...)
		}
	}

	// Add new token
	newToken := &PushToken{
		Pubkey:       pubkey,
		System:       system,
		Token:        token,
		Relays:       relays,
		RegisteredAt: time.Now(),
		LastUsed:     time.Now(),
		FailureCount: 0,
	}

	s.tokens[pubkey] = append(existingTokens, newToken)
	return "added", nil
}

// RemoveToken removes a push token
func (s *PushNotifyService) RemoveToken(pubkey, token string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.removeTokenLocked(pubkey, token)
}

// removeTokenLocked removes a token while holding the lock.
// It also cleans up empty pubkey entries to prevent memory leaks.
func (s *PushNotifyService) removeTokenLocked(pubkey, token string) {
	tokens := s.tokens[pubkey]
	for i, t := range tokens {
		if t.Token == token {
			newTokens := append(tokens[:i], tokens[i+1:]...)
			if len(newTokens) == 0 {
				// Clean up empty entry to prevent memory leak
				delete(s.tokens, pubkey)
			} else {
				s.tokens[pubkey] = newTokens
			}
			return
		}
	}
}

// GetTokensForPubkey returns a copy of all tokens registered for a pubkey.
// The returned slice is safe to iterate over without holding locks.
func (s *PushNotifyService) GetTokensForPubkey(pubkey string) []*PushToken {
	s.mu.RLock()
	defer s.mu.RUnlock()

	tokens := s.tokens[pubkey]
	if len(tokens) == 0 {
		return nil
	}

	// Return a copy to prevent data races during iteration
	result := make([]*PushToken, len(tokens))
	for i, t := range tokens {
		// Deep copy the token to prevent race conditions on token fields
		tokenCopy := *t
		// Also copy the relays slice
		if len(t.Relays) > 0 {
			tokenCopy.Relays = make([]string, len(t.Relays))
			copy(tokenCopy.Relays, t.Relays)
		}
		result[i] = &tokenCopy
	}
	return result
}

// NotifyEvent sends push notifications for an event to all registered recipients
// The event is wrapped using NIP-59 GiftWrap format for privacy
func (s *PushNotifyService) NotifyEvent(ctx context.Context, event *nostr.Event, recipientPubkey string) error {
	if !s.config.Enabled {
		return nil
	}

	tokens := s.GetTokensForPubkey(recipientPubkey)
	if len(tokens) == 0 {
		return nil // No tokens registered
	}

	// Create wrapped notification payload (NIP-59 style)
	// Note: Per NIP-97, no p-tag is added to prevent push system from identifying recipient
	payload, err := s.createNotificationPayload(event)
	if err != nil {
		return fmt.Errorf("failed to create notification payload: %w", err)
	}

	// Send to all registered tokens
	var lastErr error
	for _, token := range tokens {
		var deliverErr error
		var delivered bool

		switch token.System {
		case PushSystemApple:
			if s.deliverAPNS != nil {
				deliverErr = s.deliverAPNS(token.Token, payload)
				delivered = true
			} else {
				log.Printf("NIP-97: APNS delivery callback not configured, skipping token for %s", recipientPubkey[:12])
			}
		case PushSystemGoogle:
			if s.deliverFCM != nil {
				deliverErr = s.deliverFCM(token.Token, payload)
				delivered = true
			} else {
				log.Printf("NIP-97: FCM delivery callback not configured, skipping token for %s", recipientPubkey[:12])
			}
		case PushSystemUnifiedPush:
			if s.deliverUnifiedPush != nil {
				deliverErr = s.deliverUnifiedPush(token.Token, payload)
				delivered = true
			} else {
				log.Printf("NIP-97: UnifiedPush delivery callback not configured, skipping token for %s", recipientPubkey[:12])
			}
		}

		if deliverErr != nil {
			lastErr = deliverErr
			s.recordFailure(recipientPubkey, token.Token)
		} else if delivered {
			// Only record success if we actually attempted delivery
			s.recordSuccess(recipientPubkey, token.Token)
		}
		// If not delivered (callback not set), we don't record success or failure
		// This prevents false success counts while avoiding token removal for config issues
	}

	return lastErr
}

// createNotificationPayload creates a NIP-44 encrypted notification payload
func (s *PushNotifyService) createNotificationPayload(event *nostr.Event) ([]byte, error) {
	// Create a notification envelope
	notification := map[string]interface{}{
		"event_id":   event.ID,
		"kind":       event.Kind,
		"pubkey":     event.PubKey,
		"created_at": event.CreatedAt,
	}

	// For DMs and other private events, don't include content
	// For public events, include a preview
	if event.Kind == 1 || event.Kind == 6 || event.Kind == 7 {
		// Public note, repost, or reaction - include content preview
		content := event.Content
		if len(content) > 100 {
			content = content[:100] + "..."
		}
		notification["content_preview"] = content
	}

	return json.Marshal(notification)
}

// recordFailure records a delivery failure for a token
func (s *PushNotifyService) recordFailure(pubkey, token string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tokens := s.tokens[pubkey]
	for i, t := range tokens {
		if t.Token == token {
			tokens[i].FailureCount++

			// Remove token if too many failures (and MaxFailureCount > 0)
			if s.config.MaxFailureCount > 0 && tokens[i].FailureCount >= s.config.MaxFailureCount {
				log.Printf("NIP-97: Removing push token for %s after %d failures", pubkey[:12], tokens[i].FailureCount)
				s.removeTokenLocked(pubkey, token)
			}
			return
		}
	}
}

// recordSuccess records a successful delivery
func (s *PushNotifyService) recordSuccess(pubkey, token string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tokens := s.tokens[pubkey]
	for i, t := range tokens {
		if t.Token == token {
			tokens[i].LastUsed = time.Now()
			tokens[i].FailureCount = 0
			return
		}
	}
}

// HandleRegister handles POST /register endpoint for NIP-97
func (s *PushNotifyService) HandleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if !s.config.Enabled {
		http.Error(w, "Push notifications are disabled", http.StatusServiceUnavailable)
		return
	}

	// Parse NIP-98 authorization header
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, "Missing Authorization header (NIP-98)", http.StatusUnauthorized)
		return
	}

	// Build the expected URL from the request (proxy-aware)
	expectedURL := getRequestURL(r)

	// Validate NIP-98 auth event with method and URL binding
	authEvent, err := parseNIP98Auth(authHeader, http.MethodPost, expectedURL)
	if err != nil {
		http.Error(w, fmt.Sprintf("Invalid NIP-98 auth: %v", err), http.StatusUnauthorized)
		return
	}

	// Extract push system and token from the auth event challenge
	// Format: "<system>:<token>"
	system, token, err := parseAuthChallenge(authEvent)
	if err != nil {
		http.Error(w, fmt.Sprintf("Invalid auth challenge: %v", err), http.StatusBadRequest)
		return
	}

	// Extract relays from auth event tags
	var relays []string
	for _, tag := range authEvent.Tags {
		if len(tag) >= 2 && tag[0] == "relay" {
			relays = append(relays, tag[1])
		}
	}

	// Register the token
	status, err := s.RegisterToken(authEvent.PubKey, system, token, relays)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Send response
	response := PushRegistrationResponse{
		Results: []PushRegistrationResult{
			{
				Pubkey: authEvent.PubKey,
				Status: status,
			},
		},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// HandleUnregister handles DELETE /register endpoint
func (s *PushNotifyService) HandleUnregister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if !s.config.Enabled {
		http.Error(w, "Push notifications are disabled", http.StatusServiceUnavailable)
		return
	}

	// Parse NIP-98 authorization header
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		http.Error(w, "Missing Authorization header (NIP-98)", http.StatusUnauthorized)
		return
	}

	// Build the expected URL from the request (proxy-aware)
	expectedURL := getRequestURL(r)

	// Validate NIP-98 auth event with method and URL binding
	authEvent, err := parseNIP98Auth(authHeader, http.MethodDelete, expectedURL)
	if err != nil {
		http.Error(w, fmt.Sprintf("Invalid NIP-98 auth: %v", err), http.StatusUnauthorized)
		return
	}

	// Extract token from challenge
	_, token, err := parseAuthChallenge(authEvent)
	if err != nil {
		http.Error(w, fmt.Sprintf("Invalid auth challenge: %v", err), http.StatusBadRequest)
		return
	}

	// Remove the token
	s.RemoveToken(authEvent.PubKey, token)

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "removed"})
}

// NIP98Kind is the event kind for NIP-98 HTTP Auth
const NIP98Kind = 27235

// getRequestURL constructs the full request URL, properly handling TLS-terminating
// proxies and load balancers by checking standard proxy headers.
// Order of precedence:
// 1. Forwarded header (RFC 7239) - "for=...; proto=https; host=example.com"
// 2. X-Forwarded-Proto + X-Forwarded-Host headers
// 3. X-Forwarded-Proto + r.Host
// 4. Direct connection (r.TLS + r.Host)
func getRequestURL(r *http.Request) string {
	scheme := "http"
	host := r.Host
	foundProto := false
	foundHost := false

	// Check RFC 7239 Forwarded header first (highest priority)
	if forwarded := r.Header.Get("Forwarded"); forwarded != "" {
		// Parse Forwarded header - RFC 7239 allows comma-separated entries for multiple proxies
		// Example: "for=proxy1, for=proxy2; host=example.com" or "for=client; proto=https; host=example.com, for=proxy2"
		// Per RFC 7239, we only use the first entry (leftmost = added by first/trusted proxy)
		// If the first entry lacks proto/host, we fall back to X-Forwarded-* headers below
		foundProto, foundHost = parseForwardedHeader(forwarded, &scheme, &host)
	}

	// Fall back to X-Forwarded-* headers if Forwarded didn't provide proto or host
	if !foundProto {
		if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
			scheme = proto
		} else if r.TLS != nil {
			scheme = "https"
		}
	}

	if !foundHost {
		if fwdHost := r.Header.Get("X-Forwarded-Host"); fwdHost != "" {
			host = fwdHost
		}
	}

	return fmt.Sprintf("%s://%s%s", scheme, host, r.URL.Path)
}

// parseForwardedHeader parses an RFC 7239 Forwarded header value.
// It handles comma-separated entries for multiple proxies and semicolon-separated
// key-value pairs within each entry. Returns whether proto and host were found.
// Example formats:
//   - "for=client; proto=https; host=example.com"
//   - "for=proxy1, for=proxy2; host=example.com"  (comma separates proxy entries)
//   - "proto=\"https\"; host=\"example.com\""     (quoted values)
func parseForwardedHeader(header string, scheme, host *string) (foundProto, foundHost bool) {
	// Split by comma first (RFC 7239: multiple proxies are comma-separated)
	entries := splitForwardedEntries(header)

	// RFC 7239: Entries are ordered left-to-right, with leftmost being closest to client.
	// We ONLY parse the FIRST entry. If it doesn't have proto/host, we return found=false
	// to trigger fallback logic (X-Forwarded-* headers or r.TLS).
	// We do NOT walk through subsequent entries, as those represent proxy-to-proxy hops.
	if len(entries) == 0 {
		return false, false
	}

	// Parse only the first (client-facing) entry
	for _, part := range splitForwardedParts(entries[0]) {
		part = trimSpace(part)
		if len(part) > 6 && part[:6] == "proto=" {
			*scheme = unquoteValue(part[6:])
			foundProto = true
		} else if len(part) > 5 && part[:5] == "host=" {
			*host = unquoteValue(part[5:])
			foundHost = true
		}
	}
	return foundProto, foundHost
}

// splitForwardedEntries splits a Forwarded header by commas (proxy entry separator),
// respecting quoted values.
func splitForwardedEntries(header string) []string {
	return splitForwardedBy(header, ',')
}

// splitForwardedParts splits a single Forwarded entry by semicolons (key-value separator),
// respecting quoted values.
func splitForwardedParts(entry string) []string {
	return splitForwardedBy(entry, ';')
}

// splitForwardedBy splits a Forwarded header/entry by the given delimiter,
// handling quoted values properly (RFC 7239 allows quoted values).
func splitForwardedBy(s string, delimiter byte) []string {
	var parts []string
	var current []byte
	inQuote := false

	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '"' {
			inQuote = !inQuote
			current = append(current, c)
		} else if c == delimiter && !inQuote {
			if len(current) > 0 {
				parts = append(parts, string(current))
				current = current[:0]
			}
		} else {
			current = append(current, c)
		}
	}
	if len(current) > 0 {
		parts = append(parts, string(current))
	}
	return parts
}

// unquoteValue removes surrounding double quotes from a value if present.
// RFC 7239 allows quoted values: proto="https", host="example.com"
func unquoteValue(s string) string {
	s = trimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	return s
}

// trimSpace trims leading and trailing whitespace from a string
// without importing strings package
func trimSpace(s string) string {
	start := 0
	end := len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t') {
		start++
	}
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t') {
		end--
	}
	return s[start:end]
}

// parseNIP98Auth parses a NIP-98 Authorization header and validates the auth event
// It requires the expected method and URL to prevent cross-endpoint and replay attacks
func parseNIP98Auth(authHeader, expectedMethod, expectedURL string) (*nostr.Event, error) {
	// NIP-98 format: "Nostr <base64-encoded-event>"
	if len(authHeader) < 7 || authHeader[:6] != "Nostr " {
		return nil, fmt.Errorf("invalid authorization format")
	}

	// Decode base64 event
	eventJSON, err := base64.StdEncoding.DecodeString(authHeader[6:])
	if err != nil {
		return nil, fmt.Errorf("failed to decode auth event: %w", err)
	}

	var event nostr.Event
	if err := json.Unmarshal(eventJSON, &event); err != nil {
		return nil, fmt.Errorf("failed to parse auth event: %w", err)
	}

	// Verify event kind (27235 for NIP-98, not 22242)
	if event.Kind != NIP98Kind {
		return nil, fmt.Errorf("invalid auth event kind: %d, expected %d", event.Kind, NIP98Kind)
	}

	// Verify signature
	ok, err := event.CheckSignature()
	if err != nil || !ok {
		return nil, fmt.Errorf("invalid signature")
	}

	// Check timestamp (within 60 seconds)
	now := nostr.Now()
	if event.CreatedAt < now-60 || event.CreatedAt > now+60 {
		return nil, fmt.Errorf("auth event expired or from future")
	}

	// NIP-98: Validate required "u" tag (URL binding)
	var foundURL string
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == "u" {
			foundURL = tag[1]
			break
		}
	}
	if foundURL == "" {
		return nil, fmt.Errorf("missing required 'u' tag for URL binding")
	}
	if foundURL != expectedURL {
		return nil, fmt.Errorf("URL mismatch: auth for '%s' but request to '%s'", foundURL, expectedURL)
	}

	// NIP-98: Validate required "method" tag
	var foundMethod string
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == "method" {
			foundMethod = tag[1]
			break
		}
	}
	if foundMethod == "" {
		return nil, fmt.Errorf("missing required 'method' tag")
	}
	if foundMethod != expectedMethod {
		return nil, fmt.Errorf("method mismatch: auth for '%s' but request is '%s'", foundMethod, expectedMethod)
	}

	return &event, nil
}

// parseAuthChallenge extracts system and token from auth event
// Expected content format: "<system>:<token>"
func parseAuthChallenge(event *nostr.Event) (system, token string, err error) {
	content := event.Content

	// Find the separator
	for i, c := range content {
		if c == ':' {
			system = content[:i]
			token = content[i+1:]

			// Validate system
			switch system {
			case PushSystemGoogle, PushSystemApple, PushSystemUnifiedPush:
				return system, token, nil
			default:
				return "", "", fmt.Errorf("unsupported push system: %s", system)
			}
		}
	}

	return "", "", fmt.Errorf("invalid challenge format, expected '<system>:<token>'")
}

// SetAPNSDelivery sets the APNS delivery callback
func (s *PushNotifyService) SetAPNSDelivery(fn func(token string, payload []byte) error) {
	s.deliverAPNS = fn
}

// SetFCMDelivery sets the FCM delivery callback
func (s *PushNotifyService) SetFCMDelivery(fn func(token string, payload []byte) error) {
	s.deliverFCM = fn
}

// SetUnifiedPushDelivery sets the UnifiedPush delivery callback
func (s *PushNotifyService) SetUnifiedPushDelivery(fn func(endpoint string, payload []byte) error) {
	s.deliverUnifiedPush = fn
}

// WrapEventNIP44 wraps an event using NIP-44 encryption for the recipient
// This is used for private notification delivery
// NOTE: This function requires nip44 import - currently a stub for future implementation
func WrapEventNIP44(event *nostr.Event, senderPrivkey, recipientPubkey string) ([]byte, error) {
	// TODO: Implement NIP-44 encryption when needed
	// For now, return the event JSON without encryption (suitable for local relay use)
	return json.Marshal(event)
}

// EventWatcherService watches for events and triggers notifications.
// Currently uses p-tag based notification triggers.
// TODO: Future enhancement - support kind:10097 event watcher preference lists
type EventWatcherService struct {
	pushService *PushNotifyService
}

// NewEventWatcherService creates a new event watcher
func NewEventWatcherService(pushService *PushNotifyService) *EventWatcherService {
	return &EventWatcherService{
		pushService: pushService,
	}
}

// OnEventSaved is called when a new event is saved to the relay
// It checks if any registered watchers should be notified
func (s *EventWatcherService) OnEventSaved(ctx context.Context, event *nostr.Event) {
	// Check p-tags for mentions
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == "p" {
			recipientPubkey := tag[1]

			// Check if this pubkey has registered for notifications
			if tokens := s.pushService.GetTokensForPubkey(recipientPubkey); len(tokens) > 0 {
				// Notify asynchronously
				go func(pubkey string) {
					if err := s.pushService.NotifyEvent(ctx, event, pubkey); err != nil {
						log.Printf("Failed to send push notification to %s: %v", pubkey[:12], err)
					}
				}(recipientPubkey)
			}
		}
	}
}

// Stats returns push notification statistics
func (s *PushNotifyService) Stats() map[string]interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()

	totalTokens := 0
	for _, tokens := range s.tokens {
		totalTokens += len(tokens)
	}

	return map[string]interface{}{
		"enabled":              s.config.Enabled,
		"registered_pubkeys":   len(s.tokens),
		"total_tokens":         totalTokens,
		"apns_enabled":         s.config.APNSEnabled,
		"fcm_enabled":          s.config.FCMEnabled,
		"unified_push_enabled": s.config.UnifiedPushEnabled,
	}
}

// PushNotificationHandler wraps the push notification service for use in the relay
// This provides a simplified interface matching the relay's OnEventSaved callback signature
type PushNotificationHandler struct {
	service *PushNotifyService
}

// NewPushNotificationHandler creates a new push notification handler with default config
func NewPushNotificationHandler() *PushNotificationHandler {
	return &PushNotificationHandler{
		service: NewPushNotifyService(DefaultPushNotifyConfig()),
	}
}

// NewPushNotificationHandlerWithConfig creates a new push notification handler with the given config
func NewPushNotificationHandlerWithConfig(config *PushNotifyConfig) *PushNotificationHandler {
	return &PushNotificationHandler{
		service: NewPushNotifyService(config),
	}
}

// NotifyEvent is called when a new event is saved to the relay
// It checks if any registered watchers should be notified based on p-tags
func (h *PushNotificationHandler) NotifyEvent(ctx context.Context, event *nostr.Event) {
	// Check p-tags for mentions
	for _, tag := range event.Tags {
		if len(tag) >= 2 && tag[0] == "p" {
			recipientPubkey := tag[1]

			// Check if this pubkey has registered for notifications
			if tokens := h.service.GetTokensForPubkey(recipientPubkey); len(tokens) > 0 {
				// Notify asynchronously
				go func(pubkey string) {
					if err := h.service.NotifyEvent(ctx, event, pubkey); err != nil {
						log.Printf("NIP-97: Failed to send push notification to %s: %v", pubkey[:12], err)
					} else {
						log.Printf("NIP-97: Sent push notification to %s for event %s", pubkey[:12], event.ID[:12])
					}
				}(recipientPubkey)
			}
		}
	}
}

// HandleRegister handles POST /register endpoint for NIP-97
func (h *PushNotificationHandler) HandleRegister(w http.ResponseWriter, r *http.Request) {
	h.service.HandleRegister(w, r)
}

// HandleUnregister handles DELETE /register endpoint
func (h *PushNotificationHandler) HandleUnregister(w http.ResponseWriter, r *http.Request) {
	h.service.HandleUnregister(w, r)
}

// HandleStats returns push notification statistics as JSON
func (h *PushNotificationHandler) HandleStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(h.service.Stats())
}

// Service returns the underlying push notification service for advanced configuration
func (h *PushNotificationHandler) Service() *PushNotifyService {
	return h.service
}
