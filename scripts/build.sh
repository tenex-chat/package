#!/usr/bin/env bash
# scripts/build.sh — update submodules and rebuild native dependencies
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 [--relay] [--update-submodules] [--all]"
    echo ""
    echo "Options:"
    echo "  --relay              Rebuild the khatru-relay Go binary (arm64 + amd64)"
    echo "  --update-submodules  Pull each submodule to its latest remote commit"
    echo "  --all                --update-submodules + --relay"
    echo ""
    echo "With no options, defaults to --all."
    exit 0
}

OPT_RELAY=0
OPT_SUBMODULES=0

if [[ $# -eq 0 ]]; then
    OPT_RELAY=1
    OPT_SUBMODULES=1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --relay)             OPT_RELAY=1 ;;
        --update-submodules) OPT_SUBMODULES=1 ;;
        --all)               OPT_RELAY=1; OPT_SUBMODULES=1 ;;
        --help|-h)           usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 1. Update submodules
# ---------------------------------------------------------------------------
if [[ $OPT_SUBMODULES -eq 1 ]]; then
    echo "==> Updating git submodules..."
    cd "$ROOT_DIR"
    git submodule update --init --recursive
    git submodule foreach --recursive 'git fetch --tags origin'

    # Only fast-forward submodules that have no local uncommitted changes
    for module in deps/tui deps/backend; do
        if [[ -d "$ROOT_DIR/$module/.git" || -f "$ROOT_DIR/$module/.git" ]]; then
            if git -C "$ROOT_DIR/$module" diff --quiet HEAD; then
                echo "  Updating $module..."
                git submodule update --remote --merge "$module" || \
                    echo "  Warning: could not fast-forward $module — local changes present, skipping."
            else
                echo "  Skipping $module — has uncommitted local changes."
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# 2. Build khatru-relay
# ---------------------------------------------------------------------------
if [[ $OPT_RELAY -eq 1 ]]; then
    RELAY_DIR="$ROOT_DIR/relay"
    echo "==> Building khatru-relay..."

    if ! command -v go &>/dev/null; then
        echo "Error: 'go' not found in PATH. Install Go 1.21+ to build the relay."
        exit 1
    fi

    cd "$RELAY_DIR"
    make build

    echo "  arm64 binary: $(ls -lh dist/tenex-relay-arm64 | awk '{print $5, $9}')"
    if [[ -f dist/tenex-relay-x86_64 ]]; then
        echo "  amd64 binary: $(ls -lh dist/tenex-relay-x86_64 | awk '{print $5, $9}')"
    fi

    echo "==> khatru-relay build complete."
fi

echo "==> Done."
