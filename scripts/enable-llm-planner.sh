#!/usr/bin/env bash
# enable-llm-planner.sh
# ---------------------------------------------------------------------------
# Turn the guided-analysis LLM planner ON (or OFF) for the demo backend, WITHOUT
# committing the key, writing it into any tracked file, or passing it on the
# command line.
#
#   The Anthropic key is read from, in order:
#     1) $GUIDED_ANALYSIS_ANTHROPIC_API_KEY already in your environment
#     2) the line  GUIDED_ANALYSIS_ANTHROPIC_API_KEY=sk-ant-...  in
#        axiome-infra/.env  (gitignored — see .gitignore)
#   It is NEVER taken as an argument (that leaks to shell history / `ps`) and
#   NEVER written into a compose file: the runtime override references it as
#   ${GUIDED_ANALYSIS_ANTHROPIC_API_KEY}, which docker compose substitutes from
#   this script's exported shell env at `up` time only.
#
# Usage (from anywhere):
#   axiome-infra/scripts/enable-llm-planner.sh          # enable (provider=anthropic)
#   axiome-infra/scripts/enable-llm-planner.sh --off    # revert to deterministic
#
# Prereqs: the demo stack is up (make demo-up); Docker running.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve the infra dir from this script's own location, so it works from anywhere.
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${INFRA}/docker-compose.demo.yml"
PROJECT="axiome-demo"
SERVICE="backend"
SECRET_STORE="${INFRA}/.env"                              # gitignored, in the infra folder
OVERRIDE="${INFRA}/docker-compose.demo.llm.yml"           # gitignored (see .gitignore)
# AXI-1462 (W5 validation): Sonnet 5 — the P01–P61 plan contract needs a model
# that holds a 61-rule schema and its own arithmetic. Every rejection seen on the
# demo was structural bookkeeping, not statistics. Override per environment.
MODEL="${GUIDED_ANALYSIS_ANTHROPIC_MODEL:-claude-sonnet-5}"

# --- OFF: drop the override and recreate the backend on the base compose only ---
if [[ "${1:-}" == "--off" ]]; then
  rm -f "$OVERRIDE"
  docker compose -p "$PROJECT" -f "$COMPOSE" up -d "$SERVICE"
  echo "LLM planner DISABLED — demo backend back on the deterministic planner."
  exit 0
fi

# --- Resolve the key from env, else from the infra secret store (never from argv) ---
key="${GUIDED_ANALYSIS_ANTHROPIC_API_KEY:-}"
if [[ -z "$key" && -f "$SECRET_STORE" ]]; then
  key="$(grep -E '^GUIDED_ANALYSIS_ANTHROPIC_API_KEY=' "$SECRET_STORE" | tail -1 | cut -d= -f2- || true)"
fi
if [[ -z "$key" ]]; then
  cat >&2 <<MSG
No Anthropic key found. Provide a FRESH key (do not reuse the leaked one) by either:
  export GUIDED_ANALYSIS_ANTHROPIC_API_KEY=sk-ant-...            # this shell, or
  echo 'GUIDED_ANALYSIS_ANTHROPIC_API_KEY=sk-ant-...' >> ${SECRET_STORE}
then re-run this script.
MSG
  exit 1
fi
case "$key" in
  sk-ant-*) : ;;
  *) echo "warning: key does not look like an Anthropic key (expected sk-ant-*)" >&2 ;;
esac

# --- Runtime override: provider name (non-secret) + a REFERENCE to the key ---
#     The key value itself is never written here.
umask 077
cat > "$OVERRIDE" <<YML
services:
  ${SERVICE}:
    environment:
      GUIDED_ANALYSIS_LLM_PROVIDER: "anthropic"
      GUIDED_ANALYSIS_ANTHROPIC_MODEL: "${MODEL}"
      GUIDED_ANALYSIS_ANTHROPIC_API_KEY: "\${GUIDED_ANALYSIS_ANTHROPIC_API_KEY}"
YML

# --- Recreate ONLY the backend with base + override; export key for interpolation ---
export GUIDED_ANALYSIS_ANTHROPIC_API_KEY="$key"
docker compose -p "$PROJECT" -f "$COMPOSE" -f "$OVERRIDE" up -d "$SERVICE"

echo "LLM planner ENABLED on ${PROJECT} backend (provider=anthropic, model=${MODEL})."
echo "Key sourced from env/${SECRET_STORE#"$INFRA"/}; not committed, not in the compose file."
echo "Verify:  a /guided-analysis/plan response should now report  planner=anthropic  (falls back to deterministic on any API/parse error)."
