#!/bin/bash
# One-time correction on the server: backup first, then clear_yasmin_balance.sql (all or nothing).
# Usage: sudo bash clear_yasmin_balance.sh [forgiven|returned]   (default forgiven)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-forgiven}"
case "$MODE" in forgiven|returned) ;; *) echo "use: forgiven or returned"; exit 1;; esac
BK=/var/backups/motionpos/before_yasmin_balance_clear.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos -v mode="$MODE" < "$DIR/clear_yasmin_balance.sql"
