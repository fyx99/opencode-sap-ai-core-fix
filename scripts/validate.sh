#!/usr/bin/env bash
#
# validate.sh — reproduce the opencode + SAP AI Core "Schema validation failed" bug
# and confirm the V3-package fix, against a live AI Core tenant.
#
# Usage:
#   export AICORE_SERVICE_KEY='{"clientid":"...","clientsecret":"...","url":"https://<tenant>.authentication.sap.hana.ondemand.com","serviceurls":{"AI_API_URL":"https://<host>.ml.hana.ondemand.com"}}'
#   export AICORE_RESOURCE_GROUP='default'
#   ./scripts/validate.sh [model]
#
# Default model: sap-ai-core/gpt-6.1-sol  (any RUNNING deployment works)
#
# It runs each case twice: once with the broken default (-v2) provider, once with the
# V3 provider, and greps for the schema error. Needs opencode on PATH (or ~/.opencode/bin).

set -uo pipefail

MODEL="${1:-sap-ai-core/gpt-6.1-sol}"

if command -v opencode >/dev/null 2>&1; then OC="$(command -v opencode)"
elif [ -x "$HOME/.opencode/bin/opencode" ]; then OC="$HOME/.opencode/bin/opencode"
else echo "ERROR: opencode not found" >&2; exit 1; fi

if [ -z "${AICORE_SERVICE_KEY:-}" ]; then
  echo "ERROR: set AICORE_SERVICE_KEY (and AICORE_RESOURCE_GROUP) first." >&2; exit 1
fi

echo "opencode: $("$OC" --version)   model: $MODEL"

# Register credentials with the background service (idempotent).
"$OC" service set env AICORE_SERVICE_KEY "$AICORE_SERVICE_KEY" >/dev/null
"$OC" service set env AICORE_RESOURCE_GROUP "${AICORE_RESOURCE_GROUP:-default}" >/dev/null
"$OC" service restart >/dev/null

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

run_case() {
  # $1 = label, $2 = npm package (empty = registry default -v2), $3 = prompt
  local label="$1" pkg="$2" prompt="$3"
  if [ -n "$pkg" ]; then
    cat > "$WORKDIR/opencode.json" <<EOF
{ "\$schema": "https://opencode.ai/config.json",
  "provider": { "sap-ai-core": { "npm": "$pkg" } } }
EOF
  else
    rm -f "$WORKDIR/opencode.json"
  fi
  local out
  out="$( cd "$WORKDIR" && timeout 180 "$OC" run --standalone --print-logs --log-level error \
            --auto -m "$MODEL" "$prompt" 2>&1 )"
  if grep -qiE "Schema validation failed|Failed to drain Session" <<<"$out"; then
    echo "  [$label] FAIL — schema validation error"
  else
    echo "  [$label] OK — no schema error"
  fi
}

echo
echo "== Case 1: simple reply =="
run_case "default -v2 (expect FAIL)" ""                            "reply with exactly: PONG"
run_case "V3 fix       (expect OK)"  "@jerome-benoit/sap-ai-provider" "reply with exactly: PONG"

echo
echo "== Case 2: tool-call turn =="
run_case "default -v2 (expect FAIL)" ""                            "Use the ls tool to list files here, then describe this directory in one sentence."
run_case "V3 fix       (expect OK)"  "@jerome-benoit/sap-ai-provider" "Use the ls tool to list files here, then describe this directory in one sentence."

echo
echo "Done. To apply the fix permanently, copy examples/opencode.json to ~/.config/opencode/opencode.json"
