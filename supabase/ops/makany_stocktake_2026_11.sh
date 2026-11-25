#!/bin/bash
# Makany stocktake from the paper sheets (2026-11-25).
#   sudo bash makany_stocktake_2026_11.sh preview                     -> shows everything, changes nothing
#   sudo bash makany_stocktake_2026_11.sh apply                       -> backup first, then sets the stock
#   optional 2nd argument: when the counting was done, e.g. "2026-11-24 23:30" (Cairo time)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-preview}"
SINCE="${2:-}"
if [ "$MODE" = "apply" ]; then
  BK=/var/backups/motionpos/before_makany_stocktake_2026_11.dump
  sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
  echo "[OK]   Backup: $BK"
fi
sudo -u postgres psql -X -p 5433 -d motionpos -v mode="$MODE" -v since="$SINCE" < "$DIR/makany_stocktake_2026_11.sql"
