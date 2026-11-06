#!/usr/bin/env bash
# build-pack.sh — AXI-2420 (Feature Hosting-Assurance-Pack). Regenerates the hosting
# evidence from Terraform, then renders every partner-facing Markdown file of a pack
# (fr/ and en/) to DOCX and PDF in <pack>/dist/. INTERNAL-* files are never rendered.
#
# Usage: scripts/hosting-evidence/build-pack.sh [<pack-dir>]
#   default pack: ../axiome-docs/04 - architecture/infrastructure/hosting-assurance/aphm-mag4
# Needs: python3, pandoc; libreoffice (soffice) for PDF (skipped with a warning if absent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCS_ROOT="${REPO_ROOT}/../axiome-docs"
PACK="${1:-${DOCS_ROOT}/04 - architecture/infrastructure/hosting-assurance/aphm-mag4}"
DIST="${PACK}/dist"

command -v pandoc >/dev/null || { echo "pandoc is required" >&2; exit 1; }
[ -d "${PACK}/fr" ] || { echo "not a pack (no fr/): ${PACK}" >&2; exit 1; }

# 1. Evidence first: a failed residency check (exit 2) stops the build.
python3 "${SCRIPT_DIR}/scan.py" --out-dir "${DOCS_ROOT}/reports/hosting" >/dev/null
latest="$(ls -1 "${DOCS_ROOT}/reports/hosting/"*__hosting-evidence.md | sort | tail -1)"

mkdir -p "${DIST}"
render() { # <markdown> <basename>
  pandoc "$1" --from gfm --to docx --output "${DIST}/$2.docx"
  if command -v soffice >/dev/null; then
    soffice --headless --convert-to pdf --outdir "${DIST}" "${DIST}/$2.docx" >/dev/null 2>&1
  else
    echo "warning: soffice not found, PDF skipped for $2" >&2
  fi
}

render "${latest}" "annexe-1-rapport-preuves-hebergement"
for lang in fr en; do
  for md in "${PACK}/${lang}"/0[1-9]-*.md; do
    render "${md}" "${lang}-$(basename "${md}" .md)"
  done
done
ls -1 "${DIST}"
