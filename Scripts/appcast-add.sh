#!/bin/bash
# Appends a release entry to appcast.xml (the Sparkle update feed).
#
# Usage: appcast-add.sh <version> <build> <signature-attrs> [notes-html-file] [ko-notes-html-file]
#   version             marketing version, no leading v (e.g. 1.1.0)
#   build               CFBundleVersion of the release (CI run number)
#   signature-attrs     sign_update's output for the release zip, verbatim:
#                       sparkle:edSignature="..." length="..."
#   notes-html-file     optional English HTML release notes, embedded as the
#                       item's description (shown in the update dialog)
#   ko-notes-html-file  optional Korean notes; Sparkle picks by the user's
#                       macOS language, falling back to the first (English)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$1
BUILD=$2
SIGNATURE_ATTRS=$3
NOTES_HTML_FILE=${4:-}
KO_NOTES_HTML_FILE=${5:-}

ITEM=$(mktemp)
{
    cat <<EOF
    <item>
      <title>Sill v$VERSION</title>
      <link>https://github.com/domus-apps/sill/releases/tag/v$VERSION</link>
      <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
EOF
    # Every description carries an explicit xml:lang: Sparkle treats an
    # unlabeled sibling as implicit English AND logs an error, so labeling
    # only some of them is the one wrong way to do it. English first — the
    # document-order fallback when the user's languages match nothing.
    if [[ -n "$NOTES_HTML_FILE" && -s "$NOTES_HTML_FILE" ]]; then
        echo "      <description xml:lang=\"en\"><![CDATA["
        cat "$NOTES_HTML_FILE"
        echo "      ]]></description>"
        if [[ -n "$KO_NOTES_HTML_FILE" && -s "$KO_NOTES_HTML_FILE" ]]; then
            echo "      <description xml:lang=\"ko\"><![CDATA["
            cat "$KO_NOTES_HTML_FILE"
            echo "      ]]></description>"
        fi
    fi
    cat <<EOF
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/domus-apps/sill/releases/download/v$VERSION/Sill.zip"
        $SIGNATURE_ATTRS
        type="application/octet-stream"/>
    </item>
EOF
} > "$ITEM"

awk -v itemfile="$ITEM" '
  /<\/channel>/ { while ((getline line < itemfile) > 0) print line }
  { print }
' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml
rm "$ITEM"

echo "Added v$VERSION (build $BUILD) to appcast.xml"
