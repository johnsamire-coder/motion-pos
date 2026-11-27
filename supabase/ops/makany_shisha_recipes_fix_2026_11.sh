#!/bin/bash
# Makany: قص برج recipes 6.25 g -> 25 g, سلوم shisha takes معسل سلوم. Backup first, runs once.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_makany_shisha_recipes_fix_2026_11.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/makany_shisha_recipes_fix_2026_11.sql"
