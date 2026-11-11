#!/bin/bash
# One-time data change on the server: backup first, then makany_expense_accounts_instapay.sql (all or nothing).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BK=/var/backups/motionpos/before_expense_accounts.dump
sudo -u postgres /usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc motionpos > "$BK"
echo "[OK]   Backup: $BK"
sudo -u postgres psql -X -p 5433 -d motionpos < "$DIR/makany_expense_accounts_instapay.sql"
