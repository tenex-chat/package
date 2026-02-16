package main

import (
	"context"
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

	// Create a valid NIP-98 auth event
	privkey := nostr.GeneratePrivateKey()
	pubkey, _ := nostr.GetPublicKey(privkey)

	authEvent := &nostr.Event{
		Kind:      22242,
		PubKey:    pubkey,
		CreatedAt: nostr.Now(),
		Tags: nostr.Tags{
			{"relay", "wss://relay.example.com"},
		},
		Content: "google:test-token-12345",
	}
	authEvent.Sign(privkey)

	// Encode as base64 for NIP-98 header
	eventJSON, _ := json.Marshal(authEvent)
	authHeader := "Nostr " + base64.StdEncoding.EncodeToString(eventJSON)

	req := httptest.NewRequest(http.MethodPost, "/register", nil)
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
	storage, _ := NewStorage("/tmp/test-event-watcher-storage.json")
	defer storage.Close()

	watcher := NewEventWatcherService(pushService, storage)

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

