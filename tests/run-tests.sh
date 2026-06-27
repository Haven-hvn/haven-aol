#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
OFFLINE=""
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
  esac
done

echo "═══════════════════════════════════════════════════"
echo "  Haven-AOL Integration Test Suite"
echo "═══════════════════════════════════════════════════"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v python3 &>/dev/null; then
  echo "FAIL: python3 not found"
  exit 1
fi

if ! command -v node &>/dev/null; then
  echo "FAIL: node not found"
  exit 1
fi

# Verify Python package is importable
if ! python3 -c "from haven_aol import compute_derivation_input" 2>/dev/null; then
  echo "FAIL: Python haven-aol package not installed."
  echo "  Run: pip install maturin && pip install -e packages/python/rust_ext && pip install -e \"packages/python[dev]\""
  exit 1
fi

# Verify TypeScript package is built
if [ ! -f "$ROOT/packages/typescript/dist/derivation.js" ]; then
  echo "FAIL: TypeScript package not built."
  echo "  Run: cd packages/typescript && npm install && npm run build"
  exit 1
fi

echo "  ✓ Python package installed"
echo "  ✓ TypeScript package built"

if [ -z "$OFFLINE" ]; then
  # Check local replica
  if ! icp network status -e local &>/dev/null 2>&1; then
    echo ""
    echo "WARNING: Local ICP network not running."
    echo "  Canister tests (TC-3, TC-4) will be skipped."
    echo "  Start with: icp network start -d && icp deploy -e local"
    echo ""
    OFFLINE=1
  else
    echo "  ✓ Local ICP network running"
  fi
fi

echo ""

# Run tests
if [ -n "$OFFLINE" ]; then
  echo "Running OFFLINE tests (TC-1, TC-5, TC-6, TC-7, TC-8)..."
  echo ""
  OFFLINE=1 node --test "$SCRIPT_DIR/integration.test.mjs"
else
  echo "Running ALL tests..."
  echo ""
  node --test "$SCRIPT_DIR/integration.test.mjs"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Test suite complete"
echo "═══════════════════════════════════════════════════"
