#!/bin/bash
# publish-privacy-page.sh — sync the privacy policy to the live site.
#
# Source of truth: app/docs/privacy.html (edit that file, never gh-pages).
# Publishes to the gh-pages branch as privacy/index.html, served at
# https://ziroedge.zanishlabs.com/privacy/ via the repo's custom domain.
#
# Usage: ./Scripts/publish-privacy-page.sh
# Requires: gh CLI authenticated with repo scope.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/docs/privacy.html"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SOURCE" ]; then
	echo "Source not found: $SOURCE" >&2
	exit 1
fi

git clone -q --branch gh-pages "https://github.com/Zane-dev16/ZiroEdge.git" "$WORK/site"
mkdir -p "$WORK/site/privacy"
cp "$SOURCE" "$WORK/site/privacy/index.html"

cd "$WORK/site"
if git diff --quiet -- privacy/index.html; then
	echo "Privacy page already up to date — nothing to publish."
	exit 0
fi
git add privacy/index.html
git -c user.name="ZiroEdge Publisher" -c user.email="publish@zanishlabs.com" \
	commit -qm "site: sync privacy policy"
git push -q origin gh-pages
echo "Published privacy page to https://ziroedge.zanishlabs.com/privacy/"
