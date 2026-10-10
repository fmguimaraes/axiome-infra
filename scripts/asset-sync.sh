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
# pull: downloads <s3-prefix>/manifest.sha256, downloads every file it lists,
# verifies every checksum, validates docker-compose.yml (if present among the
# downloaded files) with `docker compose config -q`, and only then installs
# each file into <dest-dir> (keeping each previous copy as "<file>.prev").
# A failure at any step before install leaves <dest-dir> completely untouched.
#
# publish: builds a manifest.sha256 from a small "<repo-relative-src>:
# <dest-relative-path>" manifest-source file (default
# providers/aws/onbox/publish-manifest.txt, resolved against <repo-root>) and
# uploads every listed file plus the manifest to <s3-prefix>. Operator/CI
# side only — this story never runs it against a real bucket.
#
# Exit codes (pull):
#   0  installed, or confirmed already current
#   2  manifest or a listed file could not be fetched — existing assets kept
#   3  a downloaded file's checksum does not match the manifest — nothing installed
#   4  docker-compose.yml failed `docker compose config -q` — nothing installed
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

cleanup_dir() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] && rm -rf "$dir"
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

install_staged_files() {
  local staging="$1" dest="$2" line rel dest_path
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel="$(manifest_rel "$line")"
    dest_path="${dest}/${rel}"
    mkdir -p "$(dirname "$dest_path")"
    [ -f "$dest_path" ] && cp -p "$dest_path" "${dest_path}.prev"
    mv "${staging}/${rel}" "$dest_path"
  done < "${staging}/${MANIFEST_NAME}"
  cp "${staging}/${MANIFEST_NAME}" "${dest}/${MANIFEST_NAME}"
}

# Fetches + verifies + validates into $2 (an already-created staging dir).
# Returns 0 only when it is safe to install; a non-zero return means $2 is
# left exactly as the caller handed it — do_pull never installs on failure.
stage_and_verify() {
  local prefix="$1" staging="$2"
  fetch_manifest "$prefix" "$staging" || {
    echo "WARN asset-sync: manifest unreachable at ${prefix} — keeping existing assets" >&2
    return 2
  }
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
  if stage_and_verify "$prefix" "$staging"; then
    install_staged_files "$staging" "$dest"
    cleanup_dir "$staging"
    echo "asset-sync: installed on-box assets from ${prefix} into ${dest}"
    return 0
  else
    # Captured as the FIRST statement of this branch, deliberately — $?
    # after a skipped `if` body is POSIX-mandated to read 0, not the
    # condition's own code, so it must be read right here, not after `fi`.
    rc=$?
    cleanup_dir "$staging"
    return "$rc"
  fi
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
