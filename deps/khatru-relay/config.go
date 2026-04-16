package main

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/nbd-wtf/go-nostr"
)

// Config represents the relay configuration
type Config struct {
	Port        int              `json:"port"`
	BindAddress string           `json:"bind_address"`
	DataDir     string           `json:"data_dir"`
	NIP11       NIP11Config      `json:"nip11"`
	Limits      LimitsConfig     `json:"limits"`
	Negentropy  NegentropyConfig `json:"negentropy"`
	Auth        AuthConfig       `json:"auth"`
}

// NIP11Config contains all NIP-11 relay information document fields
type NIP11Config struct {
	Name          string `json:"name"`
	Description   string `json:"description"`
	Pubkey        string `json:"pubkey"`
	Contact       string `json:"contact"`
	SupportedNIPs []int  `json:"supported_nips"`
	Software      string `json:"software"`
	Version       string `json:"version"`
}

// LimitsConfig contains relay limits
type LimitsConfig struct {
	MaxMessageLength  int `json:"max_message_length"`
	MaxSubscriptions  int `json:"max_subscriptions"`
	MaxFilters        int `json:"max_filters"`
	MaxEventTags      int `json:"max_event_tags"`
	MaxContentLength  int `json:"max_content_length"`
}

// NegentropyConfig contains negentropy sync settings
type NegentropyConfig struct {
	Enabled bool `json:"enabled"`
}

// AuthConfig contains NIP-42 authentication settings
type AuthConfig struct {
	// Enabled controls whether NIP-42 auth is required
	Enabled bool `json:"enabled"`
	// OwnerPubkey is the primary owner pubkey (always authorized)
	OwnerPubkey string `json:"owner_pubkey"`
	// WhitelistedPubkeys are additional pubkeys that are always authorized
	WhitelistedPubkeys []string `json:"whitelisted_pubkeys"`
	// BackendPrivateKey is the TENEX backend private key (hex); pubkey is derived from it
	BackendPrivateKey string `json:"backend_private_key"`
	// BackendPubkey is derived from BackendPrivateKey (populated after loading config)
	BackendPubkey string `json:"-"`
	// SyncRelays are relays to subscribe to for fetching 24010 events
	SyncRelays []string `json:"sync_relays"`
}

// DefaultConfig returns the default configuration
func DefaultConfig() *Config {
	return &Config{
		Port:        7777,
		BindAddress: "127.0.0.1",
		DataDir:     expandPath("~/.tenex/relay/data"),
		NIP11: NIP11Config{
			Name:          "TENEX Local Relay",
			Description:   "Local Nostr relay for TENEX",
			Pubkey:        "",
			Contact:       "",
			SupportedNIPs: []int{1, 2, 4, 9, 11, 12, 16, 20, 22, 33, 40, 42, 77},
			Software:      "tenex-khatru-relay",
			Version:       "0.1.0",
		},
		Limits: LimitsConfig{
			MaxMessageLength: 524288,
			MaxSubscriptions: 100,
			MaxFilters:       50,
			MaxEventTags:     2500,
			MaxContentLength: 102400,
		},
		Negentropy: NegentropyConfig{
			Enabled: true,
		},
		Auth: AuthConfig{
			Enabled:           false,
			OwnerPubkey:       "",
			WhitelistedPubkeys: []string{},
			BackendPrivateKey: "",
			BackendPubkey:     "",
			SyncRelays:        []string{},
		},
	}
}

// LoadConfig loads configuration from the given path
// If the file doesn't exist, it returns the default config
func LoadConfig(path string) (*Config, error) {
	path = expandPath(path)

	// Check if config file exists
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return DefaultConfig(), nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	// Start with defaults and overlay loaded config
	config := DefaultConfig()
	if err := json.Unmarshal(data, config); err != nil {
		return nil, err
	}

	// Expand paths
	config.DataDir = expandPath(config.DataDir)

	// Derive backend pubkey from private key if provided
	if config.Auth.BackendPrivateKey != "" {
		pubkey, err := derivePublicKey(config.Auth.BackendPrivateKey)
		if err != nil {
			// SECURITY: If auth is enabled and backend key is invalid, fail fast
			if config.Auth.Enabled {
				return nil, errors.New("auth enabled but backend_private_key is invalid: " + err.Error())
			}
			// Auth disabled, log warning but continue
			// Note: This means 24010 sync won't work, but relay can still function
		} else {
			config.Auth.BackendPubkey = pubkey
		}
	}

	// Validate
	if err := config.Validate(); err != nil {
		return nil, err
	}

	return config, nil
}

// Validate checks if the configuration is valid
func (c *Config) Validate() error {
	if c.Port < 1 || c.Port > 65535 {
		return errors.New("port must be between 1 and 65535")
	}

	if c.DataDir == "" {
		return errors.New("data_dir cannot be empty")
	}

	// SECURITY: If auth is enabled, owner_pubkey must be set to prevent lockout
	if c.Auth.Enabled && c.Auth.OwnerPubkey == "" {
		return errors.New("auth.owner_pubkey is required when auth is enabled (prevents lockout)")
	}

	// Validate owner pubkey format if provided
	if c.Auth.OwnerPubkey != "" && len(c.Auth.OwnerPubkey) != 64 {
		return errors.New("auth.owner_pubkey must be a 64-character hex pubkey")
	}

	return nil
}

// EnsureDataDir creates the data directory if it doesn't exist
func (c *Config) EnsureDataDir() error {
	return os.MkdirAll(c.DataDir, 0755)
}

// expandPath expands ~ to the user's home directory
func expandPath(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return path
		}
		return filepath.Join(home, path[2:])
	}
	return path
}

// derivePublicKey derives a Nostr pubkey (hex) from a hex private key
func derivePublicKey(hexPrivateKey string) (string, error) {
	if len(hexPrivateKey) != 64 {
		return "", errors.New("private key must be 64 hex characters")
	}

	privKeyBytes, err := hex.DecodeString(hexPrivateKey)
	if err != nil {
		return "", err
	}

	// Use go-nostr's built-in key generation
	pk, err := nostr.GetPublicKey(hex.EncodeToString(privKeyBytes))
	if err != nil {
		return "", err
	}

	return pk, nil
}
