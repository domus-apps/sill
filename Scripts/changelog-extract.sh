#!/bin/bash
# Prints the changelog section for <version> (heading excluded).
# Fails if the section is missing or empty, so a release without notes
# stops before anything is built or published.
#
# Usage: changelog-extract.sh <version> [changelog-file]
#   version         no leading v, e.g. 1.1.0
#   changelog-file  defaults to CHANGELOG.md; pass CHANGELOG.ko.md for the
#                   Korean notes that feed the localized appcast entry
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$1
CHANGELOG=${2:-CHANGELOG.md}

NOTES=$(awk -v ver="$VERSION" '
  /^## / { in_section = ($2 == ver); next }
  in_section { print }
' "$CHANGELOG")

if [[ -z "${NOTES//[[:space:]]/}" ]]; then
    echo "error: $CHANGELOG has no section '## $VERSION'" >&2
    exit 1
fi

printf '%s\n' "$NOTES"
