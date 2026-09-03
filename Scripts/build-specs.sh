#!/bin/bash
# Builds the completion-spec bundle Sill downloads at runtime.
#
# The corpus is npm's @withfig/autocomplete: one already-self-contained ESM
# bundle per CLI. JavaScriptCore has no module loader, so each file is
# converted to a classic IIFE script assigning `var __sillSpec` — a pure
# format conversion (no imports remain in the upstream builds).
#
# Specs/overrides/ is layered on top: <cmd>.ts/.js modules are converted the
# same way and replace (or add to) the corpus; <cmd>.json files are plain
# Fig.Spec objects and are wrapped. The bundle version gains "+ov.<hash>"
# whenever overrides exist, so a change here reaches users on the next
# build. See Specs/overrides/README.md.
#
# Output: build/specs/ (converted corpus + index.json),
#         build/specs.zip and build/specs-manifest.json (upload artifacts).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-latest}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Resolve the requested version and fetch the tarball straight from the
# registry — no npm needed.
META=$(curl -fsSL "https://registry.npmjs.org/@withfig/autocomplete/$VERSION")
ACTUAL=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' <<< "$META")
TARBALL=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dist"]["tarball"])' <<< "$META")
echo "@withfig/autocomplete $ACTUAL"
curl -fsSL "$TARBALL" | tar -xz -C "$WORK"
SRC="$WORK/package/build"

if command -v npx > /dev/null; then ESBUILD=(npx -y esbuild); else ESBUILD=(bunx esbuild); fi

OUT=build/specs
rm -rf "$OUT" build/specs.zip build/specs-manifest.json
mkdir -p "$OUT"

# One esbuild invocation for the whole corpus (index.js is the name list,
# not a spec — skipped). --outbase keeps nested loadSpec paths (aws/s3.js).
find "$SRC" -name "*.js" ! -path "$SRC/index.js" > "$WORK/entries.txt"
xargs "${ESBUILD[@]}" --bundle --format=iife --global-name=__sillSpec --minify \
    --log-level=error --outbase="$SRC" --outdir="$OUT" < "$WORK/entries.txt"

# Overrides: modules through esbuild (same flags, overwriting upstream files
# of the same name), JSON wrapped into the same IIFE shape.
OVERRIDES=Specs/overrides
OVERRIDE_FILES=()
if [[ -d "$OVERRIDES" ]]; then
    while IFS= read -r f; do OVERRIDE_FILES+=("$f"); done \
        < <(find "$OVERRIDES" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.json" \) | sort)
fi
if (( ${#OVERRIDE_FILES[@]} > 0 )); then
    MODULES=()
    for f in "${OVERRIDE_FILES[@]}"; do
        case "$f" in
            *.json)
                rel=${f#"$OVERRIDES"/}
                mkdir -p "$OUT/$(dirname "$rel")"
                python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f"  # must parse
                { printf 'var __sillSpec={default:'; cat "$f"; printf '};'; } \
                    > "$OUT/${rel%.json}.js"
                ;;
            *) MODULES+=("$f") ;;
        esac
    done
    if (( ${#MODULES[@]} > 0 )); then
        "${ESBUILD[@]}" --bundle --format=iife --global-name=__sillSpec --minify \
            --log-level=error --outbase="$OVERRIDES" --outdir="$OUT" "${MODULES[@]}"
    fi
    OVHASH=$(cat "${OVERRIDE_FILES[@]}" | shasum -a 256 | cut -c1-8)
    ACTUAL="$ACTUAL+ov.$OVHASH"
    echo "${#OVERRIDE_FILES[@]} overrides → $ACTUAL"
fi

python3 - "$OUT" "$ACTUAL" "$OVERRIDES" <<'PY'
import json, os, sys
out, version, overrides = sys.argv[1], sys.argv[2], sys.argv[3]
files = sorted(
    os.path.relpath(os.path.join(root, f), out)
    for root, _, names in os.walk(out) for f in names if f.endswith(".js"))
overridden = sorted(
    os.path.splitext(os.path.relpath(os.path.join(root, f), overrides))[0]
    for root, _, names in os.walk(overrides) for f in names
    if f.endswith((".ts", ".js", ".json"))) if os.path.isdir(overrides) else []
with open(os.path.join(out, "index.json"), "w") as fh:
    json.dump({"version": version, "files": files, "overrides": overridden}, fh)
print(f"{len(files)} specs")
PY

(cd build && zip -qr specs.zip specs)
SHA=$(shasum -a 256 build/specs.zip | cut -d' ' -f1)
printf '{"version":"%s","sha256":"%s"}\n' "$ACTUAL" "$SHA" > build/specs-manifest.json
echo "Built build/specs.zip ($(du -h build/specs.zip | cut -f1)) sha256=$SHA"
