#!/bin/bash
# Correction after the Makany paper stocktake: espresso 972 g (not 9972), ice to zero. Backup first, all or nothing.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_makany_stocktake_2026_11_fix.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/makany_stocktake_2026_11_fix.sql"
