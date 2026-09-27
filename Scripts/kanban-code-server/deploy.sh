#!/bin/bash
# Builds kanban-code-server on a Linux host and runs it there as a systemd service.
#
#   Scripts/kanban-code-server/deploy.sh [user@host]      (default root@51.159.202.175)
#
# The host needs a Swift 6.2 toolchain in /opt/swift (swift.org tarball for the
# distribution) plus zlib1g-dev. The tree is synced to ~/Projects/kanban-linux on
# the host, built there in release mode with a static Swift runtime, installed as
# /usr/local/bin/kanban-code-server and restarted.
set -euo pipefail

HOST="${1:-root@51.159.202.175}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_DIR="Projects/kanban-linux"

ssh "$HOST" "mkdir -p $REMOTE_DIR"
rsync -az --delete \
  --exclude .build --exclude build --exclude node_modules --exclude .claude --exclude .git \
  --exclude Package.resolved \
  "$ROOT/" "$HOST:$REMOTE_DIR/"

ssh "$HOST" bash -s <<REMOTE
set -euo pipefail
export PATH=/opt/swift/usr/bin:\$PATH
cd $REMOTE_DIR
swift build -c release --product kanban-code-server --static-swift-stdlib
install -m 0755 .build/release/kanban-code-server /usr/local/bin/kanban-code-server
install -m 0644 Scripts/kanban-code-server/kanban-code-server.service /etc/systemd/system/kanban-code-server.service
systemctl daemon-reload
systemctl enable kanban-code-server >/dev/null
systemctl restart kanban-code-server
sleep 2
systemctl --no-pager --lines=5 status kanban-code-server
curl -fsS http://127.0.0.1:7780/v1/health
echo
REMOTE
