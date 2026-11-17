#!/bin/bash
# One-time data fix on the server: backup first, then fix_ice_shisha_tea.sql (all or nothing).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_ice_shisha_tea_fix.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/fix_ice_shisha_tea.sql"
