#!/usr/bin/env bash
set -euo pipefail

VERSION_FILE="${VERSION_FILE:-VERSION}"

# Read current version or default
if [[ -f "$VERSION_FILE" ]]; then
  current="$(cat "$VERSION_FILE" | tr -d ' \t\r\n')"
else
  current="0.0.0"
fi

# Last tag (or none)
last_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"

# Collect commit messages since last tag
if [[ -n "$last_tag" ]]; then
  log="$(git log --format=%B "${last_tag}..HEAD")"
else
  log="$(git log --format=%B HEAD)"
fi

# Decide bump type (Conventional Commits)
bump="patch"
if echo "$log" | grep -Eq '(BREAKING CHANGE|!:)' ; then
  bump="major"
elif echo "$log" | grep -Eq '(^|\n)feat(\(.+\))?:' ; then
  bump="minor"
elif echo "$log" | grep -Eq '(^|\n)fix(\(.+\))?:' ; then
  bump="patch"
fi

IFS='.' read -r major minor patch <<< "$current"
major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"

case "$bump" in
  major) major=$((major+1)); minor=0; patch=0 ;;
  minor) minor=$((minor+1)); patch=0 ;;
  patch) patch=$((patch+1)) ;;
esac

new="${major}.${minor}.${patch}"

echo "$new" > "$VERSION_FILE"
echo "NEW_VERSION=$new" >> "$GITHUB_ENV"
echo "NEW_TAG=v$new" >> "$GITHUB_ENV"
