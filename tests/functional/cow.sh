#!/usr/bin/env bash

source common.sh

# Tests for the copy-on-write (reflink) import fast paths:
#
#   P1  `Store::addToStoreSlow()` -> `Store::addToStoreFromSourcePath()`
#       (used by `nix store add`/`add-path`, `nix-store --add-fixed`)
#   P2  `LocalStore::addToStore(name, SourcePath)`
#       (used by `builtins.path`, `fetchToStore()`, `nix-store --add`)
#   P3  `path:` inputs -> `libfetchers/path.cc` (the same `addToStore()` as P2)
#   P4  the batch `copyPaths()` fast path (used by `nix copy`)
#
# Whether a reflink actually happens depends on the backing file system, so
# these tests only assert correctness: a path imported through the CoW fast
# path must end up with exactly the same store path and NAR hash as a normal
# NAR-based import. Actually observing reflinks on btrfs is the job of
# `tests/nixos/cow.nix`.

# The content-addressed NAR hash of an on-disk path, as an SRI string.
narHashOfSrc() {
    nix hash path --type sha256 "$1"
}

# The `narHash` the store recorded for a store path, as an SRI string.
# Optionally pass a store URL as the second argument.
narHashOf() {
    if [[ -n "${2-}" ]]; then
        nix path-info --store "$2" --json --json-format 2 "$1"
    else
        nix path-info --json --json-format 2 "$1"
    fi | jq -r '.info[] | .narHash'
}

# Whether the store considers a path ultimately trusted.
# Optionally pass a store URL as the second argument.
ultimateOf() {
    if [[ -n "${2-}" ]]; then
        nix path-info --store "$2" --json --json-format 2 "$1"
    else
        nix path-info --json --json-format 2 "$1"
    fi | jq -r '.info[] | .ultimate'
}

# Assert that a store path holds exactly the same content as the on-disk
# source path it was imported from.
assertSameContent() {
    local path="$1" src="$2" expected actual
    expected=$(narHashOfSrc "$src")
    actual=$(narHashOf "$path")
    if [[ "$expected" != "$actual" ]]; then
        fail "NAR hash of '$path' is $actual, but '$src' hashes to $expected"
    fi
}

# The `st_dev` of a path, in a GNU/BSD portable way.
deviceOf() {
    if stat -c %d "$1" > /dev/null 2>&1; then
        stat -c %d "$1"
    else
        stat -f %d "$1"
    fi
}

# The mtime of a path, in a GNU/BSD portable way.
mtimeOf() {
    if stat -c %Y "$1" > /dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

###############################################################################
# A source tree that exercises the interesting cases of `copyRecursive`
###############################################################################

src="$TEST_ROOT/cow-src"
rm -rf "$src"
mkdir -p "$src/dir/nested" "$src/empty-dir"
echo "hello" > "$src/file"
echo "world" > "$src/dir/nested/file"
: > "$src/empty-file"
printf '#!/bin/sh\necho exec\n' > "$src/exe"
chmod +x "$src/exe"
ln -s file "$src/relative-symlink"
ln -s /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-missing "$src/dangling-symlink"
echo "name with spaces" > "$src/name with spaces"
printf 'quote " backslash \\ dollar $ backtick `\n' > "$src/weird-\"-\$-name"

###############################################################################
# P1: `addToStoreSlow()` / `addToStoreFromSourcePath()` (`nix store add`)
###############################################################################

p1=$(nix store add-path --name cow-p1 "$src")
assertSameContent "$p1" "$src"

# A symlink to the source tree (the source itself is a symlink).
ln -s "$src" "$TEST_ROOT/cow-src-link"
p1link=$(nix store add-path --name cow-p1-link "$TEST_ROOT/cow-src-link")
[[ "$(narHashOf "$p1link")" == "$(narHashOfSrc "$TEST_ROOT/cow-src-link")" ]]

# Flat mode (a single regular file).
p1flat=$(nix store add --mode flat --name cow-p1-flat "$src/file")
[[ "$(narHashOf "$p1flat")" == "$(narHashOfSrc "$src/file")" ]]

# Empty file and empty directory.
p1empty=$(nix store add-path --name cow-p1-empty "$src/empty-dir")
[[ "$(narHashOf "$p1empty")" == "$(narHashOfSrc "$src/empty-dir")" ]]

###############################################################################
# P2: `LocalStore::addToStore(name, SourcePath)` (`builtins.path`)
###############################################################################

p2=$(nix eval --impure --raw --expr "builtins.path { name = \"cow-p2\"; path = \"$src\"; }")
assertSameContent "$p2" "$src"

# `builtins.path` and `nix store add-path` must agree on the store path.
p2ref=$(nix store add-path --name cow-p2 "$src")
[[ "$p2" == "$p2ref" ]] || fail "builtins.path and nix store add-path disagree: $p2 vs $p2ref"

# A filter must be applied consistently to both the hash and the copy.
filtered="$TEST_ROOT/cow-filtered"
rm -rf "$filtered"
mkdir -p "$filtered"
echo keep > "$filtered/keep"
echo drop > "$filtered/drop"
p2filter=$(nix eval --impure --raw --expr \
    "builtins.path { name = \"cow-p2-filter\"; path = \"$filtered\"; filter = path: type: builtins.baseNameOf path != \"drop\"; }")
[[ -e "$p2filter/keep" ]] || fail "filtered import dropped an included file"
[[ ! -e "$p2filter/drop" ]] || fail "filtered import kept an excluded file"
filteredRef="$TEST_ROOT/cow-filtered-ref"
rm -rf "$filteredRef"
mkdir -p "$filteredRef"
echo keep > "$filteredRef/keep"
[[ "$(narHashOf "$p2filter")" == "$(narHashOfSrc "$filteredRef")" ]] || fail "filtered import hash mismatch"

# An explicitly wrong expected hash must be rejected.
expect 1 nix eval --impure --raw --expr \
    "builtins.path { name = \"cow-p2-bad\"; path = \"$src\"; sha256 = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; }"

###############################################################################
# Legacy CLI: `nix-store --add` (P2) and `nix-store --add-fixed` (P1)
###############################################################################

# `nix-store --add` calls `LocalStore::addToStore(name, SourcePath)`, i.e. the
# same entry point as `builtins.path` (P2).
p2legacy=$(nix-store --add "$src")
[[ "$(narHashOf "$p2legacy")" == "$(narHashOfSrc "$src")" ]] || fail "nix-store --add produced a wrong NAR hash"

# `nix-store --add-fixed` calls `addToStoreSlow()`, i.e. the same entry point
# as `nix store add-path` (P1). Flat (the default) takes a single regular file.
p1fixed=$(nix-store --add-fixed sha256 "$src/file")
[[ "$(narHashOf "$p1fixed")" == "$(narHashOfSrc "$src/file")" ]] \
    || fail "nix-store --add-fixed (flat) produced a wrong NAR hash"

# With `--recursive` it ingests a whole tree as a NAR.
p1fixedrec=$(nix-store --add-fixed --recursive sha256 "$src")
[[ "$(narHashOf "$p1fixedrec")" == "$(narHashOfSrc "$src")" ]] \
    || fail "nix-store --add-fixed --recursive produced a wrong NAR hash"

# `--add` and `--add-fixed --recursive` must agree on the resulting store path.
[[ "$p2legacy" == "$p1fixedrec" ]] || fail "nix-store --add and --add-fixed --recursive disagree"

###############################################################################
# P3: `path:` inputs (`builtins.fetchTree "path://..."`)
###############################################################################

p3src="$TEST_ROOT/cow-p3"
rm -rf "$p3src"
mkdir -p "$p3src"
echo p3 > "$p3src/file"
# `lastModified` is the maximum mtime over the tree, so set every entry.
touch -t 202211111111 "$p3src/file" "$p3src"

p3=$(nix eval --impure --raw --expr "(builtins.fetchTree \"path://$p3src\").outPath")
assertSameContent "$p3" "$p3src"

# `lastModified` must be propagated from the source directory.
[[ "$(nix eval --impure --json --expr "(builtins.fetchTree { type = \"path\"; path = \"$p3src\"; }).lastModified")" == \
    "$(mtimeOf "$p3src/file")" ]] || fail "path: input did not propagate lastModified"

###############################################################################
# P4: the batch `copyPaths()` fast path (`nix copy`)
###############################################################################

# `NIX_STORE_DIR` is only set when not testing on NixOS.
storeDir="${NIX_STORE_DIR:-${NIX_STORE:-/nix/store}}"
dstRoot="$TEST_ROOT/cow-dst"
dstStore="$dstRoot?store=$storeDir"
rm -rf "$dstRoot"

nix copy --no-check-sigs --to "$dstStore" "$p1"
[[ "$(narHashOf "$p1" "$dstStore")" == "$(narHashOf "$p1")" ]] || fail "copied path has a different NAR hash"
[[ "$(ultimateOf "$p1" "$dstStore")" == false ]] || fail "copied path is marked as ultimately trusted"

# Copying a locally built path must also clear `ultimate`.
out=$(nix-build ./simple.nix --no-out-link)
[[ "$(ultimateOf "$out")" == true ]] || fail "locally built path is not marked ultimate"
nix copy --no-check-sigs --to "$dstStore" "$out"
[[ "$(ultimateOf "$out" "$dstStore")" == false ]] || fail "copied built path is marked ultimate"

# `--repair` must produce the same result.
nix copy --no-check-sigs --to "$dstStore" --repair "$p1"
[[ "$(narHashOf "$p1" "$dstStore")" == "$(narHashOf "$p1")" ]] || fail "repaired copy has a different NAR hash"

# Round-trip through a binary cache. The source is not a local file-system
# store, so this deterministically takes the NAR fallback, and the result must
# still be correct.
cacheRoot="$cacheDir/cow-cache"
cache="file://$cacheRoot"
rm -rf "$cacheRoot"
nix copy --no-check-sigs --to "$cache" "$p1"
dst2Root="$TEST_ROOT/cow-dst2"
dst2Store="$dst2Root?store=$storeDir"
rm -rf "$dst2Root"
nix copy --no-check-sigs --from "$cache" --to "$dst2Store" "$p1"
[[ "$(narHashOf "$p1" "$dst2Store")" == "$(narHashOf "$p1")" ]] || fail "NAR fallback copy has a different NAR hash"
[[ "$(ultimateOf "$p1" "$dst2Store")" == false ]] || fail "NAR fallback copy is marked as ultimately trusted"
