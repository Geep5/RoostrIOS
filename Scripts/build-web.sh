#!/usr/bin/env bash
# Builds the sibling website (SvelteKit adapter-static) and copies its output
# into App/Web/, the folder reference the app bundles and serves at
# roostr://app/. Writes App/Web/web-manifest.json {websiteCommit, builtAt}.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
website="${ROOSTR_WEBSITE:-$root/../RoostrWebsite}"
target="$root/App/Web"

(cd "$website" && npm run build)

mkdir -p "$target"
rsync -a --delete "$website/build/" "$target/"

commit="$(git -C "$website" rev-parse HEAD 2>/dev/null || echo unknown)"
built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"websiteCommit":"%s","builtAt":"%s"}\n' "$commit" "$built_at" > "$target/web-manifest.json"
echo "App/Web ← $website/build ($commit, $built_at)"
