#!/bin/sh
# Builds agtop for Linux x86_64 from its checkout and installs it on a
# machine that runs cards, when the machine's agtop differs from this one.
#
#   Scripts/agtop-to-machine.sh root@100.114.220.85
#
# AGTOP_SRC is the agtop checkout (default ~/Projects/agtop), AGTOP_ARCH the
# machine's architecture (default amd64). The binary goes to
# /usr/local/bin/agtop. Running hosts keep their old binary until they restart.
set -eu

target="${1:?usage: Scripts/agtop-to-machine.sh <ssh target>}"
src="${AGTOP_SRC:-$HOME/Projects/agtop}"
arch="${AGTOP_ARCH:-amd64}"

here="$(agtop --version 2>/dev/null || echo none)"
there="$(ssh -o BatchMode=yes "$target" 'agtop --version 2>/dev/null || echo none')"
echo "this machine: $here"
echo "$target: $there"
if [ "$here" = "$there" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "Same agtop, nothing to do (FORCE=1 to install anyway)."
  exit 0
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
(cd "$src" && GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -o "$out/agtop" ./cmd/agtop)
scp -q -o BatchMode=yes "$out/agtop" "$target:/usr/local/bin/agtop.new"
ssh -o BatchMode=yes "$target" 'chmod 755 /usr/local/bin/agtop.new && mv -f /usr/local/bin/agtop.new /usr/local/bin/agtop && agtop --version'
