#!/usr/bin/env bash
#
# Re-vendor the Microsoft Common Data Model schema documents into
# priv/cdm/schemaDocuments at a pinned commit.
#
# This is idempotent and rarely run: upstream is frozen (see ../ATTRIBUTION.md).
# You run it to (a) reproduce the vendored tree from scratch, or (b) widen
# SPARSE_PATHS when a new problem domain needs another slice of the CDM.
#
# Usage:  priv/cdm/tools/vendor.sh
#
set -euo pipefail

# Pinned upstream commit. Bump deliberately, never automatically -- and update
# the SHA in ../ATTRIBUTION.md when you do.
CDM_SHA="dd21d715e05ebf740a11356c80b5c3b4c38a89c2"

# Which subtrees to fetch. Cone-mode sparse checkout also brings each parent
# directory's own files, which is how we get schemaDocuments/*.cdm.json and
# schemaDocuments/core/*.cdm.json without listing them.
#
# NOTE: adding core/applicationCommon/foundationCommon costs ~580MB. Add the
# specific accelerator path you need instead, e.g.
#   schemaDocuments/core/applicationCommon/foundationCommon/crmCommon/sales
SPARSE_PATHS=(
  "schemaDocuments/core/applicationCommon"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="${REPO_ROOT}/priv/cdm/schemaDocuments"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Fetching microsoft/CDM @ ${CDM_SHA:0:12}"
git init -q "${WORK}"
git -C "${WORK}" remote add origin https://github.com/microsoft/CDM.git
git -C "${WORK}" config core.sparseCheckout true
git -C "${WORK}" sparse-checkout init --cone
git -C "${WORK}" sparse-checkout set "${SPARSE_PATHS[@]}"
git -C "${WORK}" fetch -q --depth 1 origin "${CDM_SHA}"
git -C "${WORK}" checkout -q FETCH_HEAD

SRC="${WORK}/schemaDocuments"

# Upstream ships every document twice: the current `Foo.cdm.json` and a series
# of historical snapshots `Foo.1.2.cdm.json`. The resolver reads only the
# former, so we drop anything carrying a numeric version segment.
is_versioned() {
  [[ "$1" =~ \.[0-9]+(\.[0-9]+)*\.(manifest\.)?cdm\.json$ ]]
}

copy_unversioned() { # $1 = src dir, $2 = dst dir
  local f base
  mkdir -p "$2"
  for f in "$1"/*.cdm.json; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    is_versioned "$base" || cp "$f" "$2/$base"
  done
}

echo "==> Pruning to unversioned documents"
rm -rf "${DEST}"
copy_unversioned "${SRC}" "${DEST}"
copy_unversioned "${SRC}/core" "${DEST}/core"
copy_unversioned "${SRC}/core/applicationCommon" "${DEST}/core/applicationCommon"

# Provenance READMEs travel with the schemas.
cp "${SRC}/README.md" "${DEST}/README.md" 2>/dev/null || true
cp "${SRC}/core/applicationCommon/README.md" "${DEST}/core/applicationCommon/README.md" 2>/dev/null || true

echo "==> Done: $(find "${DEST}" -name '*.cdm.json' | wc -l) documents, $(du -sh "${DEST}" | cut -f1)"
echo "    Licensed CC-BY-4.0 (c) Microsoft Corporation -- see priv/cdm/ATTRIBUTION.md"
