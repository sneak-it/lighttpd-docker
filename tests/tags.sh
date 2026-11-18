#!/bin/sh
# Floating tags (latest, major, minor) must move only for the newest upstream version.
set -eu
R=.github/resolve-version.sh
export GITHUB_REPOSITORY=Owner/Repo GITHUB_STEP_SUMMARY=/dev/null
I=ghcr.io/owner/repo
D=$(date -u +%Y%m%d)
eq() { [ "$2" = "$3" ] || { echo "FAIL $1: want $3, got $2"; exit 1; }; echo "ok   $1"; }
tags() { INPUT_VERSION=$1 "$R" | sed -n 's/^tags=//p'; }

new=$(INPUT_VERSION='' "$R" | sed -n 's/^version=//p')
float="$I:latest,$I:${new%%.*},$I:${new%.*},$I:$new,$I:$new-$D"
eq "no input resolves newest with floating tags" "$(tags '')"     "$float"
eq "explicit newest gets floating tags"          "$(tags "$new")" "$float"
eq "older version gets version tags only"        "$(tags 1.4.80)" "$I:1.4.80,$I:1.4.80-$D"
eq "malformed version is rejected" \
  "$(INPUT_VERSION='1.4.80;id' "$R" 2>/dev/null || echo rejected)" "rejected"
eq "unreachable listing is rejected" \
  "$(LISTING_URL=https://download.lighttpd.net/nonexistent/ INPUT_VERSION=1.4.80 "$R" 2>/dev/null || echo rejected)" "rejected"

# A newer release series must be followed, not only newer releases in the current one.
F=$(mktemp -d)
mkdir "$F/releases-1.4.x" "$F/releases-1.5.x"
echo '<a href="releases-1.4.x/"></a><a href="releases-1.5.x/"></a><a href="snapshots-2.0.x/"></a>
<a href="releases-1.4.x/lighttpd-1.4.85.tar.xz"></a>' > "$F/index.html"
echo '<a href="lighttpd-1.4.85.tar.xz"></a>' > "$F/releases-1.4.x/index.html"
echo '<a href="lighttpd-1.5.0.tar.xz"></a>' > "$F/releases-1.5.x/index.html"
python3 -m http.server -d "$F" -b 127.0.0.1 18098 >/dev/null 2>&1 & S=$!
trap 'kill "$S"; rm -rf "$F"' EXIT
curl -fs --retry 10 --retry-connrefused --retry-delay 1 -o /dev/null http://127.0.0.1:18098/
eq "newer release series is followed" \
  "$(LISTING_URL=http://127.0.0.1:18098/ INPUT_VERSION='' "$R" | sed -n 's/^version=//p')" "1.5.0"
