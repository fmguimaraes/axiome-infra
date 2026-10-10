#!/usr/bin/env bash
# scripts/lib/compose-resolve.sh — the ONE shared Docker Compose v2 resolver
# (AXI-1971, FR54). Sourced by every script that runs Compose for the
# local/demo/worktree stacks, and invoked directly by the root Makefile.
#
# Why this exists (epic AXI-1944 incident, 2026-10): the Makefile used to
# auto-detect Compose with `$(shell docker compose version … || echo
# "docker-compose")` — a failed v2 probe fell back to the literal name of
# the legacy v1 binary, which has no stub in a test harness and a known
# data-corrupting bug against modern image config (`KeyError:
# 'ContainerConfig'`). It stopped and renamed three real demo containers.
# AXI-1952/AXI-1955 closed the Makefile's own fallback and rejected an
# EXACT-match `DOCKER_COMPOSE=docker-compose` override, but (a) every other
# script that runs Compose still hardcoded "docker compose" independently
# (no shared place to add the same guard), and (b) the exact-match check let
# `DOCKER_COMPOSE=/usr/bin/docker-compose` or `docker-compose -f x` straight
# through (AXI-1955 follow-up). This file is the one place that decision
# lives now.
#
# Contract:
#   - Compose v2 ("docker compose") only. The legacy v1 binary
#     ("docker-compose") is NEVER accepted, whether it is the thing found on
#     PATH by default, or named (with or without a path or extra arguments)
#     through the DOCKER_COMPOSE override.
#   - On refusal: no Compose or Compose-adjacent command is ever run; the
#     caller gets back a non-zero result and ONE truthful line (in
#     COMPOSE_RESOLVE_ERROR, library mode; on stderr, CLI mode) naming what
#     was found and the remedy.
#
# Usage as a sourced library (bash):
#   . ".../scripts/lib/compose-resolve.sh"
#   compose_resolve || die "${COMPOSE_RESOLVE_ERROR}"
#   # on success: $COMPOSE_ARGS is a bash array ready to prefix a Compose
#   # call, e.g. "${COMPOSE_ARGS[@]}" -p "$PROJECT" -f "$FILE" up -d
#
# Usage as a CLI (what the Makefile calls):
#   DOCKER_COMPOSE="$value_or_empty" scripts/lib/compose-resolve.sh
#   # prints the resolved command to stdout and exits 0, OR prints the
#   # refusal to stderr, prints nothing to stdout, and exits 1.

# compose_resolve — sets COMPOSE_ARGS (array) and COMPOSE_RESOLVE_ERROR
# (string); returns 0 on a usable Compose v2, 1 on refusal. Never runs
# `docker-compose` (v1) itself to find out what it is — the basename check
# below is purely textual.
compose_resolve() {
  local candidate="${DOCKER_COMPOSE:-}" arr base
  COMPOSE_ARGS=()
  COMPOSE_RESOLVE_ERROR=""

  if [ -n "${candidate}" ]; then
    # Split exactly ONCE, into the very array that would be executed if we
    # accept it — never re-derive "the first token" from the raw string by
    # any other means (that produced AXI-1971's bounce #1: leading
    # whitespace, `sudo …`, `env X=1 …`, and a path-decorated v1 binary all
    # disagreed with this split and slipped through a separate textual
    # check). Default IFS (space/tab/newline) matches what `read -r -a`
    # below would otherwise do, so there is only one notion of "the words".
    read -r -a arr <<< "${candidate}"

    if [ "${#arr[@]}" -eq 0 ]; then
      COMPOSE_RESOLVE_ERROR="DOCKER_COMPOSE=\"${candidate}\" has no command in it (blank/whitespace-only) — refused. Set DOCKER_COMPOSE=\"docker compose\" (v2), or unset DOCKER_COMPOSE to let this resolver probe for v2 itself. Nothing was run."
      return 1
    fi

    base="${arr[0]##*/}"             # basename of the first word, path stripped
    if [ "${base}" != "docker" ] || [ "${#arr[@]}" -lt 2 ] || [ "${arr[1]}" != "compose" ]; then
      COMPOSE_RESOLVE_ERROR="DOCKER_COMPOSE=\"${candidate}\" is not shaped like a Compose v2 command — refused. The only accepted shape is: a path ending in 'docker', immediately followed by the literal word 'compose', then optional arguments (e.g. DOCKER_COMPOSE=\"docker compose\" or DOCKER_COMPOSE=\"/usr/bin/docker compose --ansi never\"). This closes every indirection we've seen reach the legacy v1 binary — a bare path naming the legacy v1 binary, a 'sudo'/'env VAR=…' prefix, or anything else that isn't literally 'docker compose' — by requiring the exact accepted shape rather than denying each one by name. The legacy v1 binary (docker-compose) is not supported here — see AXI-1952/AXI-1955/AXI-1971. Nothing was run."
      return 1
    fi

    COMPOSE_ARGS=("${arr[@]}")
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_ARGS=(docker compose)
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    COMPOSE_RESOLVE_ERROR="Docker Compose v2 not found (\`docker compose version\` failed). Install Docker Compose v2, or set DOCKER_COMPOSE=\"<v2 command>\" explicitly. The legacy docker-compose v1 binary is not supported here — see AXI-1952/AXI-1955/AXI-1971. Nothing was run."
  else
    COMPOSE_RESOLVE_ERROR="Docker Compose v2 not found (the \`docker\` binary itself is not on PATH, so \`docker compose\` cannot run). Install Docker with the Compose v2 plugin, or set DOCKER_COMPOSE=\"<v2 command>\" explicitly. The legacy docker-compose v1 binary is not supported here — see AXI-1952/AXI-1955/AXI-1971. Nothing was run."
  fi
  return 1
}

# CLI mode: only when this file is executed directly, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if compose_resolve; then
    printf '%s\n' "${COMPOSE_ARGS[*]}"
    exit 0
  fi
  printf '%s\n' "${COMPOSE_RESOLVE_ERROR}" >&2
  exit 1
fi
