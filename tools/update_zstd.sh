#!/usr/bin/env bash
#
# Update the vendored zstd in zstd/deps/zstd.
#
# Usage: tools/update_zstd.sh <version>    (e.g. tools/update_zstd.sh 1.6.0)
#
# Requires: git, python3 (>= 3.8)

set -euo pipefail

readonly REPO_URL="https://github.com/facebook/zstd"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 <version>"
version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $1"

for cmd in git python3; do
  command -v "$cmd" >/dev/null || die "$cmd is required"
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deps="$root/zstd/deps/zstd"
[[ -d "$deps/single_file" ]] || die "not found: $deps/single_file"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
src="$tmp/src"
out="$tmp/out"
mkdir "$out"

echo "Fetching zstd v$version..."
git -c advice.detachedHead=false clone --quiet --depth 1 \
  --branch "v$version" "$REPO_URL" "$src"

# Make sure the sources really are the requested version.
header_define() {
  sed -nE "s/^#define ZSTD_VERSION_$1[[:space:]]+([0-9]+).*/\1/p" "$src/lib/zstd.h"
}
actual="$(header_define MAJOR).$(header_define MINOR).$(header_define RELEASE)"
[[ "$actual" == "$version" ]] || die "zstd.h is $actual, expected $version"

# Same as upstream's create_single_file_library.sh, plus `-k zstd.h`:
# zstd.c includes ../zstd.h instead of embedding a second copy of it.
# `-X utf8`: combine.py reads and writes files in the locale encoding.
echo "Amalgamating zstd.c..."
single="$src/build/single_file_libs"
python3 -I -X utf8 "$single/combine.py" -r "$src/lib" -x legacy/zstd_legacy.h \
  -k zstd.h -o "$out/zstd.c" "$single/zstd-in.c" 2>"$tmp/combine.log" ||
  { cat "$tmp/combine.log" >&2; die "combine.py failed"; }

# combine.py reports unresolved includes without a failing exit status.
if grep -E '^(Error|Warning):' "$tmp/combine.log" >&2; then
  die "combine.py reported problems"
fi
grep -q '^#include "\.\./zstd\.h"' "$out/zstd.c" ||
  die "zstd.c does not include ../zstd.h; the upstream layout may have changed"

# Every remaining quoted include must be a header we vendor.
unexpected="$(grep -E '^[[:space:]]*#[[:space:]]*include[[:space:]]*"' "$out/zstd.c" |
  grep -vE '"\.\./zstd\.h"' || true)"
[[ -z "$unexpected" ]] || die "unexpected include in zstd.c: $unexpected"

for file in LICENSE lib/zstd.h lib/zstd_errors.h; do
  [[ -f "$src/$file" ]] || die "missing upstream file: $file"
done

# Nothing in the repository is touched before this point.
cp "$out/zstd.c" "$deps/single_file/zstd.c"
cp "$src/lib/zstd.h" "$src/lib/zstd_errors.h" "$src/LICENSE" "$deps/"

echo "Updated zstd to $version ($(git -C "$src" rev-parse HEAD))"
