#!/usr/bin/env bash
# scripts/asset-sync.sh — AXI-1950 (epic AXI-1944 decision 8, FR11/EC9/AC9/AC32).
#
# Delivers the versioned source under providers/aws/onbox/ (the compose
# definition, the boot wrapper, and this script + refresh-env.sh themselves)
# to an existing box, with checksum verification and an atomic swap. One
# implementation, two modes:
#
#   asset-sync.sh pull    <s3-prefix> <dest-dir>
#   asset-sync.sh publish <repo-root> <s3-prefix> [<manifest-source-file>]
#
# pull: downloads <s3-prefix>/manifest.sha256, validates every listed path,
# downloads every file it lists, verifies every checksum, validates
# docker-compose.yml (if present among the downloaded files) with
# `docker compose config -q`, and only then installs every file into
# <dest-dir> as a single all-or-nothing operation (keeping each previous
# copy as "<file>.prev"). A failure at any step before install leaves
# <dest-dir> completely untouched; a failure DURING install restores every
# file already replaced in that install back to its previous copy — and
# touches NO "<file>.prev" at all, so a pre-existing one keeps its own
# (older) content byte-for-byte — so <dest-dir> is never left with a mixed
# set (FR49/AC42). When every manifest file already matches what is
# installed AND the installed manifest.sha256 bookkeeping copy matches
# too, nothing is written at all ("already current"); when the files
# match but only that bookkeeping copy is stale, ONLY it is rewritten
# ("repaired").
#
# publish: builds a manifest.sha256 from a small "<repo-relative-src>:
# <dest-relative-path>" manifest-source file (default
# providers/aws/onbox/publish-manifest.txt, resolved against <repo-root>) and
# uploads every listed file plus the manifest to <s3-prefix>. Operator/CI
# side only — this story never runs it against a real bucket.
#
# AXI-1969 (FR48/AC41): every manifest path is validated BEFORE any listed
# file is fetched — a manifest with one absolute path, or one containing a
# ".." segment (or an empty path), is rejected as a whole: nothing is
# fetched, nothing is installed, and the offending entry is named.
#
# AXI-1969 review follow-up — install is implemented as a snapshot/commit:
# pass 1 copies every currently-installed file into a STAGING-side snapshot
# (dest-dir, including any existing "<file>.prev", is read-only here); pass
# 2 installs every staged file, tracking what it replaced; pass 3 — reached
# ONLY if pass 2 fully succeeds — rotates each snapshot into "<file>.prev".
# A failure in pass 1 or 2 returns before pass 3 ever runs, so dest-dir's
# own "<file>.prev" files are never touched on a failed run — restoring
# "already replaced" files uses the pass-1 snapshot, never dest's ".prev".
#
# Exit codes (pull):
#   0  installed, confirmed already current, or repaired a stale manifest
#       bookkeeping copy (nothing else written)
#   2  manifest or a listed file could not be fetched — existing assets kept
#   3  a downloaded file's checksum does not match the manifest — nothing installed
#   4  docker-compose.yml failed `docker compose config -q` — nothing installed
#   5  a manifest entry's path is absolute, empty, or contains a ".."
#       segment — nothing installed, nothing even fetched for that entry (FR48)
#   6  install failed partway through — every file already replaced in this
#       install was restored to its previous copy; nothing left mixed (FR49)
#   1  usage error
#
# NFR3: never prints a secret — this script touches no secret value (it
# copies files; .env refresh is scripts/refresh-env.sh's job).
set -euo pipefail

MANIFEST_NAME="manifest.sha256"
DEFAULT_MANIFEST_SOURCE="providers/aws/onbox/publish-manifest.txt"

usage() {
  echo "usage: asset-sync.sh pull <s3-prefix> <dest-dir>" >&2
  echo "       asset-sync.sh publish <repo-root> <s3-prefix> [<manifest-source-file>]" >&2
  exit 1
}

# manifest line shape: "<sha256>  <relpath>" (sha256sum -c compatible, two spaces).
manifest_sha() { printf '%s' "${1%%  *}"; }
manifest_rel() { printf '%s' "${1#*  }"; }

# is_safe_rel_path <rel> — true (0) iff <rel> is non-empty, not absolute,
# and has no ".." path segment anywhere (leading, middle, or trailing).
# Wrapping with leading/trailing slashes before the substring test turns
# "every segment" into one simple, unambiguous "/../ " search — no segment
# splitting, no off-by-one at the string's own boundaries.
is_safe_rel_path() {
  local rel="$1"
  case "$rel" in
    ""|/*) return 1 ;;
  esac
  case "/${rel}/" in
    */../*) return 1 ;;
  esac
  return 0
}

# validate_manifest_paths <staging> — checks every manifest entry's relpath
# BEFORE anything is fetched or installed (FR48/AC41). Prints the offending
# entry and returns non-zero on the first unsafe one; returns 0 once the
# WHOLE manifest has been checked clean.
validate_manifest_paths() {
  local staging="$1" line rel
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel="$(manifest_rel "$line")"
    if ! is_safe_rel_path "$rel"; then
      echo "FAIL asset-sync: manifest entry has an unsafe path: '${rel}' — nothing installed" >&2
      return 1
    fi
  done < "${staging}/${MANIFEST_NAME}"
  return 0
}

fetch_manifest() {
  local prefix="$1" staging="$2"
  aws s3 cp "${prefix%/}/${MANIFEST_NAME}" "${staging}/${MANIFEST_NAME}" >/dev/null 2>&1
}

fetch_listed_files() {
  local prefix="$1" staging="$2" line rel dest_path
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel="$(manifest_rel "$line")"
    dest_path="${staging}/${rel}"
    mkdir -p "$(dirname "$dest_path")"
    aws s3 cp "${prefix%/}/${rel}" "$dest_path" >/dev/null 2>&1 || return 1
  done < "${staging}/${MANIFEST_NAME}"
}

verify_checksums() {
  local staging="$1" line sha rel actual
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sha="$(manifest_sha "$line")"
    rel="$(manifest_rel "$line")"
    actual="$(sha256sum "${staging}/${rel}" | awk '{print $1}')"
    [ "$actual" = "$sha" ] || return 1
  done < "${staging}/${MANIFEST_NAME}"
}

validate_compose() {
  local staging="$1"
  [ -f "${staging}/docker-compose.yml" ] || return 0
  docker compose -f "${staging}/docker-compose.yml" config -q
}

# all_files_current <staging> <dest> — true (0) iff every manifest-listed
# FILE is already installed at <dest> with a matching sha256 (FR49: "when
# every installed file already matches the manifest, write nothing"). Does
# NOT look at the manifest.sha256 bookkeeping copy itself — see
# manifest_copy_current below, which is the other half of "already
# current".
all_files_current() {
  local staging="$1" dest="$2" line sha rel actual
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sha="$(manifest_sha "$line")"
    rel="$(manifest_rel "$line")"
    [ -f "${dest}/${rel}" ] || return 1
    actual="$(sha256sum "${dest}/${rel}" | awk '{print $1}')"
    [ "$actual" = "$sha" ] || return 1
  done < "${staging}/${MANIFEST_NAME}"
  return 0
}

# manifest_copy_current <staging> <dest> — true (0) iff the installed
# manifest.sha256 bookkeeping copy is byte-identical to the one just
# fetched and verified. Checked SEPARATELY from all_files_current: a prior
# run can leave the files correct but the bookkeeping copy stale (e.g. its
# own write failed, see install_staged_files's final step) — review
# follow-up #1 (AXI-1969): "already current" must not paper over that.
manifest_copy_current() {
  local staging="$1" dest="$2"
  [ -f "${dest}/${MANIFEST_NAME}" ] && cmp -s "${staging}/${MANIFEST_NAME}" "${dest}/${MANIFEST_NAME}"
}

# restore_replaced <snap_dir> <dest> <rel>... — undoes install for exactly
# the relpaths named, using the PASS-1 SNAPSHOT taken by
# install_staged_files below — NEVER <dest>'s own "<file>.prev", which this
# whole call chain never touches on a failed run: a previously-existing
# file goes back to its snapshotted (pre-this-run) content; a file that
# did not exist before this install is removed. Used only when install
# fails partway, to put <dest> back at its state before THIS install
# began — "<file>.prev" included (review follow-up #2, AXI-1969).
restore_replaced() {
  local snap_dir="$1" dest="$2" rel dest_path
  shift 2
  for rel in "$@"; do
    dest_path="${dest}/${rel}"
    if [ -f "${snap_dir}/${rel}" ]; then
      cp -p "${snap_dir}/${rel}" "$dest_path"
    else
      rm -f "$dest_path"
    fi
  done
}

# install_staged_files <staging> <dest> — all-or-nothing (FR49/AC42), in
# three passes:
#
#   1. SNAPSHOT every currently-installed file into <staging>/.rollback/.
#      <dest> itself — including any existing "<file>.prev" — is read-only
#      in this pass; nothing is written to it yet.
#   2. INSTALL every staged file, tracking what this call has replaced so
#      far. On any failure, restore_replaced undoes exactly those files
#      from the pass-1 snapshot and returns non-zero — <dest>'s own
#      "<file>.prev" files were never touched, so a pre-existing one keeps
#      its own (older) content untouched (review follow-up #2).
#   3. COMMIT — reached ONLY if every file installed — rotates each pass-1
#      snapshot into "<file>.prev" (the run succeeded as a whole, so the
#      bookkeeping is now allowed to move on) and writes the new
#      manifest.sha256.
install_staged_files() {
  local staging="$1" dest="$2" line rel dest_path snap_dir
  snap_dir="${staging}/.rollback"
  local -a replaced=()
  mkdir -p "$snap_dir"

  # Pass 1: snapshot every currently-installed file (read-only on <dest>).
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel="$(manifest_rel "$line")"
    dest_path="${dest}/${rel}"
    if [ -f "$dest_path" ]; then
      mkdir -p "$(dirname "${snap_dir}/${rel}")" || {
        echo "FAIL asset-sync: could not prepare a rollback snapshot for '${rel}' — nothing installed" >&2
        return 6
      }
      cp -p "$dest_path" "${snap_dir}/${rel}" || {
        echo "FAIL asset-sync: could not snapshot '${rel}' before install — nothing installed" >&2
        return 6
      }
    fi
  done < "${staging}/${MANIFEST_NAME}"

  # Pass 2: install every staged file.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel="$(manifest_rel "$line")"
    dest_path="${dest}/${rel}"
    mkdir -p "$(dirname "$dest_path")" || {
      echo "FAIL asset-sync: could not create '$(dirname "$dest_path")' — restoring ${#replaced[@]} already-installed file(s) to their previous copy" >&2
      restore_replaced "$snap_dir" "$dest" "${replaced[@]}" || true
      return 6
    }
    if ! mv "${staging}/${rel}" "$dest_path"; then
      echo "FAIL asset-sync: failed to install '${rel}' — restoring ${#replaced[@]} already-installed file(s) to their previous copy" >&2
      restore_replaced "$snap_dir" "$dest" "${replaced[@]}" || true
      return 6
    fi
    replaced+=("$rel")
  done < "${staging}/${MANIFEST_NAME}"

  # Pass 3: commit. Every snapshot taken in pass 1 becomes the new
  # "<file>.prev"; a file with no snapshot (new in this manifest) correctly
  # ends up with no ".prev" at all.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel="$(manifest_rel "$line")"
    [ -f "${snap_dir}/${rel}" ] && mv -f "${snap_dir}/${rel}" "${dest}/${rel}.prev"
  done < "${staging}/${MANIFEST_NAME}"

  # Every listed file is installed at this point; only the manifest copy
  # itself is left. A failure here is reported rather than silently losing
  # track of what is actually on disk (it does NOT roll back the files
  # above — they are correct and match the manifest already copied into
  # staging; only the on-disk manifest.sha256 bookkeeping copy failed —
  # a later `already_current`-family check will offer to repair it, see
  # do_pull).
  cp "${staging}/${MANIFEST_NAME}" "${dest}/${MANIFEST_NAME}" || {
    echo "FAIL asset-sync: installed ${#replaced[@]} file(s) but could not write ${dest}/${MANIFEST_NAME} — rerun asset-sync" >&2
    return 6
  }
}

# Fetches + validates paths + verifies + validates into $2 (an already-
# created staging dir). Returns 0 only when it is safe to install; a
# non-zero return means $2 is left exactly as the caller handed it —
# do_pull never installs on failure.
stage_and_verify() {
  local prefix="$1" staging="$2"
  fetch_manifest "$prefix" "$staging" || {
    echo "WARN asset-sync: manifest unreachable at ${prefix} — keeping existing assets" >&2
    return 2
  }
  validate_manifest_paths "$staging" || return 5
  fetch_listed_files "$prefix" "$staging" || {
    echo "WARN asset-sync: a listed file could not be fetched from ${prefix} — keeping existing assets" >&2
    return 2
  }
  verify_checksums "$staging" || {
    echo "FAIL asset-sync: checksum mismatch against ${MANIFEST_NAME} — nothing installed" >&2
    return 3
  }
  validate_compose "$staging" || {
    echo "FAIL asset-sync: docker-compose.yml failed validation — nothing installed" >&2
    return 4
  }
}

do_pull() {
  local prefix="$1" dest="$2" staging rc
  mkdir -p "$dest"
  staging="$(mktemp -d "${dest}/.onbox-staging.XXXXXX")"
  # Double-quoted so "${staging}" expands NOW to a literal path (see
  # do_publish's trap below for why single-quoting it would be wrong) —
  # armed immediately so an unexpected abort (not just the handled error
  # paths below) still removes the staging dir. Left armed for the
  # remainder of the process — never disarmed, never replaced by a manual
  # rm -rf after the fact: disarming the trap and then cleaning up
  # explicitly would open a real window where a signal arriving between
  # the disarm and the manual rm -rf hits neither mechanism and leaves the
  # staging dir behind. The trap alone is the single source of truth for
  # cleanup on every exit path, success, handled failure, or abort.
  # shellcheck disable=SC2064 # intentional: expand ${staging} NOW, see above
  trap "rm -rf '${staging}'" EXIT
  if stage_and_verify "$prefix" "$staging"; then
    if all_files_current "$staging" "$dest"; then
      if manifest_copy_current "$staging" "$dest"; then
        rc=0
        echo "asset-sync: ${dest} already current"
      elif cp "${staging}/${MANIFEST_NAME}" "${dest}/${MANIFEST_NAME}"; then
        rc=0
        echo "asset-sync: ${dest} files already current — repaired stale ${MANIFEST_NAME}"
      else
        echo "FAIL asset-sync: files already current but could not repair ${dest}/${MANIFEST_NAME} — rerun asset-sync" >&2
        rc=6
      fi
    elif install_staged_files "$staging" "$dest"; then
      rc=0
      echo "asset-sync: installed on-box assets from ${prefix} into ${dest}"
    else
      rc=$?
    fi
  else
    # Captured as the FIRST statement of this branch, deliberately — $?
    # after a skipped `if` body is POSIX-mandated to read 0, not the
    # condition's own code, so it must be read right here, not after `fi`.
    rc=$?
  fi
  return "$rc"
}

read_manifest_source() {
  local repo_root="$1" manifest_source="$2"
  local path="${manifest_source}"
  case "$path" in
    /*) : ;;
    *) path="${repo_root}/${path}" ;;
  esac
  [ -f "$path" ] || { echo "ERROR asset-sync: manifest source not found: ${path}" >&2; return 1; }
  grep -Ev '^\s*(#|$)' "$path"
}

build_publish_staging() {
  local repo_root="$1" staging="$2" entries="$3" line src dest_rel
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    src="${line%%:*}"
    dest_rel="${line#*:}"
    mkdir -p "$(dirname "${staging}/${dest_rel}")"
    cp "${repo_root}/${src}" "${staging}/${dest_rel}"
  done <<< "$entries"
}

write_publish_manifest() {
  local staging="$1" f rel
  : > "${staging}/${MANIFEST_NAME}"
  while IFS= read -r -d '' f; do
    rel="${f#"${staging}/"}"
    [ "$rel" = "${MANIFEST_NAME}" ] && continue
    printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$rel" >> "${staging}/${MANIFEST_NAME}"
  done < <(find "$staging" -type f -print0 | sort -z)
}

upload_staging() {
  local staging="$1" prefix="$2" f rel
  while IFS= read -r -d '' f; do
    rel="${f#"${staging}/"}"
    aws s3 cp "$f" "${prefix%/}/${rel}" >/dev/null
  done < <(find "$staging" -type f -print0 | sort -z)
}

do_publish() {
  local repo_root="$1" prefix="$2" manifest_source="${3:-${DEFAULT_MANIFEST_SOURCE}}"
  local entries staging
  entries="$(read_manifest_source "$repo_root" "$manifest_source")"
  staging="$(mktemp -d)"
  # Double-quoted so "${staging}" expands NOW (trap registration time) to a
  # literal path — a single-quoted trap would defer expansion to EXIT-trap
  # firing time, by which point this function's `local staging` is gone and,
  # under `set -u`, that deferred expansion itself fails.
  # shellcheck disable=SC2064 # intentional: expand ${staging} NOW, see above
  trap "rm -rf '${staging}'" EXIT

  build_publish_staging "$repo_root" "$staging" "$entries"
  validate_compose "$staging"
  write_publish_manifest "$staging"
  upload_staging "$staging" "$prefix"
  echo "asset-sync: published on-box assets from ${manifest_source} to ${prefix}"
}

main() {
  local mode="${1:-}"
  case "$mode" in
    pull)
      [ "$#" -eq 3 ] || usage
      do_pull "$2" "$3"
      ;;
    publish)
      [ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
      do_publish "$2" "$3" "${4:-}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
