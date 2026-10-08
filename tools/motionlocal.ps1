# Motion POS - shop server on this PC (database + API + screens), works on any Windows PC
# Usage: powershell -ExecutionPolicy Bypass -File motionlocal.ps1 -Step setup|start|stop|status|update|cloud|sync|syncloop|compare|backup|run|autostart|autostart-off [-Rebuild] [-Repo D:\SmartPOS] [-Root D:\MotionLocal]
param([string]$Step = 'status', [switch]$Rebuild, [string]$Repo = 'D:\SmartPOS', [string]$Root = 'D:\MotionLocal')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PgDir   = Join-Path $Root 'pgsql'
$PgBin   = Join-Path $PgDir 'bin'
$ApiDir  = Join-Path $Root 'postgrest'
$CadDir  = Join-Path $Root 'caddy'
$Www     = Join-Path $Root 'www'
$Data    = Join-Path $Root 'data'
$Logs    = Join-Path $Root 'logs'
$Secret  = Join-Path $Root 'secret'
$Dl      = Join-Path $Root 'downloads'
$DbPort  = 54329
$ApiPort = 54330
$WebPort = 8080
$DbName  = 'motionpos'
$MinCommit = '0bee7b9'
try { $UserDl = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch { $UserDl = Join-Path $env:USERPROFILE 'Downloads' }

$PgUrls = @(
  'https://get.enterprisedb.com/postgresql/postgresql-17.11-3-windows-x64-binaries.zip',
  'https://get.enterprisedb.com/postgresql/postgresql-17.11-2-windows-x64-binaries.zip',
  'https://get.enterprisedb.com/postgresql/postgresql-17.11-1-windows-x64-binaries.zip')
$ApiUrls = @(
  'https://github.com/PostgREST/postgrest/releases/download/v16.2/postgrest-v16.2-windows-x86-64.zip')
$CadUrls = @(
  'https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_windows_amd64.zip')

# database files in order, fingerprint = sha256 after removing CR, first 16
$Files = [ordered]@{
  'supabase\backup\schema_2026-10-06.sql'                         = '078b2d6e289aa387'
  'supabase\migrations\001_hash_staff_pins.sql'                   = 'db5649002b6d3cdd'
  'supabase\migrations\002_staff_login.sql'                       = '590b294844b567a0'
  'supabase\migrations\003_staff_sessions.sql'                    = 'a13c4ef35cf50dd5'
  'supabase\migrations\004_list_branch_staff.sql'                 = 'dbf06b8a41be43c4'
  'supabase\migrations\005_lock_staff.sql'                        = '799084e403e47d26'
  'supabase\migrations\006_manager_pin_limit_and_secure_void.sql' = 'd79b08d93d70d755'
  'supabase\migrations\007_close_old_void_lock_unused_tables.sql' = '845ba22e79ff793f'
  'supabase\migrations\008_server_order_item_submission.sql'      = '0a87c61ec0cc24b4'
  'supabase\migrations\009_server_order_totals.sql'               = 'ca7b352b7e4ce76c'
  'supabase\migrations\010_phase2_order_engine.sql'               = 'b4b5ead02f18add1'
  'supabase\migrations\011_phases_3_to_7.sql'                     = 'a896aa27b2eba8a6'
  'supabase\migrations\012_phases_8_to_11.sql'                    = 'ea19dacef0ac4e8c'
  'supabase\migrations\013_phase12_customer_requests.sql'         = 'b1098a8634d29849'
  'supabase\migrations\014_phase12_fixes.sql'                     = '7a5ef7eff86194f6'
  'supabase\migrations\015_phase13_sync_log.sql'                  = '8066e2b93300489a'
  'supabase\migrations\016_phase13_sync_engine.sql'               = '8ca679605935e4de'
  'supabase\migrations\017_phase13_sync_admin.sql'                = '7acb02b62e6f7e85'
  'supabase\migrations\018_phase13_sync_heartbeat_fix.sql'        = '9d2be902543b6250'
  'supabase\migrations\019_fixes2_whatsapp.sql'                 = '917bbfa5ca0a09c2'
}
$LastVersion = '019'

function Ok($m)   { Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m) { Write-Host "[..]   $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }
function Get-Fp($p) {
  $enc = [Text.Encoding]::GetEncoding(28591)
  $t = $enc.GetString([IO.File]::ReadAllBytes($p)).Replace("`r", '')
  $h = [Security.Cryptography.SHA256]::Create().ComputeHash($enc.GetBytes($t))
  (($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}
function New-Pass {
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
  $b = New-Object byte[] 24
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  -join ($b | ForEach-Object { $chars[$_ % $chars.Length] })
}
function Get-Code($url) { try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).StatusCode } catch { try { [int]$_.Exception.Response.StatusCode } catch { 0 } } }
function Get-Download($urls, $name) {
  foreach ($u in $urls) {
    $leaf = [IO.Path]::GetFileName($u); $out = Join-Path $Dl $leaf; $inUser = Join-Path $UserDl $leaf
    if ((-not (Test-Path $out)) -and (Test-Path $inUser)) { Move-Item $inUser $out -Force; Ok "$name taken from Downloads" }
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 1MB) { Ok "$name ready: $leaf"; return $out }
  }
  foreach ($u in $urls) {
    $out = Join-Path $Dl ([IO.Path]::GetFileName($u))
    Info "Downloading $name : $u"
    try { Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing -ErrorAction Stop; if ((Get-Item $out).Length -gt 1MB) { Ok "$name downloaded"; return $out } } catch { Info '  not available, trying next' }
    if (Test-Path $out) { Remove-Item $out -Force }
  }
  Fail "Could not get $name. Download it in the browser into $UserDl and run again: $($urls[0])"
}
function Use-Env {
  if ($env:PATH -notlike "*$PgBin*") { $env:PATH = "$PgBin;$env:PATH" }
  $env:PGCLIENTENCODING = 'UTF8'
  $pf = Join-Path $Secret 'db_superuser.txt'
  if (Test-Path $pf) { $env:PGPASSWORD = (Get-Content $pf -Raw).Trim() }
}
function Invoke-Sql($file, $db = $DbName) {
  $log = Join-Path $Logs ('sql_' + [IO.Path]::GetFileNameWithoutExtension($file) + '.log')
  & psql -X -q -v ON_ERROR_STOP=1 -h localhost -p $DbPort -U postgres -d $db -f $file *> $log
  if ($LASTEXITCODE -ne 0) {
    Write-Host "----- last lines of $log -----" -ForegroundColor Yellow
    Get-Content $log -Tail 25 | ForEach-Object { Write-Host $_ }
    Fail "SQL failed: $(Split-Path $file -Leaf)"
  }
  return $log
}
function Get-Val($sql, $db = $DbName) {
  $r = & psql -X -A -t -h localhost -p $DbPort -U postgres -d $db -c $sql 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "Query failed: $sql :: $r" }
  ($r | Out-String).Trim()
}
function Invoke-PgCtl([string]$a) {
  $p = Start-Process -FilePath (Join-Path $PgBin 'pg_ctl.exe') -ArgumentList $a -WindowStyle Hidden -PassThru
  $null = $p.Handle; $p.WaitForExit(); return $p.ExitCode
}
function Test-DbUp { & (Join-Path $PgBin 'pg_isready.exe') -h localhost -p $DbPort *> $null; return ($LASTEXITCODE -eq 0) }
function Start-Db {
  if (Test-DbUp) { Ok "Database running (port $DbPort)"; return }
  Invoke-PgCtl "-D `"$Data`" -l `"$(Join-Path $Logs 'db.log')`" -w -t 60 start" | Out-Null
  if (-not (Test-DbUp)) { Get-Content (Join-Path $Logs 'db.log') -Tail 20; Fail 'Database did not start' }
  Ok "Database running (port $DbPort)"
}
function Get-ApiExe { Get-ChildItem $ApiDir -Recurse -Filter 'postgrest.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Test-ApiUp { (Get-Code "http://127.0.0.1:$ApiPort/") -eq 200 }
function Start-Api {
  if (Test-ApiUp) { Ok "API running (port $ApiPort)"; return }
  $exe = Get-ApiExe; $conf = Join-Path $Root 'api\postgrest.conf'
  Start-Process -FilePath $exe.FullName -ArgumentList "`"$conf`"" -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $Logs 'api.log') -RedirectStandardError (Join-Path $Logs 'api_err.log') | Out-Null
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep 1; if (Test-ApiUp) { Ok "API running (port $ApiPort)"; return } }
  Get-Content (Join-Path $Logs 'api_err.log') -Tail 20 -ErrorAction SilentlyContinue
  Fail 'API did not start'
}
function Start-Web {
  if ((Get-Code "http://127.0.0.1:$WebPort/") -eq 200) { Ok "Screens running (port $WebPort)"; return }
  if (Get-NetTCPConnection -LocalPort $WebPort -State Listen -ErrorAction SilentlyContinue) { Fail "Port $WebPort is used by another program" }
  Start-Process -FilePath (Join-Path $CadDir 'caddy.exe') -ArgumentList "run --config `"$(Join-Path $CadDir 'Caddyfile')`" --adapter caddyfile" `
    -WorkingDirectory $CadDir -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Logs 'web.log') -RedirectStandardError (Join-Path $Logs 'web_err.log') | Out-Null
  for ($i = 0; $i -lt 15; $i++) { Start-Sleep 1; if ((Get-Code "http://127.0.0.1:$WebPort/") -eq 200) { Ok "Screens running (port $WebPort)"; return } }
  Get-Content (Join-Path $Logs 'web_err.log') -Tail 15 -ErrorAction SilentlyContinue
  Fail 'Screens server did not start'
}
function Test-All {
  try {
    $v = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$WebPort/rest/v1/rpc/motionpos_version_public" -Body '{}' -ContentType 'application/json' `
         -Headers @{ apikey = 'x'; Authorization = 'Bearer x' } -ErrorAction Stop
    $i = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$WebPort/rest/v1/rpc/motionpos_sync_info_public" -Body '{}' -ContentType 'application/json' -ErrorAction Stop
  } catch { Fail "Database through the screens server failed: $($_.Exception.Message)" }
  Ok "Through the screens server: version $v, node=$($i.node), logged_tables=$($i.logged_tables), guarded_tables=$($i.guarded_tables)"
  foreach ($p in '/vendor/tailwind.js', '/vendor/supabase.js', '/vendor/fonts/cairo.css') { $c = Get-Code "http://127.0.0.1:$WebPort$p"; if ($c -ne 200) { Fail "$p -> $c" } }
  Ok 'Local copies are served'
  $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -in 'Dhcp', 'Manual' }
  Ok "On this PC: http://localhost:$WebPort"
  foreach ($ip in $ips) { Ok "From a phone on the same Wi-Fi: http://$($ip.IPAddress):$WebPort   ($($ip.InterfaceAlias))" }
}

function Get-CloudConn {
  $f = Join-Path $Secret 'cloud_conn.dat'
  if (-not (Test-Path $f)) { Fail 'Cloud connection not saved yet. Run -Step cloud first.' }
  $ss = Get-Content $f | ConvertTo-SecureString
  [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
}
function Hide($text, $conn) { ($text | Out-String).Replace($conn, '<cloud>').Trim() }
function Invoke-SyncRound($conn) {
  $out = "select public.pos_sync_run(:'conn', 500)::text;" |
         & psql -X -A -t -v ON_ERROR_STOP=1 -v "conn=$conn" -h localhost -p $DbPort -U postgres -d $DbName -f - 2>&1
  if ($LASTEXITCODE -ne 0) { return @{ ok = $false; msg = (Hide $out $conn) } }
  try { return @{ ok = $true; r = ((Hide $out $conn) | ConvertFrom-Json) } } catch { return @{ ok = $false; msg = (Hide $out $conn) } }
}
function Invoke-Backup([switch]$Force) {
  $bd = Join-Path $Root 'backups'
  if (-not (Test-Path $bd)) { New-Item -ItemType Directory $bd -Force | Out-Null }
  $f = Join-Path $bd ("motionpos_" + (Get-Date -Format 'yyyy-MM-dd') + '.dump')
  if ((Test-Path $f) -and -not $Force) { return $null }
  & (Join-Path $PgBin 'pg_dump.exe') -h localhost -p $DbPort -U postgres -d $DbName -Fc -f $f *> (Join-Path $Logs 'backup.log')
  if ($LASTEXITCODE -ne 0) { return "backup FAILED (see logs\backup.log)" }
  Get-ChildItem $bd -Filter 'motionpos_*.dump' | Sort-Object Name -Descending | Select-Object -Skip 14 | Remove-Item -Force
  return "backup saved: $(Split-Path $f -Leaf) ($([math]::Round((Get-Item $f).Length/1KB)) KB)"
}
# keep database, API and screens alive (programs started from a PowerShell window die when that window closes)
function Ensure-Services($log) {
  $notes = @()
  if (-not (Test-DbUp)) {
    Invoke-PgCtl "-D `"$Data`" -l `"$(Join-Path $Logs 'db.log')`" -w -t 60 start" | Out-Null
    $notes += $(if (Test-DbUp) { 'database was stopped - started again' } else { 'database is stopped and did not start (see logs\db.log)' })
  }
  if (-not (Test-ApiUp)) {
    Get-Process postgrest -ErrorAction SilentlyContinue | Stop-Process -Force
    $exe = Get-ApiExe
    Start-Process -FilePath $exe.FullName -ArgumentList "`"$(Join-Path $Root 'api\postgrest.conf')`"" -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $Logs 'api.log') -RedirectStandardError (Join-Path $Logs 'api_err.log') | Out-Null
    for ($i = 0; $i -lt 20 -and -not (Test-ApiUp); $i++) { Start-Sleep 1 }
    $notes += $(if (Test-ApiUp) { 'API was stopped - started again' } else { 'API is stopped and did not start (see logs\api_err.log)' })
  }
  if ((Get-Code "http://127.0.0.1:$WebPort/") -ne 200) {
    Get-Process caddy -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process -FilePath (Join-Path $CadDir 'caddy.exe') -ArgumentList "run --config `"$(Join-Path $CadDir 'Caddyfile')`" --adapter caddyfile" `
      -WorkingDirectory $CadDir -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Logs 'web.log') -RedirectStandardError (Join-Path $Logs 'web_err.log') | Out-Null
    for ($i = 0; $i -lt 15 -and (Get-Code "http://127.0.0.1:$WebPort/") -ne 200; $i++) { Start-Sleep 1 }
    $notes += $(if ((Get-Code "http://127.0.0.1:$WebPort/") -eq 200) { 'screens were stopped - started again' } else { 'screens are stopped and did not start (see logs\web_err.log)' })
  }
  foreach ($n in $notes) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') FIX  $n"; Add-Content $log $line; Write-Host $line -ForegroundColor Yellow }
}
function Invoke-SyncLoop {
  $mutex = New-Object Threading.Mutex($false, 'Local\MotionPOSSyncLoop')
  if (-not $mutex.WaitOne(0)) { Fail 'Another sync loop is already running on this PC (window or automatic start). Close it first.' }
  $conn = Get-CloudConn
  $log = Join-Path $Logs 'sync.log'
  Write-Host 'Sync every 30 seconds. Leave this window open (minimize it). Ctrl+C or close to stop.' -ForegroundColor Yellow
  while ($true) {
    Ensure-Services $log
    if (Test-Path (Join-Path $Root 'sync.pause')) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') paused" -ForegroundColor DarkYellow; Start-Sleep 30; continue }
    $b = Invoke-Backup
    if ($b) { Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $b"; Write-Host $b -ForegroundColor Cyan }
    $i = 0
    do {
      $i++
      $x = Invoke-SyncRound $conn
      $t = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
      if ($x.ok) { $line = "$t OK   " + (Show-Round $i $x.r); $more = $x.r.more } else { $line = "$t FAIL " + $x.msg; $more = $false }
      if ($x.ok -and ($x.r.pulled + $x.r.pushed + $x.r.conflicts + $x.r.errors) -eq 0) { Write-Host "$t idle" -ForegroundColor DarkGray }
      else { Add-Content $log $line; if ($x.ok) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red } }
    } while ($more -and $i -lt 40)
    if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 5MB) { Move-Item $log "$log.old" -Force }
    Start-Sleep 30
  }
}
function Show-Round($i, $r) {
  $fc = if ($r.first_copy -ne $null) { " first_copy=$($r.first_copy) rows" } else { '' }
  "round $i :$fc pulled=$($r.pulled) pushed=$($r.pushed) conflicts=$($r.conflicts) errors=$($r.errors)"
}

foreach ($d in $Root, $Logs, $Secret, $Dl, (Join-Path $Root 'api'), $CadDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null } }

switch ($Step) {

'setup' {
  # 1) repo up to date and clean
  if (-not (Test-Path (Join-Path $Repo '.git'))) { Fail "No repo at $Repo" }
  Set-Location $Repo
  $br = (git rev-parse --abbrev-ref HEAD).Trim(); if ($br -ne 'dev') { Fail "Repo is on branch $br, not dev" }
  $st = git status --short; if ($st) { Fail "Repo has changes:`n$st" }
  git fetch -q origin; if ($LASTEXITCODE -ne 0) { Fail 'Could not reach GitHub' }
  $before = (git rev-parse --short HEAD).Trim()
  git merge -q --ff-only origin/dev; if ($LASTEXITCODE -ne 0) { Fail 'Repo could not be updated (not a straight update)' }
  $head = (git rev-parse --short HEAD).Trim()
  git merge-base --is-ancestor $MinCommit HEAD; if ($LASTEXITCODE -ne 0) { Fail "Repo $head does not contain $MinCommit" }
  Ok "Repo updated $before -> $head (same as GitHub dev)"
  foreach ($k in $Files.Keys) {
    $p = Join-Path $Repo $k; if (-not (Test-Path $p)) { Fail "Missing $k" }
    if ((Get-Fp $p) -ne $Files[$k]) { Fail "Fingerprint mismatch $k" }
  }
  Ok "All $($Files.Count) database files match"
  if (-not (Test-Path (Join-Path $Repo 'vendor\tailwind.js'))) { Fail 'Repo has no vendor folder' }
  $free = [math]::Round((Get-PSDrive ($Root.Substring(0,1))).Free / 1GB, 1)
  if ($free -lt 5) { Fail "$($Root.Substring(0,2)) has only $free GB free" } else { Ok "$($Root.Substring(0,2)) free space $free GB" }

  # 2) programs
  if (-not (Test-Path (Join-Path $PgBin 'postgres.exe'))) {
    $z = Get-Download $PgUrls 'Database program'
    Info 'Extracting database program (a few minutes, the screen stays quiet)...'
    & tar.exe -xf $z -C $Root; if ($LASTEXITCODE -ne 0) { Fail 'Extract failed (file incomplete? download it again)' }
    foreach ($x in 'pgAdmin 4', 'StackBuilder', 'doc', 'symbols') { $p = Join-Path $PgDir $x; if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
  }
  $v = & (Join-Path $PgBin 'postgres.exe') -V 2>&1
  if ("$v" -notmatch '17\.') { Fail "Database program does not run: $v" }
  Ok "Database program: $v"
  if (-not (Get-ApiExe)) {
    $z = Get-Download $ApiUrls 'API program'
    New-Item -ItemType Directory $ApiDir -Force | Out-Null
    & tar.exe -xf $z -C $ApiDir; if ($LASTEXITCODE -ne 0) { Fail 'Extract failed' }
  }
  Use-Env
  $av = & (Get-ApiExe).FullName --version 2>&1; Ok "API program: $($av | Select-Object -First 1)"
  if (-not (Test-Path (Join-Path $CadDir 'caddy.exe'))) {
    $z = Get-Download $CadUrls 'Screens server program'
    & tar.exe -xf $z -C $CadDir; if ($LASTEXITCODE -ne 0) { Fail 'Extract failed' }
  }
  $cv = & (Join-Path $CadDir 'caddy.exe') version 2>&1; Ok "Screens server program: $(("$cv" -split ' ')[0])"

  # 3) database
  if (Test-Path $Data) {
    if (-not $Rebuild) { Fail 'Local database already exists. Add -Rebuild to wipe it and build again.' }
    Get-Process postgrest -ErrorAction SilentlyContinue | Stop-Process -Force
    Invoke-PgCtl "-D `"$Data`" -w stop -m fast" | Out-Null
    Remove-Item $Data -Recurse -Force; Ok 'Old local database removed'
  }
  $su = New-Pass; $au = New-Pass
  Set-Content (Join-Path $Secret 'db_superuser.txt') $su -Encoding ASCII
  Set-Content (Join-Path $Secret 'db_authenticator.txt') $au -Encoding ASCII
  $pw = Join-Path $Secret 'tmp_pw.txt'; Set-Content $pw $su -Encoding ASCII
  Info 'Creating database storage'
  & initdb -D $Data -U postgres --pwfile=$pw -E UTF8 --locale=C --locale-provider=builtin --builtin-locale=C.UTF-8 -A scram-sha-256 *> (Join-Path $Logs 'initdb.log')
  if ($LASTEXITCODE -ne 0) {
    if (Test-Path $Data) { Remove-Item $Data -Recurse -Force }
    & initdb -D $Data -U postgres --pwfile=$pw -E UTF8 --locale=C -A scram-sha-256 *> (Join-Path $Logs 'initdb.log')
  }
  $ic = $LASTEXITCODE; Remove-Item $pw -Force
  if ($ic -ne 0) { Get-Content (Join-Path $Logs 'initdb.log') -Tail 20; Fail 'Creating storage failed' }
  Add-Content (Join-Path $Data 'postgresql.conf') "`nlisten_addresses = 'localhost'`nport = $DbPort`ntimezone = 'UTC'`nlog_timezone = 'UTC'`n"
  Use-Env; Start-Db
  $pre = Join-Path $Logs 'pre_roles.sql'
  @"
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create role supabase_admin nologin;
create role authenticator login noinherit password '$au';
grant anon, authenticated, service_role to authenticator;
create database $DbName;
"@ | Set-Content $pre -Encoding ASCII
  Invoke-Sql $pre 'postgres' | Out-Null; Remove-Item $pre -Force
  $pre2 = Join-Path $Logs 'pre_schema.sql'
  "create schema extensions;`ncreate extension pgcrypto with schema extensions;`ngrant usage on schema extensions to anon, authenticated, service_role;`ndrop schema public cascade;`n" | Set-Content $pre2 -Encoding ASCII
  Invoke-Sql $pre2 | Out-Null; Remove-Item $pre2 -Force
  Ok 'Roles and helpers ready'
  foreach ($k in $Files.Keys) {
    Info "Running $(Split-Path $k -Leaf)"
    $log = Invoke-Sql (Join-Path $Repo $k)
    $n = ([regex]::Match((Split-Path $k -Leaf), '^(\d{3})_')).Groups[1].Value
    if ($n -and (Select-String -Path (Join-Path $Repo $k) -Pattern "MOTIONPOS-$n-SELFTEST-OK" -Quiet) -and -not (Select-String -Path $log -Pattern "MOTIONPOS-$n-SELFTEST-OK" -Quiet)) { Fail "$n self-test message missing" }
  }
  Get-Val "update public.sync_node set node = 'store', updated_at = now();" | Out-Null
  Get-Val 'create extension if not exists dblink with schema extensions;' | Out-Null
  $ver = Get-Val 'select public.motionpos_version_public();'
  $tb  = Get-Val "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE';"
  $fn  = Get-Val "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public';"
  if ($ver -ne $LastVersion) { Fail "Version is '$ver' not $LastVersion" }
  Ok "Database built: version $ver, tables $tb, functions $fn, marked as shop copy"

  # 4) API + screens settings
  @"
db-uri = "postgres://authenticator:$au@127.0.0.1:$DbPort/$DbName"
db-schemas = "public"
db-anon-role = "anon"
server-host = "127.0.0.1"
server-port = $ApiPort
"@ | Set-Content (Join-Path $Root 'api\postgrest.conf') -Encoding ASCII
  & robocopy $Repo $Www /MIR /NFL /NDL /NJH /NJS /NP /XD .git supabase docs tests tools /XF README.md .gitignore .vercelignore | Out-Null
  if ($LASTEXITCODE -ge 8) { Fail 'Copying the screens failed' }
  Ok "Screens copied to $Www (from $head)"
  $wf = $Www.Replace('\', '/')
  "{`n`tadmin off`n`tauto_https off`n}`n`n:$WebPort {`n`tencode gzip`n`thandle_path /rest/v1/* {`n`t`treverse_proxy 127.0.0.1:$ApiPort {`n`t`t`theader_up -Authorization`n`t`t}`n`t}`n`thandle {`n`t`troot * $wf`n`t`tfile_server`n`t}`n}`n" |
    Set-Content (Join-Path $CadDir 'Caddyfile') -Encoding ASCII
  $vr = & (Join-Path $CadDir 'caddy.exe') validate --config (Join-Path $CadDir 'Caddyfile') --adapter caddyfile 2>&1
  if ($LASTEXITCODE -ne 0) { $vr | Select-Object -Last 10; Fail 'Screens server settings invalid' }
  Ok 'Settings written'
  Start-Api; Start-Web; Test-All
  Write-Host 'SETUP DONE' -ForegroundColor Green
}

'start'  { Use-Env; Start-Db; Start-Api; Start-Web; Test-All }
'update' {
  # copy the latest screens from the repo to the shop server folder
  Set-Location $Repo
  $st = git status --short; if ($st) { Fail "Repo has changes:`n$st" }
  & robocopy $Repo $Www /MIR /NFL /NDL /NJH /NJS /NP /XD .git supabase docs tests tools /XF README.md .gitignore .vercelignore | Out-Null
  if ($LASTEXITCODE -ge 8) { Fail 'Copying the screens failed' }
  Ok "Screens on this PC updated to $((git rev-parse --short HEAD).Trim())"
}
'stop'   {
  Get-Process caddy, postgrest -ErrorAction SilentlyContinue | Stop-Process -Force; Ok 'Screens server and API stopped'
  Use-Env; Invoke-PgCtl "-D `"$Data`" -w stop -m fast" | Out-Null; Ok 'Database stopped'
}
'status' {
  Use-Env
  if (Test-DbUp) { Ok "Database running (port $DbPort)" } else { Info 'Database stopped' }
  if (Test-ApiUp) { Ok "API running (port $ApiPort)" } else { Info 'API stopped' }
  if ((Get-Code "http://127.0.0.1:$WebPort/") -eq 200) { Ok "Screens running (port $WebPort)" } else { Info 'Screens stopped' }
  if (Test-Path (Join-Path $Root 'sync.pause')) { Info 'Sync PAUSED - run -Step resume' }
  $ts = (Get-ScheduledTask -TaskName 'MotionPOS Shop Server' -ErrorAction SilentlyContinue).State
  if ($ts) { Info "Automatic start: $ts" } else { Info 'Automatic start: not set' }
  if (Test-DbUp) { Info "Last good sync (UTC): $(Get-Val "select coalesce((select s.value from public.sync_state s where s.key = 'last_ok'), 'never');")" }
}

'cloud' {
  Use-Env; Start-Db
  Get-Val 'create extension if not exists dblink with schema extensions;' | Out-Null
  Write-Host 'Supabase > Connect > Session pooler > copy the string (it contains [YOUR-PASSWORD])' -ForegroundColor Yellow
  $uri = (Read-Host 'Paste the Session pooler connection string').Trim()
  if ($uri -notmatch '^postgres(ql)?://[^:/]+:\[YOUR-PASSWORD\]@[^/]+/postgres') { Fail 'This is not the Session pooler string with [YOUR-PASSWORD] in it' }
  $sp = Read-Host 'Cloud database password (hidden)' -AsSecureString
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp))
  if (-not $plain) { Fail 'Empty password' }
  $conn = $uri.Replace('[YOUR-PASSWORD]', [uri]::EscapeDataString($plain))
  if ($conn -notmatch '\?') { $conn += '?sslmode=require' }
  $saved = $env:PGPASSWORD; Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  $v = & psql $conn -X -A -t -c 'select public.motionpos_version_public();' 2>&1
  $code = $LASTEXITCODE; $env:PGPASSWORD = $saved
  if ($code -ne 0) { Fail "Could not reach the cloud database: $(Hide $v $conn)" }
  $v = ($v | Out-String).Trim()
  ConvertTo-SecureString $conn -AsPlainText -Force | ConvertFrom-SecureString | Set-Content (Join-Path $Secret 'cloud_conn.dat')
  Ok "Cloud database reached (version $v). Connection saved encrypted for this Windows user."
  $lv = Get-Val 'select public.motionpos_version_public();'
  if ($v -ne $lv) { Fail "Versions differ: cloud $v, this PC $lv" }
  Ok "Versions match ($v)"
}

'sync' {
  Use-Env; Start-Db
  $conn = Get-CloudConn
  for ($i = 1; $i -le 40; $i++) {
    $x = Invoke-SyncRound $conn
    if (-not $x.ok) { Fail "Sync failed: $($x.msg)" }
    Ok (Show-Round $i $x.r)
    if (-not $x.r.more) { break }
  }
  $info = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ApiPort/rpc/motionpos_sync_info_public" -Body '{}' -ContentType 'application/json' -ErrorAction SilentlyContinue
  if ($info) { Ok "Last good sync: $($info.last_ok)  open conflicts/errors: $($info.open_conflicts)" }
  Write-Host 'SYNC DONE' -ForegroundColor Green
}


'syncloop' { Use-Env; Start-Db; Invoke-SyncLoop }

'run' {
  # what the automatic start runs: everything up, then sync forever
  Use-Env; Start-Db; Start-Api; Start-Web; Invoke-SyncLoop
}

'backup' {
  Use-Env; Start-Db
  $b = Invoke-Backup -Force
  if ($b -like '*FAILED*') { Fail $b } else { Ok $b }
  Ok "Backups folder: $(Join-Path $Root 'backups') (last 14 days kept)"
}

'compare' {
  # same data on both sides? (run it when the sync window says idle)
  Use-Env; Start-Db
  $conn = Get-CloudConn
  $list = Get-Val "select string_agg(c.relname, ',' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and c.relname not in ('sync_log', 'sync_node', 'sync_state', 'sync_runs', 'login_attempts', 'manager_pin_attempts', 'staff_sessions', 'order_sequences')"
  $q = "set timezone = 'UTC';`n" + ((($list -split ',') | ForEach-Object { "select '$_', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text collate `"C`"), '')) from (select to_jsonb(r) as x from public.$_ r) s" }) -join "`nunion all ") + ";`n"
  $qf = Join-Path $Logs 'compare.sql'; Set-Content $qf $q -Encoding ASCII
  $mine = & psql -X -q -A -t -F '|' -h localhost -p $DbPort -U postgres -d $DbName -f $qf 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "Local compare failed: $mine" }
  $saved = $env:PGPASSWORD; Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  $theirs = & psql $conn -X -q -A -t -F '|' -f $qf 2>&1
  $code = $LASTEXITCODE; $env:PGPASSWORD = $saved
  if ($code -ne 0) { Fail "Cloud compare failed: $(Hide $theirs $conn)" }
  $m = @{}; foreach ($l in $mine) { $p = "$l".Split('|'); if ($p.Count -eq 3) { $m[$p[0]] = $p } }
  $c = @{}; foreach ($l in $theirs) { $p = "$l".Split('|'); if ($p.Count -eq 3) { $c[$p[0]] = $p } }
  $diff = 0; $rows = 0
  foreach ($t in ($list -split ',')) {
    $a = $m[$t]; $b = $c[$t]
    if (-not $b) { Write-Host "[DIFF] $t : missing on the cloud" -ForegroundColor Red; $diff++; continue }
    $rows += [int]$a[1]
    if ($a[2] -ne $b[2]) { Write-Host "[DIFF] $t : shop $($a[1]) rows, cloud $($b[1]) rows, content differs" -ForegroundColor Red; $diff++ }
  }
  if ($diff) { Fail "$diff tables differ (if the sync window was not idle, wait for idle and compare again)" }
  Ok "All $($m.Count) tables identical on this PC and the cloud ($rows rows)"
  Write-Host 'COMPARE DONE' -ForegroundColor Green
}

'pause'  { Set-Content (Join-Path $Root 'sync.pause') (Get-Date -Format s) -Encoding ASCII; Ok 'Sync paused (like the shop internet is down). Screens keep working. Run -Step resume to continue.' }
'resume' { Remove-Item (Join-Path $Root 'sync.pause') -Force -ErrorAction SilentlyContinue; Ok 'Sync resumed (next round within 30 seconds)' }
'autostart' {
  # start everything automatically when this Windows user logs in (no admin needed)
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Step run -Repo `"$Repo`" -Root `"$Root`""
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $me
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
         -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  $prn = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
  try { Register-ScheduledTask -TaskName 'MotionPOS Shop Server' -Action $act -Trigger $trg -Settings $set -Principal $prn -Force -ErrorAction Stop | Out-Null }
  catch { Fail "Could not create the automatic start: $($_.Exception.Message)" }
  Ok "Automatic start created for $me (runs at Windows sign-in, hidden, restarts itself if it stops)"
  Start-ScheduledTask -TaskName 'MotionPOS Shop Server'
  Start-Sleep 15
  $st = (Get-ScheduledTask -TaskName 'MotionPOS Shop Server').State
  if ($st -ne 'Running') { Fail "Automatic start is '$st' - is a sync window still open? close it and run autostart again" }
  Ok 'Running now in the background'
  Use-Env
  if ((Get-Code "http://127.0.0.1:$WebPort/") -eq 200) { Ok "Screens answer on http://localhost:$WebPort" } else { Fail 'Screens do not answer' }
  Ok "Sync log: $(Join-Path $Logs 'sync.log')"
}

'autostart-off' {
  Unregister-ScheduledTask -TaskName 'MotionPOS Shop Server' -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*motionlocal.ps1*-Step run*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  Ok 'Automatic start removed and background sync stopped (database and screens keep running until -Step stop)'
}

default { Fail "Unknown step $Step" }
}
