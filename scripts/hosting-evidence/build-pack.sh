#!/usr/bin/env bash
# build-pack.sh — AXI-2420 (Feature Hosting-Assurance-Pack). Regenerates the hosting
# evidence from Terraform, then renders every partner-facing Markdown file of a pack
# (fr/ and en/) to DOCX and PDF in <pack>/dist/. INTERNAL-* files are never rendered.
#
# Usage: scripts/hosting-evidence/build-pack.sh [<pack-dir>] [<docs-root>]
#   default pack: ../axiome-docs/04 - architecture/infrastructure/hosting-assurance/aphm-mag4
# Needs: python3, pandoc, an authenticated gh; libreoffice (soffice) for PDF (skipped with a warning if absent).
# Refuses (exit 3) when providers/aws differs from the last production apply (committed or
# not), so the annex only ever describes the configuration that is live.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCS_ROOT="${2:-${REPO_ROOT}/../axiome-docs}"
PACK="${1:-${DOCS_ROOT}/04 - architecture/infrastructure/hosting-assurance/aphm-mag4}"
DIST="${PACK}/dist"

command -v pandoc >/dev/null || { echo "pandoc is required" >&2; exit 1; }
[ -d "${PACK}/fr" ] || { echo "not a pack (no fr/): ${PACK}" >&2; exit 1; }

REPORTS="${DOCS_ROOT}/reports/hosting"
REV="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ] || REV="${REV}-dirty"

# 1. Evidence first: a failed residency check (exit 2) stops the build.
python3 "${SCRIPT_DIR}/scan.py" --out-dir "${REPORTS}" --revision "${REV}" >/dev/null
latest="$(ls -1 "${REPORTS}/"*__hosting-evidence.json | sort | tail -1)"
deployment="${latest%__hosting-evidence.json}__last-deployment.json"

# 2. The scanned Terraform must be identical to the one last applied to production.
python3 "${SCRIPT_DIR}/last_deployment.py" > "${deployment}"
deployed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["head_sha"])' "${deployment}")"
git -C "${REPO_ROOT}" cat-file -e "${deployed}^{commit}" 2>/dev/null || git -C "${REPO_ROOT}" fetch -q origin
if ! git -C "${REPO_ROOT}" diff --quiet "${deployed}" -- providers/aws \
   || [ -n "$(git -C "${REPO_ROOT}" status --porcelain -- providers/aws)" ]; then
  echo "providers/aws differs from the last production apply (${deployed}); apply or revert first" >&2
  rm -f "${deployment}"
  exit 3
fi

mkdir -p "${DIST}"
render() { # <markdown> <basename>
  pandoc "$1" --from gfm --to docx --output "${DIST}/$2.docx"
  if command -v soffice >/dev/null; then
    soffice --headless --convert-to pdf --outdir "${DIST}" "${DIST}/$2.docx" >/dev/null 2>&1
  else
    echo "warning: soffice not found, PDF skipped for $2" >&2
  fi
}

annex() { # <lang> <basename>
  local md; md="$(mktemp --suffix .md)"
  python3 "${SCRIPT_DIR}/partner_report.py" "${latest}" --lang "$1" --deployment "${deployment}" > "${md}"
  render "${md}" "$2"
  rm -f "${md}"
}
annex fr "annexe-1-rapport-preuves-hebergement"
annex en "en-annex-1-hosting-evidence-report"
for lang in fr en; do
  for md in "${PACK}/${lang}"/0[1-9]-*.md; do
    render "${md}" "${lang}-$(basename "${md}" .md)"
  done
done
ls -1 "${DIST}"
