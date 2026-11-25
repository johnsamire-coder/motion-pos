#!/bin/bash
# Makany: add the items counted on the paper that were not in the system, with their stock; سكر دايت in pieces.
# Backup first, all or nothing, runs once.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_makany_new_items_2026_11.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/makany_new_items_2026_11.sql"
