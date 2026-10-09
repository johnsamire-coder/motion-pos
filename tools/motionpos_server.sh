#!/usr/bin/env bash
# Motion POS on the shared Linux server (Ubuntu 22.04), next to MotionHR / PharmaFlow / MotionStore without touching them.
#   * its own PostgreSQL 17 cluster "motionpos" on port 5433 (MotionHR's PostgreSQL 14 on 5432 is not touched or restarted)
#   * API (PostgREST) on 127.0.0.1:3010 as the service "motionpos-api"
#   * screens in /var/www/motionpos, nginx site "motionpos" for pos.jssolutions-eg.com with its own certificate
#   * daily backup at 03:30 in /var/backups/motionpos (last 14 days)
# Usage (as root): bash motionpos_server.sh install | restore <file.sql> | update | sql <file.sql> | status
# Secrets (passwords) are made here and stay in /etc/motionpos (root only). Nothing is printed.
set -uo pipefail

STEP="${1:-status}"
DOMAIN="pos.jssolutions-eg.com"
PGV=17
PGPORT=5433
CLUSTER=motionpos
DB=motionpos
API_PORT=3010
BASE=/opt/motionpos
REPO="$BASE/repo"
WWW=/var/www/motionpos
SECRETS=/etc/motionpos
BACKUPS=/var/backups/motionpos
REPO_URL="https://github.com/johnsamire-coder/motion-pos.git"
SERVER_USER="${SUDO_USER:-john}"

ok()   { echo "[OK]   $*"; }
info() { echo "[..]   $*"; }
fail() { echo "[FAIL] $*"; exit 1; }
[ "$(id -u)" = "0" ] || fail "Run it with sudo"
cd /tmp || exit 1

psqlm() { sudo -u postgres "/usr/lib/postgresql/$PGV/bin/psql" -X -q -v ON_ERROR_STOP=1 -p "$PGPORT" "$@"; }
val()   { sudo -u postgres "/usr/lib/postgresql/$PGV/bin/psql" -X -A -t -p "$PGPORT" -d "$DB" -c "$1" 2>&1; }

copy_screens() {
  mkdir -p "$WWW"
  rsync -a --delete --exclude '.git' --exclude 'supabase' --exclude 'docs' --exclude 'tests' --exclude 'tools' \
        --exclude 'README.md' --exclude '.gitignore' --exclude '.vercelignore' "$REPO/" "$WWW/" || fail "Copying the screens failed"
  chown -R www-data:www-data "$WWW"
  ok "Screens copied ($(git -C "$REPO" log -1 --format='%h %s' | cut -c1-70))"
}

api_test() {
  local v
  v=$(curl -s -m 10 -X POST "http://127.0.0.1:$API_PORT/rpc/motionpos_version_public" -H 'Content-Type: application/json' -d '{}' || true)
  echo "$v"
}

case "$STEP" in

install)
  # ---------------------------------------------------------------- 0) checks
  [ -r /etc/os-release ] && . /etc/os-release
  info "Server: ${PRETTY_NAME:-unknown}"
  # can be run again after a stop in the middle; once finished it refuses (the data would be lost)
  [ -f "$SECRETS/installed" ] && fail "Motion POS is already installed here. Use: update"
  if ! pg_lsclusters -h 2>/dev/null | awk '{print $1" "$2}' | grep -qx "$PGV $CLUSTER"; then
    ss -ltn | grep -q ":$PGPORT " && fail "Port $PGPORT is already used by something else - stopped, nothing changed"
  fi
  if ! systemctl list-unit-files motionpos-api.service >/dev/null 2>&1 || ! systemctl cat motionpos-api >/dev/null 2>&1; then
    ss -ltn | grep -q "127.0.0.1:$API_PORT " && fail "Port $API_PORT is already used by something else - stopped, nothing changed"
  fi
  myip=$(hostname -I | tr ' ' '\n' | grep -v ':' | head -1)
  dnsip=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)
  [ -n "$dnsip" ] || fail "$DOMAIN does not point anywhere yet (Namecheap A record pos -> server). Wait a few minutes and run again"
  hostname -I | tr ' ' '\n' | grep -qx "$dnsip" || fail "$DOMAIN points to $dnsip, not to this server ($myip)"
  ok "$DOMAIN points to this server"

  # ---------------------------------------------------------------- 1) PostgreSQL 17 (a second, separate cluster)
  export DEBIAN_FRONTEND=noninteractive
  if [ ! -x "/usr/lib/postgresql/$PGV/bin/postgres" ]; then
    info "Installing PostgreSQL $PGV (MotionHR's PostgreSQL 14 keeps running, not restarted)"
    apt-get update -qq >/dev/null || fail "apt update failed"
    apt-get install -y -qq postgresql-common curl ca-certificates git rsync openssl >/dev/null || fail "Installing helpers failed"
    # never make an extra default cluster when the new version is installed
    if ! grep -q '^create_main_cluster *= *false' /etc/postgresql-common/createcluster.conf 2>/dev/null; then
      echo 'create_main_cluster = false' >> /etc/postgresql-common/createcluster.conf
    fi
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null 2>&1 || fail "Adding the PostgreSQL package source failed"
    apt-get install -y -qq "postgresql-$PGV" >/dev/null || fail "Installing PostgreSQL $PGV failed"
  fi
  apt-get install -y -qq git rsync curl openssl xz-utils >/dev/null || true
  ok "PostgreSQL $PGV program ready"
  if ! pg_lsclusters -h | awk '{print $1" "$2}' | grep -qx "$PGV $CLUSTER"; then
    pg_createcluster --locale C.UTF-8 -e UTF8 -p "$PGPORT" "$PGV" "$CLUSTER" >/dev/null || fail "Creating the database cluster failed"
  fi
  pg_conftool "$PGV" "$CLUSTER" set listen_addresses '*'
  pg_conftool "$PGV" "$CLUSTER" set timezone 'UTC'
  pg_conftool "$PGV" "$CLUSTER" set log_timezone 'UTC'
  pg_conftool "$PGV" "$CLUSTER" set shared_buffers '128MB'
  pg_conftool "$PGV" "$CLUSTER" set max_connections '60'
  HBA="/etc/postgresql/$PGV/$CLUSTER/pg_hba.conf"
  if ! grep -q 'motionpos_sync' "$HBA"; then
    printf '\n# Motion POS: the shop PC sync (password + encryption only)\nhostssl %s motionpos_sync 0.0.0.0/0 scram-sha-256\nhostssl %s motionpos_sync ::/0 scram-sha-256\n' "$DB" "$DB" >> "$HBA"
  fi
  systemctl enable "postgresql@$PGV-$CLUSTER" >/dev/null 2>&1 || true
  pg_ctlcluster "$PGV" "$CLUSTER" restart || pg_ctlcluster "$PGV" "$CLUSTER" start || fail "Starting the database failed"
  ok "Database cluster $CLUSTER running on port $PGPORT (MotionHR untouched on 5432)"

  # ---------------------------------------------------------------- 2) secrets, roles, database
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  if [ ! -f "$SECRETS/env" ]; then
    AU=$(openssl rand -hex 24); SY=$(openssl rand -hex 24)
    printf 'AU=%s\nSY=%s\n' "$AU" "$SY" > "$SECRETS/env"; chmod 600 "$SECRETS/env"
  fi
  . "$SECRETS/env"
  psqlm -d postgres >/dev/null <<SQL || fail "Creating roles failed"
do \$\$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then create role supabase_admin nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator login noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'motionpos_sync') then create role motionpos_sync login superuser; end if;
end \$\$;
alter role authenticator password '$AU';
alter role motionpos_sync password '$SY';
grant anon, authenticated, service_role to authenticator;
SQL
  if [ -z "$(val "select 1" | grep -x 1)" ]; then
    psqlm -d postgres -c "create database $DB" >/dev/null || fail "Creating the database failed"
  fi
  ok "Roles and database ready (passwords kept in $SECRETS, root only)"

  # ---------------------------------------------------------------- 3) program files + tables (same files as the shop PC)
  mkdir -p "$BASE"
  if [ -d "$REPO/.git" ]; then git -C "$REPO" pull -q --ff-only || fail "git pull failed"; else git clone -q "$REPO_URL" "$REPO" || fail "git clone failed"; fi
  ok "Program files: $(git -C "$REPO" log -1 --format='%h')"
  latest=$(ls "$REPO"/supabase/migrations/0*.sql | xargs -n1 basename | grep -oE '^[0-9]{3}' | sort | tail -1)
  have=$(val "select public.motionpos_version_public()" | grep -E '^[0-9]{3}$' || true)
  if [ "$have" = "$latest" ]; then
    ok "Tables already built (version $have)"
  else
    if [ -n "$(val "select count(*) from information_schema.tables where table_schema='public'" | grep -vx 0)" ]; then
      info "Half-built tables from a stopped try (version ${have:-none}) - starting them again (no real data here yet)"
      psqlm -d postgres -c "drop database $DB with (force)" >/dev/null || fail "Could not clear the half-built database"
      psqlm -d postgres -c "create database $DB" >/dev/null || fail "Creating the database failed"
    fi
    psqlm -d "$DB" >/dev/null <<'SQL' || fail "Preparing the database failed"
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists dblink with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
drop schema public cascade;
SQL
    mkdir -p /var/log/motionpos
    for f in "$REPO"/supabase/backup/schema_*.sql "$REPO"/supabase/migrations/0*.sql; do
      n=$(basename "$f"); log="/var/log/motionpos/sql_${n%.sql}.log"
      info "Running $n"
      sudo -u postgres "/usr/lib/postgresql/$PGV/bin/psql" -X -q -v ON_ERROR_STOP=1 -p "$PGPORT" -d "$DB" -f "$f" > "$log" 2>&1 || { tail -20 "$log"; fail "SQL failed: $n"; }
      if [ "$n" != "${n#schema_}" ]; then
        # the roles every copy starts with (the self-tests use them); the real ones come with the data
        psqlm -d "$DB" -c "insert into public.roles (name) select x from unnest(array['owner','branch_manager','cashier','waiter','storekeeper']) x where not exists (select 1 from public.roles r where r.name = x)" >/dev/null || fail "Adding the roles failed"
      fi
      num=$(echo "$n" | grep -oE '^[0-9]{3}' || true)
      if [ -n "$num" ] && grep -q "MOTIONPOS-$num-SELFTEST-OK" "$f" && ! grep -q "MOTIONPOS-$num-SELFTEST-OK\|selftest skipped" "$log"; then
        fail "$num self-test message missing (see $log)"
      fi
    done
  fi
  ver=$(val "select public.motionpos_version_public()")
  echo "$ver" | grep -qE '^[0-9]{3}$' || fail "Database version check failed: $ver"
  ok "Tables built: version $ver, this copy is the main (cloud) copy"

  # ---------------------------------------------------------------- 4) API (PostgREST)
  mkdir -p "$BASE/bin"
  if [ ! -x "$BASE/bin/postgrest" ]; then
    got=0
    for u in https://github.com/PostgREST/postgrest/releases/download/v16.2/postgrest-v16.2-linux-static-x86-64.tar.xz \
             https://github.com/PostgREST/postgrest/releases/download/v16.2/postgrest-v16.2-linux-static-x64.tar.xz \
             https://github.com/PostgREST/postgrest/releases/download/v12.2.3/postgrest-v12.2.3-linux-static-x64.tar.xz; do
      if curl -fsSL -m 120 -o /tmp/postgrest.tar.xz "$u"; then
        tar -xJf /tmp/postgrest.tar.xz -C "$BASE/bin" && [ -x "$BASE/bin/postgrest" ] && { got=1; break; }
      fi
    done
    [ "$got" = "1" ] || fail "Downloading the API program failed"
  fi
  id motionpos >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin motionpos
  cat > "$SECRETS/postgrest.conf" <<CONF
db-uri = "postgres://authenticator:$AU@127.0.0.1:$PGPORT/$DB"
db-schemas = "public"
db-anon-role = "anon"
db-pool = 10
server-host = "127.0.0.1"
server-port = $API_PORT
CONF
  chown root:motionpos "$SECRETS/postgrest.conf"; chmod 640 "$SECRETS/postgrest.conf"; chmod 711 "$SECRETS"
  cat > /etc/systemd/system/motionpos-api.service <<UNIT
[Unit]
Description=Motion POS API (PostgREST)
After=network.target postgresql@$PGV-$CLUSTER.service

[Service]
User=motionpos
ExecStart=$BASE/bin/postgrest $SECRETS/postgrest.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable motionpos-api >/dev/null 2>&1; systemctl restart motionpos-api
  for i in $(seq 1 20); do [ -n "$(api_test | grep -E '[0-9]{3}')" ] && break; sleep 1; done
  [ -n "$(api_test | grep -E '[0-9]{3}')" ] || { journalctl -u motionpos-api -n 20 --no-pager; fail "API did not start"; }
  ok "API running (answers version $(api_test))"

  # ---------------------------------------------------------------- 5) screens + nginx + certificate
  copy_screens
  cat > /etc/nginx/sites-available/motionpos <<NGX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $WWW;
    index index.html;
    client_max_body_size 5m;
    location /rest/v1/ {
        proxy_pass http://127.0.0.1:$API_PORT/;
        proxy_set_header Authorization "";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
    location ~ /\.(git|ht|env) { deny all; }
    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-cache";
    }
}
NGX
  ln -sf /etc/nginx/sites-available/motionpos /etc/nginx/sites-enabled/motionpos
  if ! nginx -t >/dev/null 2>&1; then rm -f /etc/nginx/sites-enabled/motionpos; nginx -t; fail "nginx settings invalid - removed again, other sites untouched"; fi
  systemctl reload nginx
  ok "nginx site added (other sites untouched)"
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect --register-unsafely-without-email >/var/log/motionpos/certbot.log 2>&1 \
    || { tail -15 /var/log/motionpos/certbot.log; fail "Certificate failed (site works on http only for now)"; }
  ok "Certificate (lock) ready for $DOMAIN"

  # ---------------------------------------------------------------- 6) daily backup + sync address for the shop PC
  mkdir -p "$BACKUPS"; chown postgres:postgres "$BACKUPS"; chmod 700 "$BACKUPS"
  cat > /etc/cron.d/motionpos-backup <<CRON
30 3 * * * postgres /usr/lib/postgresql/$PGV/bin/pg_dump -p $PGPORT -Fc -f $BACKUPS/motionpos_\$(date +\%F).dump $DB && find $BACKUPS -name 'motionpos_*.dump' -mtime +14 -delete
CRON
  printf 'postgresql://motionpos_sync:%s@%s:%s/%s?sslmode=require\n' "$SY" "$DOMAIN" "$PGPORT" "$DB" > "$SECRETS/sync_conn"
  chown root:"$SERVER_USER" "$SECRETS/sync_conn"; chmod 640 "$SECRETS/sync_conn"
  ok "Daily backup at 03:30 in $BACKUPS (14 days kept)"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$DOMAIN/")
  v=$(curl -s -m 15 -X POST "https://$DOMAIN/rest/v1/rpc/motionpos_version_public" -H 'Content-Type: application/json' -d '{}')
  [ "$code" = "200" ] || fail "https://$DOMAIN/ answers $code"
  ok "https://$DOMAIN/ -> 200, database version $v"
  date -u +%FT%TZ > "$SECRETS/installed"
  echo "SERVER INSTALL DONE"
  ;;

restore)
  # data from the old cloud copy (pg_dump --data-only of schema public); replaces all data here
  f="${2:-}"; [ -f "$f" ] || fail "Data file not found: $f"
  grep -q 'PostgreSQL database dump' "$f" || fail "This is not a database dump file"
  info "Emptying the tables here, then loading the data"
  list=$(val "select string_agg(format('public.%I', tablename), ', ') from pg_tables where schemaname = 'public'")
  log=/var/log/motionpos/restore.log; mkdir -p /var/log/motionpos
  { echo "begin;"; echo "truncate $list restart identity cascade;"; grep -v '^SET transaction_timeout' "$f"; echo "commit;"; } > /tmp/motionpos_restore.sql
  chown postgres /tmp/motionpos_restore.sql
  sudo -u postgres "/usr/lib/postgresql/$PGV/bin/psql" -X -q -v ON_ERROR_STOP=1 -p "$PGPORT" -d "$DB" -f /tmp/motionpos_restore.sql > "$log" 2>&1 \
    || { tail -20 "$log"; rm -f /tmp/motionpos_restore.sql; fail "Loading the data failed - nothing changed (all or nothing)"; }
  rm -f /tmp/motionpos_restore.sql "$f"
  val "update public.sync_node set node = 'cloud', updated_at = now()" >/dev/null
  ok "Data loaded: $(val "select count(*) from public.products") products, $(val "select count(*) from public.recipes") recipe lines, $(val "select count(*) from public.ingredients") ingredients, $(val "select count(*) from public.staff") users, $(val "select count(*) from public.orders") orders"
  systemctl restart motionpos-api
  echo "RESTORE DONE"
  ;;

update)
  # new screens after a release on GitHub
  git -C "$REPO" pull -q --ff-only || fail "git pull failed"
  copy_screens
  echo "UPDATE DONE"
  ;;

sql)
  # run one database file (new phases), all or nothing
  f="${2:-}"; [ -f "$f" ] || fail "File not found: $f"
  log="/var/log/motionpos/sql_$(basename "$f" .sql).log"; mkdir -p /var/log/motionpos
  cp "$f" /tmp/motionpos_one.sql; chown postgres /tmp/motionpos_one.sql
  sudo -u postgres "/usr/lib/postgresql/$PGV/bin/psql" -X -q -v ON_ERROR_STOP=1 -p "$PGPORT" -d "$DB" -f /tmp/motionpos_one.sql > "$log" 2>&1 \
    || { tail -20 "$log"; rm -f /tmp/motionpos_one.sql; fail "SQL failed: $(basename "$f") - nothing changed"; }
  rm -f /tmp/motionpos_one.sql
  grep -o 'MOTIONPOS-[0-9]*-SELFTEST-OK' "$log" | head -1
  systemctl restart motionpos-api
  ok "Done, database version $(val "select public.motionpos_version_public()")"
  ;;

status)
  pg_lsclusters | grep -E "^$PGV +$CLUSTER" || echo "cluster $CLUSTER not found"
  echo "version: $(val "select public.motionpos_version_public()")"
  echo "api: $(systemctl is-active motionpos-api) $(api_test)"
  echo "site: $(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$DOMAIN/")"
  ls -1t "$BACKUPS" 2>/dev/null | head -3
  ;;

*)
  fail "Unknown step $STEP (install | restore <file> | update | sql <file> | status)"
  ;;
esac
