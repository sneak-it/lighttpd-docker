#!/bin/sh
# Prints the version and image tags as step outputs. Floating tags move only for the newest version.
set -eu
LISTING_URL=${LISTING_URL:-https://download.lighttpd.net/lighttpd/}
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is not set" >&2; exit 1; }

valid() {
  case "$1" in *[!0-9.]*) return 1 ;; esac
  case "$1" in [0-9]*.[0-9]*.[0-9]*) ;; *) return 1 ;; esac
}

# Resolved even for an explicit version, since the floating tags depend on it. The newest
# series comes first, so a new series such as 1.5.x is followed.
series=$(curl -fsSL "$LISTING_URL" | grep -o 'releases-[0-9.]*\.x/' | sort -uV | tail -1)
[ -n "$series" ] || { echo "no release series at $LISTING_URL" >&2; exit 1; }
newest=$(curl -fsSL "$LISTING_URL$series" \
  | grep -o 'lighttpd-[0-9.]*\.tar\.xz' | sed 's/lighttpd-//;s/\.tar\.xz//' \
  | sort -uV | tail -1)
valid "$newest" || { echo "no newest version at $LISTING_URL$series: '$newest'" >&2; exit 1; }
v=${INPUT_VERSION:-$newest}
valid "$v" || { echo "bad version: '$v'" >&2; exit 1; }

img=ghcr.io/$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')
# The dated tag never moves, so a rollback target survives every rebuild.
tags="$img:$v,$img:$v-$(date -u +%Y%m%d)"
if [ "$v" = "$newest" ]; then
  tags="$img:latest,$img:${v%%.*},$img:${v%.*},$tags"
fi

[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "### lighttpd $v" >> "$GITHUB_STEP_SUMMARY"
echo "version=$v"
echo "tags=$tags"
