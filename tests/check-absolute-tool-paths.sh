#!/usr/bin/env bash
# tests/check-absolute-tool-paths.sh — AXI-1972, scope item 1/FR62/AC56:
# "a script calling a guarded tool by absolute path is detected and fails
# the suite". The PATH-shim stubs (tests/stubs/) only intercept a BARE
# command name resolved through $PATH; a script that hardcodes
# /usr/bin/aws, /usr/bin/docker, etc. bypasses every stub and would, if
# ever actually run, reach the real binary. This is a static guard over
# the scripts the bats suite actually exercises under the stub harness.
#
# Scope deliberately excludes providers/scaleway/** and providers/onprem/**
# (not exercised by this harness) and rendered systemd unit text whose
# ExecStart/ExecStop directives correctly name the real on-box binary for
# production (ExecStart=/usr/bin/docker ... is systemd syntax, not a shell
# command this suite's stubs could intercept even in principle).
#
# Usage: tests/check-absolute-tool-paths.sh [<root>]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${TESTS_DIR}/.." && pwd)}"
cd "$ROOT"

# Deliberately does NOT include the legacy v1 Compose binary name: the
# project-wide policy (AXI-1971, tests/compose-call-sites.bats UT-INFRA-519)
# is that no in-scope file may even SPELL that name outside a *.yml
# filename or a comment, and any absolute-path/fallback shape reaching it
# is already caught there (UT-INFRA-510..520, 606) in more detail than a
# generic absolute-path scan could — duplicating the bare token here would
# itself violate that same policy.
GUARDED_TOOLS="aws docker psql curl ssh terraform git date dig systemctl scp rsync nc wget mongosh mongodump mongorestore"

mapfile -t FILES < <(
  {
    git -C "$ROOT" ls-files -- 'scripts/**/*.sh' 'scripts/*.sh' \
      'providers/aws/scripts/**/*.sh' 'providers/aws/scripts/*.sh' \
      'providers/aws/onbox/**/*.sh' 'providers/aws/onbox/*.sh' 2>/dev/null || true
  } | sort -u
)

# _code_only <line> — AXI-1977 close-out sweep item 4: returns <line> with
# any UNQUOTED trailing "# ..." comment removed (both a full-line comment
# and a trailing inline one). Tracks single- and double-quote state
# character by character so a literal "#" inside a quoted string (e.g. a
# path, a URL fragment, or a human comment ABOUT a "#") never truncates
# real code that follows it on the same line — only a "#" that is not
# inside an open quote starts a comment, matching the shell's own rule
# closely enough for this static scan's purpose.
_code_only() {
  local line="$1" i=0 c in_squote=0 in_dquote=0 out=""
  local len="${#line}"
  while [ "$i" -lt "$len" ]; do
    c="${line:$i:1}"
    if [ "$in_squote" -eq 1 ]; then
      [ "$c" = "'" ] && in_squote=0
      out="${out}${c}"
    elif [ "$in_dquote" -eq 1 ]; then
      if [ "$c" = '\' ] && [ "$((i + 1))" -lt "$len" ]; then
        out="${out}${c}${line:$((i + 1)):1}"
        i=$((i + 1))
      else
        [ "$c" = '"' ] && in_dquote=0
        out="${out}${c}"
      fi
    else
      case "$c" in
        "'") in_squote=1; out="${out}${c}" ;;
        '"') in_dquote=1; out="${out}${c}" ;;
        '#') break ;;
        *) out="${out}${c}" ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

status=0
for tool in $GUARDED_TOOLS; do
  for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    # A command-position absolute path to the tool: preceded by
    # whitespace/`;`/`&&`/`||`/`(`/start-of-line, never inside a comment
    # (full-line OR trailing inline — see _code_only above).
    while IFS=: read -r lineno content; do
      [ -n "$lineno" ] || continue
      case "$content" in
        *ExecStart=*"/${tool}"*|*ExecStop=*"/${tool}"*) continue ;;
      esac
      code="$(_code_only "$content")"
      case "$code" in
        *"/usr/local/bin/${tool}"*|*"/usr/bin/${tool}"*|*"/bin/${tool}"*) : ;;
        *) continue ;;
      esac
      echo "ERROR: ${f}:${lineno}: calls '${tool}' by absolute path — bypasses the PATH-shim stub (FR62/AC56): ${content}" >&2
      status=1
    done < <(grep -nE "(^|[[:space:];(]|&&|\|\|)(/usr/local/bin/|/usr/bin/|/bin/)${tool}([[:space:]]|\$)" "$f")
  done
done
exit "$status"
