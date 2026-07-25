#!/usr/bin/env bash
# Release script for bashpack
# Usage: ./release.sh <major|minor|small|hotfix>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$ROOT/VERSION"
LIB="$ROOT/lib/bashpack.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <major|minor|small|hotfix>" >&2
  exit 1
fi

current=$(<"$VERSION_FILE")
current="${current#v}"
echo "Current version: $current"

IFS='.-' read -r major minor patch hotfix_tag <<< "$current"
: "${patch:=0}"
hotfix_num="${hotfix_tag#hotfix}"

case "$1" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    hotfix_num=""
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    hotfix_num=""
    ;;
  small)
    patch=$((patch + 1))
    hotfix_num=""
    ;;
  hotfix)
    if [[ -n "$hotfix_num" ]]; then
      hotfix_num=$(printf "%03d" $((10#$hotfix_num + 1)))
    else
      hotfix_num="001"
    fi
    ;;
  *)
    echo "Unknown release type: $1 (use: major, minor, small, hotfix)" >&2
    exit 1
    ;;
esac

if [[ -n "$hotfix_num" ]]; then
  new_ver="${major}.${minor}.${patch}-hotfix${hotfix_num}"
else
  new_ver="${major}.${minor}.${patch}"
fi

echo "New version: v$new_ver"

echo -n "Create release v$new_ver? [y/N] "
read -r confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo "$new_ver" > "$VERSION_FILE"

git add "$VERSION_FILE"
git commit -m "Release v$new_ver"

git tag "v$new_ver"
git tag "$new_ver"

git push origin master "v$new_ver" "$new_ver"

gh release create "v$new_ver" \
  --title "v$new_ver" \
  --notes "## v$new_ver

**Release date:** $(date -u '+%Y-%m-%d %H:%M UTC')
**SHA256:** \`$(git archive "v$new_ver" --prefix="bashpack-v$new_ver/" | sha256sum | awk '{print $1}')\`" \
  --target master

echo "Done: https://github.com/wallach-game/bashpack/releases/tag/v$new_ver"
