package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func TestPushNotifyService_RegisterToken(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:            true,
		MaxTokensPerPubkey: 5,
		MaxFailureCount:    3,
		FCMEnabled:         true,
		APNSEnabled:        true,
		UnifiedPushEnabled: true,
	}

	service := NewPushNotifyService(config)

	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	// Test adding a Google token
	status, err := service.RegisterToken(pubkey, PushSystemGoogle, "google-token-123", []string{"wss://relay.example.com"})
	if err != nil {
		t.Fatalf("failed to register token: %v", err)
	}
	if status != "added" {
		t.Errorf("expected status 'added', got '%s'", status)
	}

	// Verify token was stored
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Fatalf("expected 1 token, got %d", len(tokens))
	}

	if tokens[0].System != PushSystemGoogle {
		t.Errorf("expected system 'google', got '%s'", tokens[0].System)
	}

	if tokens[0].Token != "google-token-123" {
		t.Errorf("expected token 'google-token-123', got '%s'", tokens[0].Token)
	}
}

func TestPushNotifyService_ReplaceToken(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		APNSEnabled: true,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	// Register first token
	service.RegisterToken(pubkey, PushSystemApple, "apple-token-1", []string{"wss://relay1.example.com"})

	// Register same token again with different relays
	status, _ := service.RegisterToken(pubkey, PushSystemApple, "apple-token-1", []string{"wss://relay2.example.com"})
	if status != "replaced" {
		t.Errorf("expected status 'replaced', got '%s'", status)
	}

	// Should still have only 1 token
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Errorf("expected 1 token after replace, got %d", len(tokens))
	}

	// Verify relay was updated
	if len(tokens[0].Relays) != 1 || tokens[0].Relays[0] != "wss://relay2.example.com" {
		t.Errorf("expected updated relay, got %v", tokens[0].Relays)
	}
}

func TestPushNotifyService_MaxTokensLimit(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:            true,
		MaxTokensPerPubkey: 2,
		FCMEnabled:         true,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	// Register max tokens
	service.RegisterToken(pubkey, PushSystemGoogle, "token-1", nil)
	time.Sleep(10 * time.Millisecond) // Ensure different timestamps
	service.RegisterToken(pubkey, PushSystemGoogle, "token-2", nil)

	// Register one more (should evict oldest)
	service.RegisterToken(pubkey, PushSystemGoogle, "token-3", nil)

	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 2 {
		t.Errorf("expected 2 tokens (max), got %d", len(tokens))
	}

	// token-1 should have been evicted (oldest)
	for _, tok := range tokens {
		if tok.Token == "token-1" {
			t.Error("oldest token should have been evicted")
		}
	}
}

func TestPushNotifyService_RemoveToken(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	// Register token
	service.RegisterToken(pubkey, PushSystemGoogle, "token-to-remove", nil)

	// Verify it exists
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Fatalf("expected 1 token, got %d", len(tokens))
	}

	// Remove it
	service.RemoveToken(pubkey, "token-to-remove")

	// Verify it's gone
	tokens = service.GetTokensForPubkey(pubkey)
	if len(tokens) != 0 {
		t.Errorf("expected 0 tokens after removal, got %d", len(tokens))
	}
}

func TestPushNotifyService_DisabledService(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled: false,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	_, err := service.RegisterToken(pubkey, PushSystemGoogle, "token", nil)
	if err == nil {
		t.Error("expected error when service is disabled")
	}
}

func TestPushNotifyService_UnsupportedSystem(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: false, // Google not enabled
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	_, err := service.RegisterToken(pubkey, PushSystemGoogle, "token", nil)
	if err == nil {
		t.Error("expected error for unsupported system")
	}
}

func TestPushNotifyService_HandleRegister(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	// Create a valid NIP-98 auth event with proper kind and tags
	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	// NIP-98 requires kind 27235, u tag for URL, and method tag
	authEvent := &nostr.Event{
		Kind:      27235, // NIP-98 HTTP Auth kind
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "http://example.com/register"},    // URL binding
			{"method", "POST"},                       // HTTP method
			{"relay", "wss://relay.example.com"},     // Additional relay tag
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	// Encode as base64 for NIP-98 header
	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	// Verify token was registered
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Errorf("expected 1 token, got %d", len(tokens))
	}
}

func TestPushNotifyService_HandleRegister_NoAuth(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	// No Authorization header

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401, got %d", rr.Code)
	}
}

func TestPushNotifyService_HandleRegister_Disabled(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled: false,
	}

	service := NewPushNotifyService(config)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Header.Set("Authorization", "Nostr dummy")

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected status 503, got %d", rr.Code)
	}
}

func TestPushNotifyService_Stats(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
		APNSEnabled: true,
	}

	service := NewPushNotifyService(config)

	// Register some tokens
	service.RegisterToken("pubkey1234567890123456789012345678901234567890123456789012345678", PushSystemGoogle, "token1", nil)
	service.RegisterToken("pubkey2234567890123456789012345678901234567890123456789012345678", PushSystemApple, "token2", nil)

	stats := service.Stats()

	if stats["enabled"] != true {
		t.Error("expected enabled=true")
	}

	if stats["registered_pubkeys"].(int) != 2 {
		t.Errorf("expected 2 registered pubkeys, got %v", stats["registered_pubkeys"])
	}

	if stats["total_tokens"].(int) != 2 {
		t.Errorf("expected 2 total tokens, got %v", stats["total_tokens"])
	}
}

func TestEventWatcherService_OnEventSaved(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	pushService := NewPushNotifyService(config)
	watcher := NewEventWatcherService(pushService)

	// Register a token
	recipientPubkey := "recipient123456789012345678901234567890123456789012345678901234"
	pushService.RegisterToken(recipientPubkey, PushSystemGoogle, "recipient-token", nil)

	// Track notification delivery
	deliveryCount := 0
	pushService.SetFCMDelivery(func(token string, payload []byte) error {
		deliveryCount++
		return nil
	})

	// Create an event that mentions the recipient
	event := &nostr.Event{
		ID:        "event12345678901234567890123456789012345678901234567890123456",
		Kind:      1,
		PubKey:    "sender12345678901234567890123456789012345678901234567890123456",
		CreatedAt: nostr.Timestamp(time.Now().Unix()),
		Tags: nostr.Tags{
			{"p", recipientPubkey},
		},
		Content: "Hello @recipient!",
	}

	// Trigger the event watcher
	watcher.OnEventSaved(context.Background(), event)

	// Give async notification time to process
	time.Sleep(100 * time.Millisecond)

	if deliveryCount != 1 {
		t.Errorf("expected 1 notification delivery, got %d", deliveryCount)
	}
}

func TestWrapEventNIP44(t *testing.T) {
	// Test the stub implementation
	event := &nostr.Event{
		ID:      "test12345678901234567890123456789012345678901234567890123456",
		Kind:    1,
		Content: "Test content",
	}

	wrapped, err := WrapEventNIP44(event, "privkey", "pubkey")
	if err != nil {
		t.Fatalf("failed to wrap event: %v", err)
	}

	// Should return JSON for now (stub implementation)
	var unwrapped nostr.Event
	if err := json.Unmarshal(wrapped, &unwrapped); err != nil {
		t.Fatalf("failed to unmarshal wrapped event: %v", err)
	}

	if unwrapped.ID != event.ID {
		t.Errorf("expected ID %s, got %s", event.ID, unwrapped.ID)
	}
}

func TestParseAuthChallenge(t *testing.T) {
	tests := []struct {
		name      string
		content   string
		wantSys   string
		wantToken string
		wantErr   bool
	}{
		{
			name:      "valid google",
			content:   "google:my-fcm-token",
			wantSys:   "google",
			wantToken: "my-fcm-token",
			wantErr:   false,
		},
		{
			name:      "valid apple",
			content:   "apple:my-apns-token",
			wantSys:   "apple",
			wantToken: "my-apns-token",
			wantErr:   false,
		},
		{
			name:      "valid unifiedpush",
			content:   "unifiedpush:https://push.example.com/endpoint",
			wantSys:   "unifiedpush",
			wantToken: "https://push.example.com/endpoint",
			wantErr:   false,
		},
		{
			name:    "invalid format - no colon",
			content: "googletoken",
			wantErr: true,
		},
		{
			name:    "unsupported system",
			content: "webpush:token",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := &nostr.Event{Content: tt.content}
			sys, token, err := parseAuthChallenge(event)

			if tt.wantErr {
				if err == nil {
					t.Error("expected error, got nil")
				}
				return
			}

			if err != nil {
				t.Errorf("unexpected error: %v", err)
				return
			}

			if sys != tt.wantSys {
				t.Errorf("expected system '%s', got '%s'", tt.wantSys, sys)
			}

			if token != tt.wantToken {
				t.Errorf("expected token '%s', got '%s'", tt.wantToken, token)
			}
		})
	}
}

func TestDefaultPushNotifyConfig(t *testing.T) {
	config := DefaultPushNotifyConfig()

	if config.Enabled {
		t.Error("expected disabled by default")
	}

	if config.MaxTokensPerPubkey != 5 {
		t.Errorf("expected MaxTokensPerPubkey=5, got %d", config.MaxTokensPerPubkey)
	}

	if config.MaxFailureCount != 3 {
		t.Errorf("expected MaxFailureCount=3, got %d", config.MaxFailureCount)
	}
}

func TestPushNotifyService_NotifyEvent_NoTokens(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled: true,
	}

	service := NewPushNotifyService(config)

	event := &nostr.Event{
		ID:   "test12345678901234567890123456789012345678901234567890123456",
		Kind: 1,
	}

	// Should not error when no tokens are registered
	err := service.NotifyEvent(context.Background(), event, "unknownpubkey")
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestPushNotifyService_FailureTracking(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:         true,
		FCMEnabled:      true,
		MaxFailureCount: 2,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	// Register token
	service.RegisterToken(pubkey, PushSystemGoogle, "test-token", nil)

	// Set up failing delivery
	service.SetFCMDelivery(func(token string, payload []byte) error {
		return errors.New("delivery failed")
	})

	event := &nostr.Event{
		ID:   "test12345678901234567890123456789012345678901234567890123456",
		Kind: 1,
	}

	// First failure
	service.NotifyEvent(context.Background(), event, pubkey)
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Fatal("token should still exist after 1 failure")
	}

	// Second failure should remove token
	service.NotifyEvent(context.Background(), event, pubkey)
	tokens = service.GetTokensForPubkey(pubkey)
	if len(tokens) != 0 {
		t.Error("token should be removed after max failures")
	}
}

func TestPushNotifyService_HandleUnregister(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	// First register a token
	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	service.RegisterToken(pubkey, PushSystemGoogle, "test-token-12345", nil)

	// Verify it exists
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Fatalf("expected 1 token before unregister, got %d", len(tokens))
	}

	// Create NIP-98 auth for DELETE
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "http://example.com/register"},
			{"method", "DELETE"},
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodDelete, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleUnregister(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	// Verify token was removed
	tokens = service.GetTokensForPubkey(pubkey)
	if len(tokens) != 0 {
		t.Errorf("expected 0 tokens after unregister, got %d", len(tokens))
	}
}

func TestNIP98Auth_InvalidKind(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	// Create auth event with wrong kind (22242 instead of 27235)
	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	authEvent := &nostr.Event{
		Kind:      22242, // Wrong kind - should be 27235
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "http://example.com/register"},
			{"method", "POST"},
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401 for wrong kind, got %d", rr.Code)
	}
}

func TestNIP98Auth_MissingURLTag(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	// Missing "u" tag
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"method", "POST"},
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401 for missing u tag, got %d", rr.Code)
	}
}

func TestNIP98Auth_URLMismatch(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	// URL in auth event doesn't match request URL (cross-endpoint attack)
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "http://example.com/other-endpoint"},
			{"method", "POST"},
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401 for URL mismatch, got %d", rr.Code)
	}
}

func TestNIP98Auth_MethodMismatch(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	// Method in auth event doesn't match request method
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "http://example.com/register"},
			{"method", "GET"}, // Wrong method
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401 for method mismatch, got %d", rr.Code)
	}
}

func TestNIP98Auth_ExpiredEvent(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	// Auth event from 2 minutes ago (expired)
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now() - 120, // 2 minutes ago
		Tags: nostr.Tags{
			{"u", "http://example.com/register"},
			{"method", "POST"},
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "example.com"
	req.Header.Set("Authorization", authHeader)

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected status 401 for expired event, got %d", rr.Code)
	}
}

func TestPushNotifyService_MemoryLeakPrevention(t *testing.T) {
	// Test that removing the last token cleans up the map entry
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	// Register and remove token
	service.RegisterToken(pubkey, PushSystemGoogle, "test-token", nil)
	service.RemoveToken(pubkey, "test-token")

	// Access the internal map to verify cleanup
	service.mu.RLock()
	_, exists := service.tokens[pubkey]
	service.mu.RUnlock()

	if exists {
		t.Error("expected pubkey entry to be removed when last token is removed")
	}
}

func TestPushNotifyService_ConfigValidation(t *testing.T) {
	// Test that MaxFailureCount=0 gets defaulted
	config := &PushNotifyConfig{
		Enabled:         true,
		MaxFailureCount: 0, // Invalid - should be defaulted to 3
	}

	service := NewPushNotifyService(config)

	// Check that it was corrected
	if service.config.MaxFailureCount != 3 {
		t.Errorf("expected MaxFailureCount to be defaulted to 3, got %d", service.config.MaxFailureCount)
	}

	// Test that MaxTokensPerPubkey=0 gets defaulted
	config2 := &PushNotifyConfig{
		Enabled:            true,
		MaxTokensPerPubkey: 0,
	}

	service2 := NewPushNotifyService(config2)

	if service2.config.MaxTokensPerPubkey != 5 {
		t.Errorf("expected MaxTokensPerPubkey to be defaulted to 5, got %d", service2.config.MaxTokensPerPubkey)
	}
}

func TestPushNotifyService_DataRaceSafety(t *testing.T) {
	// Test that GetTokensForPubkey returns a copy
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)
	pubkey := "ab12cd34ef56789012345678901234567890123456789012345678901234abcd"

	service.RegisterToken(pubkey, PushSystemGoogle, "test-token", []string{"wss://relay.example.com"})

	// Get tokens
	tokens1 := service.GetTokensForPubkey(pubkey)
	tokens2 := service.GetTokensForPubkey(pubkey)

	// Modify returned slice - should not affect internal state or other copies
	if len(tokens1) > 0 {
		tokens1[0].FailureCount = 999
		tokens1[0].Relays[0] = "modified"
	}

	// tokens2 should be unaffected
	if len(tokens2) > 0 {
		if tokens2[0].FailureCount != 0 {
			t.Error("modifying returned tokens affected other copies - data race vulnerability")
		}
		if tokens2[0].Relays[0] != "wss://relay.example.com" {
			t.Error("modifying returned token relays affected other copies - data race vulnerability")
		}
	}

	// Internal state should also be unaffected
	tokens3 := service.GetTokensForPubkey(pubkey)
	if len(tokens3) > 0 && tokens3[0].FailureCount != 0 {
		t.Error("modifying returned tokens affected internal state - data race vulnerability")
	}
}

func TestGetRequestURL(t *testing.T) {
	tests := []struct {
		name        string
		host        string
		path        string
		tls         bool
		headers     map[string]string
		expectedURL string
	}{
		{
			name:        "direct HTTP connection",
			host:        "example.com",
			path:        "/register",
			tls:         false,
			headers:     nil,
			expectedURL: "http://example.com/register",
		},
		{
			name:        "direct HTTPS connection",
			host:        "example.com",
			path:        "/register",
			tls:         true,
			headers:     nil,
			expectedURL: "https://example.com/register",
		},
		{
			name: "X-Forwarded-Proto HTTPS behind proxy",
			host: "example.com",
			path: "/register",
			tls:  false, // TLS terminated at proxy
			headers: map[string]string{
				"X-Forwarded-Proto": "https",
			},
			expectedURL: "https://example.com/register",
		},
		{
			name: "X-Forwarded-Host changes host",
			host: "internal-host:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"X-Forwarded-Proto": "https",
				"X-Forwarded-Host":  "api.example.com",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded header (RFC 7239) takes precedence",
			host: "internal-host:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded":         "proto=https; host=external.example.com",
				"X-Forwarded-Proto": "http", // Should be ignored
				"X-Forwarded-Host":  "wrong.example.com", // Should be ignored
			},
			expectedURL: "https://external.example.com/register",
		},
		{
			name: "Forwarded header with spaces",
			host: "localhost",
			path: "/api/push",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "for=192.168.1.1; proto=https; host=relay.nostr.com",
			},
			expectedURL: "https://relay.nostr.com/api/push",
		},
		{
			name: "X-Forwarded-Proto only (host from request)",
			host: "api.example.com",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"X-Forwarded-Proto": "https",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded with only proto",
			host: "api.example.com",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "proto=https",
			},
			expectedURL: "https://api.example.com/register",
		},
		// Multi-proxy comma-separated Forwarded header tests
		{
			name: "multi-proxy comma-separated Forwarded - use first entry",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "for=client; proto=https; host=api.example.com, for=proxy2; proto=http; host=internal",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "multi-proxy Forwarded with mixed data - host in second entry only",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				// First entry has proto but no host, second has host
				// We use first entry's proto and fall back to r.Host (since first entry has no host)
				"Forwarded": "for=client; proto=https, for=proxy; host=should-not-use",
			},
			expectedURL: "https://internal:8080/register",
		},
		{
			name: "multi-proxy Forwarded - avoid comma in quoted value confusion",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				// Comma inside quotes should not split entries
				"Forwarded": "for=\"client, special\"; proto=https; host=api.example.com",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "multi-proxy Forwarded - RFC 7239 first entry only (no proto/host in first)",
			host: "api.example.com",
			path: "/register",
			tls:  true, // TLS should be used as fallback since first entry has no proto
			headers: map[string]string{
				// RFC 7239: leftmost entry is client-facing, subsequent are proxy-to-proxy
				// First entry only has "for", second has proto/host (proxy-to-proxy hop)
				// We must NOT use the second entry; should fall back to TLS for scheme
				"Forwarded": "for=client, proto=https; host=internal-proxy",
			},
			expectedURL: "https://api.example.com/register", // Host from r.Host, scheme from TLS
		},
		{
			name: "multi-proxy Forwarded - RFC 7239 first entry only with X-Forwarded fallback",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				// First entry has only "for", second has proto/host (should be ignored)
				// Should fall back to X-Forwarded-* headers
				"Forwarded":         "for=client, proto=https; host=internal-proxy",
				"X-Forwarded-Proto": "https",
				"X-Forwarded-Host":  "api.example.com",
			},
			expectedURL: "https://api.example.com/register", // From X-Forwarded-* fallback
		},
		// Partial Forwarded header with X-Forwarded fallback tests
		{
			name: "Forwarded with only for - fallback to X-Forwarded-Proto",
			host: "api.example.com",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded":         "for=192.168.1.1",
				"X-Forwarded-Proto": "https",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded with only for - fallback to X-Forwarded-Host",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded":        "for=192.168.1.1",
				"X-Forwarded-Host": "api.example.com",
			},
			expectedURL: "http://api.example.com/register",
		},
		{
			name: "Forwarded with only for - fallback to both X-Forwarded headers",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded":         "for=192.168.1.1",
				"X-Forwarded-Proto": "https",
				"X-Forwarded-Host":  "api.example.com",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded with only for - fallback to TLS",
			host: "api.example.com",
			path: "/register",
			tls:  true,
			headers: map[string]string{
				"Forwarded": "for=192.168.1.1",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded with proto only - host fallback to X-Forwarded-Host",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded":        "proto=https",
				"X-Forwarded-Host": "api.example.com",
			},
			expectedURL: "https://api.example.com/register",
		},
		// Quoted values tests (RFC 7239)
		{
			name: "Forwarded with quoted proto value",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "proto=\"https\"; host=api.example.com",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded with quoted host value",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "proto=https; host=\"api.example.com\"",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded with both values quoted",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "for=\"client\"; proto=\"https\"; host=\"api.example.com\"",
			},
			expectedURL: "https://api.example.com/register",
		},
		{
			name: "Forwarded quoted value with spaces around quotes",
			host: "internal:8080",
			path: "/register",
			tls:  false,
			headers: map[string]string{
				"Forwarded": "proto= \"https\" ; host= \"api.example.com\" ",
			},
			expectedURL: "https://api.example.com/register",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, tt.path, nil)
			req.Host = tt.host

			// Set TLS state
			if tt.tls {
				req.TLS = &tls.ConnectionState{}
			}

			// Set headers
			for k, v := range tt.headers {
				req.Header.Set(k, v)
			}

			url := getRequestURL(req)
			if url != tt.expectedURL {
				t.Errorf("getRequestURL() = %q, want %q", url, tt.expectedURL)
			}
		})
	}
}

func TestHandleRegister_BehindTLSProxy(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	// Create a valid NIP-98 auth event with HTTPS URL (as client would sign)
	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	// Client signs with the external HTTPS URL
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "https://api.example.com/register"}, // HTTPS - what client sees
			{"method", "POST"},
		},
		Content: "google:test-token-proxy",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	// Request arrives at server over HTTP (TLS terminated at proxy)
	req := httptest.NewRequest(http.MethodPost, "/register", nil)
	req.Host = "api.example.com"
	req.TLS = nil // No TLS - terminated at proxy
	req.Header.Set("Authorization", authHeader)
	req.Header.Set("X-Forwarded-Proto", "https") // Proxy tells us original was HTTPS

	rr := httptest.NewRecorder()
	service.HandleRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200 with X-Forwarded-Proto, got %d: %s", rr.Code, rr.Body.String())
	}

	// Verify token was registered
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 1 {
		t.Errorf("expected 1 token, got %d", len(tokens))
	}
}

func TestHandleUnregister_BehindTLSProxy(t *testing.T) {
	config := &PushNotifyConfig{
		Enabled:    true,
		FCMEnabled: true,
	}

	service := NewPushNotifyService(config)

	// First register a token
	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)
	service.RegisterToken(pubkey, PushSystemGoogle, "test-token-proxy", nil)

	// Create NIP-98 auth for DELETE with HTTPS URL
	authEvent := &nostr.Event{
		Kind:      27235,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"u", "https://api.example.com/register"}, // HTTPS
			{"method", "DELETE"},
		},
		Content: "google:test-token-proxy",
	}
	authEvent.Sign(privkey)

	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodDelete, "/register", nil)
	req.Host = "api.example.com"
	req.TLS = nil // TLS terminated at proxy
	req.Header.Set("Authorization", authHeader)
	req.Header.Set("X-Forwarded-Proto", "https")

	rr := httptest.NewRecorder()
	service.HandleUnregister(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected status 200 with X-Forwarded-Proto, got %d: %s", rr.Code, rr.Body.String())
	}

	// Verify token was removed
	tokens := service.GetTokensForPubkey(pubkey)
	if len(tokens) != 0 {
		t.Errorf("expected 0 tokens after unregister, got %d", len(tokens))
	}
}

func TestSplitForwardedParts(t *testing.T) {
	tests := []struct {
		name     string
		header   string
		expected []string
	}{
		{
			name:     "simple",
			header:   "proto=https; host=example.com",
			expected: []string{"proto=https", " host=example.com"},
		},
		{
			name:     "with for",
			header:   "for=192.168.1.1; proto=https; host=example.com",
			expected: []string{"for=192.168.1.1", " proto=https", " host=example.com"},
		},
		{
			name:     "quoted value with semicolon",
			header:   `for="[2001:db8::1]"; proto=https`,
			expected: []string{`for="[2001:db8::1]"`, " proto=https"},
		},
		{
			name:     "single value",
			header:   "proto=https",
			expected: []string{"proto=https"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parts := splitForwardedParts(tt.header)
			if len(parts) != len(tt.expected) {
				t.Errorf("splitForwardedParts(%q) returned %d parts, want %d: %v", tt.header, len(parts), len(tt.expected), parts)
				return
			}
			for i, part := range parts {
				if part != tt.expected[i] {
					t.Errorf("splitForwardedParts(%q)[%d] = %q, want %q", tt.header, i, part, tt.expected[i])
				}
			}
		})
	}
}

func TestSplitForwardedEntries(t *testing.T) {
	tests := []struct {
		name     string
		header   string
		expected []string
	}{
		{
			name:     "single entry",
			header:   "proto=https; host=example.com",
			expected: []string{"proto=https; host=example.com"},
		},
		{
			name:     "multi-proxy comma-separated",
			header:   "for=client; proto=https; host=example.com, for=proxy2",
			expected: []string{"for=client; proto=https; host=example.com", " for=proxy2"},
		},
		{
			name:     "quoted value with comma inside",
			header:   `for="client, special"; proto=https`,
			expected: []string{`for="client, special"; proto=https`},
		},
		{
			name:     "three proxies",
			header:   "for=a, for=b, for=c",
			expected: []string{"for=a", " for=b", " for=c"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entries := splitForwardedEntries(tt.header)
			if len(entries) != len(tt.expected) {
				t.Errorf("splitForwardedEntries(%q) returned %d entries, want %d: %v", tt.header, len(entries), len(tt.expected), entries)
				return
			}
			for i, entry := range entries {
				if entry != tt.expected[i] {
					t.Errorf("splitForwardedEntries(%q)[%d] = %q, want %q", tt.header, i, entry, tt.expected[i])
				}
			}
		})
	}
}

func TestUnquoteValue(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"https", "https"},
		{`"https"`, "https"},
		{`"example.com"`, "example.com"},
		{" \"https\" ", "https"},
		{`"quoted, with comma"`, "quoted, with comma"},
		{`""`, ""},
		{"", ""},
		{`"unclosed`, `"unclosed`}, // malformed - return as-is
		{`unquoted"`, `unquoted"`}, // malformed - return as-is
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := unquoteValue(tt.input)
			if result != tt.expected {
				t.Errorf("unquoteValue(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestTrimSpace(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"  hello  ", "hello"},
		{"\thello\t", "hello"},
		{"hello", "hello"},
		{"  ", ""},
		{"", ""},
		{" \t hello world \t ", "hello world"},
	}

	for _, tt := range tests {
		result := trimSpace(tt.input)
		if result != tt.expected {
			t.Errorf("trimSpace(%q) = %q, want %q", tt.input, result, tt.expected)
		}
	}
}

