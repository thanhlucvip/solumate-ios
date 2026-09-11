#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINGERPRINT_JS="$SCRIPT_DIR/secret-ios-solumate/fingerprint-ipa.js"

OUTPUT_PATH="${FINGERPRINT_OUTPUT_PATH:-$SCRIPT_DIR/fingerprints.txt}"
SIGN_IPA="${SIGN_IPA:-$SCRIPT_DIR/solumate.ipa}"
TROLLSTORE_IPA="${TROLLSTORE_IPA:-$SCRIPT_DIR/solumate-trollstore.ipa}"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./get-fingerprints.sh [output.txt] [solumate.ipa] [solumate-trollstore.ipa]

Defaults:
  output.txt              ./fingerprints.txt
  solumate.ipa            ./solumate.ipa
  solumate-trollstore.ipa ./solumate-trollstore.ipa
EOF
}

absolute_path() {
  case "$1" in
    /*)
      printf '%s\n' "$1"
      ;;
    *)
      printf '%s/%s\n' "$PWD" "$1"
      ;;
  esac
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$#" -gt 3 ]]; then
  usage
  exit 1
fi

if [[ "$#" -ge 1 ]]; then
  OUTPUT_PATH="$(absolute_path "$1")"
fi
if [[ "$#" -ge 2 ]]; then
  SIGN_IPA="$(absolute_path "$2")"
fi
if [[ "$#" -ge 3 ]]; then
  TROLLSTORE_IPA="$(absolute_path "$3")"
fi

if ! command -v node >/dev/null 2>&1; then
  printf 'Node.js not found in PATH.\n' >&2
  exit 1
fi
if [[ ! -f "$FINGERPRINT_JS" ]]; then
  printf 'Fingerprint script not found: %s\n' "$FINGERPRINT_JS" >&2
  exit 1
fi
if [[ ! -f "$SIGN_IPA" ]]; then
  printf 'Signed IPA not found: %s\n' "$SIGN_IPA" >&2
  exit 1
fi
if [[ ! -f "$TROLLSTORE_IPA" ]]; then
  printf 'TrollStore IPA not found: %s\n' "$TROLLSTORE_IPA" >&2
  exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"
TEMP_OUTPUT="$(mktemp "$OUTPUT_DIR/.fingerprints.XXXXXX")"
trap 'rm -f "$TEMP_OUTPUT"' EXIT

{
  printf '# Solumate build fingerprints\n'
  printf '# Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  node "$FINGERPRINT_JS" "$SIGN_IPA" "$TROLLSTORE_IPA"
} > "$TEMP_OUTPUT"

mv -f "$TEMP_OUTPUT" "$OUTPUT_PATH"
trap - EXIT

printf 'Fingerprint TXT: %s\n' "$OUTPUT_PATH"
sed -n '1,8p' "$OUTPUT_PATH"
