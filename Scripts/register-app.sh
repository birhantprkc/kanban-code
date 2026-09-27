#!/bin/bash
# Registers this build as the only Kanban Code Launch Services knows about.
# Every other registered copy with the same bundle id (old worktree builds,
# a copy in the Trash) is unregistered, since notification clicks and
# `open -b` launch whichever copy Launch Services picks.
set -uo pipefail
APP=$(cd "$1" && pwd)
BUNDLE_ID=$2
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

"$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" '
  /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
  $1 == "identifier:" && $2 == id { print path }
' | sort -u | while IFS= read -r other; do
  [ "$other" = "$APP" ] && continue
  "$LSREGISTER" -u "$other" 2>/dev/null || true
  echo "Unregistered $other"
done
"$LSREGISTER" -f "$APP" 2>/dev/null || true
