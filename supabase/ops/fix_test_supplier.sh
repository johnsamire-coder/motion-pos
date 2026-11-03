#!/bin/bash
# One-time data fix on the server: backup first, then fix_test_supplier.sql (all or nothing).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_supplier_fix.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/fix_test_supplier.sql"
