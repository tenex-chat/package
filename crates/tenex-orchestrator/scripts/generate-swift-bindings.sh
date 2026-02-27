#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

CRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$CRATE_DIR/../.." && pwd)"

# Generate bindings to a temp location, then copy into swift-bindings/.
TEMP_OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tenex-orchestrator-swift-bindings.XXXXXX")"
SWIFT_OUT_DIR="$CRATE_DIR/swift-bindings"
trap 'rm -rf "$TEMP_OUT_DIR"' EXIT

MACOS_LIB="$ROOT_DIR/target/release/libtenex_orchestrator.a"

platform_name="${PLATFORM_NAME:-macosx}"
default_bindgen_lib=""

case "$platform_name" in
  macosx|"")
    echo "Building macOS Rust library for bindings..." >&2
    cargo build --release -p tenex-orchestrator --manifest-path "$ROOT_DIR/Cargo.toml"
    default_bindgen_lib="$MACOS_LIB"
    ;;
  *)
    echo "Unknown PLATFORM_NAME '$platform_name'; defaulting to macOS bindings." >&2
    cargo build --release -p tenex-orchestrator --manifest-path "$ROOT_DIR/Cargo.toml"
    default_bindgen_lib="$MACOS_LIB"
    ;;
esac

mkdir -p "$SWIFT_OUT_DIR"

BINDGEN_LIB="${TENEX_ORCHESTRATOR_LIB_PATH:-$default_bindgen_lib}"

if [ ! -f "$BINDGEN_LIB" ]; then
  echo "Expected Rust library at $BINDGEN_LIB" >&2
  exit 1
fi

cargo run -p tenex-orchestrator --bin uniffi-bindgen \
  --manifest-path "$ROOT_DIR/Cargo.toml" \
  -- generate \
  --library "$BINDGEN_LIB" \
  --language swift \
  --out-dir "$TEMP_OUT_DIR"

if [ ! -f "$TEMP_OUT_DIR/tenex_orchestrator.swift" ]; then
  echo "Expected $TEMP_OUT_DIR/tenex_orchestrator.swift to be generated." >&2
  exit 1
fi

# Copy all generated files to swift-bindings/
cp "$TEMP_OUT_DIR/tenex_orchestrator.swift" "$SWIFT_OUT_DIR/tenex_orchestrator.swift"
cp "$TEMP_OUT_DIR/tenex_orchestratorFFI.h" "$SWIFT_OUT_DIR/tenex_orchestratorFFI.h"
cp "$TEMP_OUT_DIR/tenex_orchestratorFFI.modulemap" "$SWIFT_OUT_DIR/tenex_orchestratorFFI.modulemap"

echo "Swift bindings generated in swift-bindings/" >&2
