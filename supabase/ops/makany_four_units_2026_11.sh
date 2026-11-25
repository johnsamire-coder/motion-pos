#!/bin/bash
# Makany: the 4 items counted in another unit: unit = the paper one, stock = the count. Backup first, runs once.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_makany_four_units_2026_11.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/makany_four_units_2026_11.sql"
