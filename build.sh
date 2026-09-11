#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

TROLLSTORE_SCRIPT="$ROOT_DIR/WDA-trollstore/Scripts/build-ios15-solumate-unsigned-ipa.sh"
SIGN_SCRIPT="$ROOT_DIR/WDA-sign/Scripts/build-ios15-solumate-unsigned-ipa.sh"
FINGERPRINT_TXT_SCRIPT="$ROOT_DIR/get-fingerprints.sh"
TROLLSTORE_IPA="${TROLLSTORE_IPA:-$ROOT_DIR/solumate-trollstore.ipa}"
SIGN_IPA="${SIGN_IPA:-$ROOT_DIR/solumate.ipa}"

run_build() {
  local label="$1"
  local script="$2"
  local output="$3"

  if [[ ! -f "$script" ]]; then
    printf 'Missing build script: %s\n' "$script" >&2
    exit 1
  fi

  printf '\n==> %s\n' "$label"
  OUTPUT_IPA_PATH="$output" bash "$script"

  if [[ ! -f "$output" ]]; then
    printf 'Expected IPA not found: %s\n' "$output" >&2
    exit 1
  fi

  printf '    IPA ready: %s\n' "$output"
}

rm -f "$TROLLSTORE_IPA" "$SIGN_IPA"

run_build "Building TrollStore IPA" "$TROLLSTORE_SCRIPT" "$TROLLSTORE_IPA"
run_build "Building signed IPA" "$SIGN_SCRIPT" "$SIGN_IPA"

printf '\nDone.\n'
printf 'TrollStore IPA: %s\n' "$TROLLSTORE_IPA"
printf 'Signed IPA: %s\n' "$SIGN_IPA"
printf '\nFingerprint extraction is manual:\n'
printf '  %s %s %s %s\n' \
  "$FINGERPRINT_TXT_SCRIPT" \
  "$ROOT_DIR/fingerprints.txt" \
  "$SIGN_IPA" \
  "$TROLLSTORE_IPA"
