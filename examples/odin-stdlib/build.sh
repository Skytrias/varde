#!/bin/sh
set -eu

# Build a single offline Varde preview from the Odin standard-library
# collections. This is intentionally source-mode output, so it is marked
# incomplete until Varde's semantic resolver reaches compiler parity.

if [ -z "${ODIN_ROOT:-}" ]; then
  echo "Usage: ODIN_ROOT=/path/to/Odin $0" >&2
  exit 2
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
varde="$repo_root/dist/varde"
output_dir=${OUT:-dist/varde-stdlib}

for collection in core vendor base; do
  if [ ! -d "$ODIN_ROOT/$collection" ]; then
    echo "Missing Odin collection: $ODIN_ROOT/$collection" >&2
    exit 2
  fi
done

if [ ! -x "$varde" ]; then
  echo "Build Varde first with: make build-cli" >&2
  exit 2
fi

artifacts=$(mktemp -d "${TMPDIR:-/tmp}/varde-odin-stdlib.XXXXXX")
trap 'rm -rf "$artifacts"' EXIT HUP INT TERM

total_sloc=0
for collection in core vendor base; do
  summary=$("$varde" extract --source "$ODIN_ROOT/$collection" --out "$artifacts/$collection.odin-doc" --allow-incomplete 2>"$artifacts/$collection.diagnostics")
  printf '%s\n' "$summary"
  collection_sloc=$(printf '%s\n' "$summary" | sed -n 's/.*and \([0-9][0-9]*\) SLOC.*/\1/p')
  if [ -z "$collection_sloc" ]; then
    echo "Could not determine SLOC for Odin collection: $collection" >&2
    exit 1
  fi
  total_sloc=$((total_sloc + collection_sloc))
done

"$varde" build \
  --doc "$artifacts/core.odin-doc" \
  --doc "$artifacts/vendor.odin-doc" \
  --doc "$artifacts/base.odin-doc" \
  --workspace "$ODIN_ROOT" \
  --sloc "$total_sloc" \
  --out "$output_dir"

diagnostics_dir="$ODIN_ROOT/$output_dir/diagnostics"
mkdir -p "$diagnostics_dir"
for collection in core vendor base; do
  cp "$artifacts/$collection.diagnostics" "$diagnostics_dir/$collection.txt"
done

echo "Built Odin standard-library preview at $ODIN_ROOT/$output_dir/index.html"
echo "Source-mode diagnostics are available in $diagnostics_dir"
