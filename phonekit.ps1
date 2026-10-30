<#
  Телефон-набор — рабочий инструмент мастера для телефонов и планшетов Android
  (Samsung, Xiaomi / Redmi / Poco, Realme / OPPO, Honor / Huawei, Motorola, Pixel и любые другие).
  Сценарий: мастер подключается к ноутбуку клиента по AnyDesk (или работает на своём ПК),
  копирует туда папку phone-kit, запускает start.bat (Windows) или start.command (Mac).
  Телефон — кабелем USB или по Wi-Fi через код сопряжения (Android 11+).
  Ничего вводить в консоль руками не нужно.

  Меню: 1) диагностика — только чтение (белый список команд чтения, Test-ReadOnly);
        2) оптимизация — диагностика, план с галочками, «да», изменения партиями с проверкой,
           только обратимые команды из белого списка записи (Test-WriteAllowed), журнал для отката;
        3) откат по журналу.

  Параметры (необязательно):
    -Prepare             подготовить папку tools (ADB для Windows и Mac) и выйти
    -Address IP:порт     подключиться к телефону по Wi-Fi
    -Label Максим        метка клиента для папки отчёта
    -AdbPath путь/adb    свой adb
    -NoPause             не ждать Enter в конце
    -Lang en             язык (ru uk en pt es fr it de lv pl); по умолчанию — язык системы
    -Console             только консоль, без страницы в браузере
    -Web -NoBrowser      страница без автозапуска браузера (адрес печатается в консоли)
    -NoUpdateCheck       не проверять новую версию на GitHub

  База пакетов (data/uad.tsv) — из Universal Android Debloater Next Generation
  (github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation, GPL-3.0),
  русские пояснения и наши правила — data/ru.tsv.
#>
param(
  [switch]$Prepare,
  [string]$Address = '',
  [string]$Label = '',
  [string]$AdbPath = '',
  [string]$Lang = '',
  [switch]$Console,
  [switch]$Web,
  [switch]$NoBrowser,
  [switch]$NoUpdateCheck,
  [string]$UpdateUrl = '',
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$KitVersion = '1.0'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$IsWin = ($env:OS -eq 'Windows_NT')
$IsMac = (-not $IsWin) -and (Test-Path '/System/Library/CoreServices/Finder.app')

# ----------------------------------------------------------------- языки
# Все тексты — в data/lang/<код>.json (ключ -> шаблон с {0}, {1}...). Нет перевода — английский, потом русский.
$KitLangs = @('ru', 'uk', 'en', 'pt', 'es', 'fr', 'it', 'de', 'lv', 'pl')
function Read-LangFile([string]$code) {
  $h = @{}
  $p = Join-Path (Join-Path (Join-Path $Root 'data') 'lang') ($code + '.json')
  if (Test-Path -LiteralPath $p) {
    try { $o = (Get-Content -LiteralPath $p -Raw -Encoding UTF8) | ConvertFrom-Json; foreach ($pr in $o.PSObject.Properties) { $h[$pr.Name] = [string]$pr.Value } } catch {}
  }
  return ,$h
}
function Set-KitLang([string]$code) {
  $code = ([string]$code).ToLower()
  if ($KitLangs -notcontains $code) { $code = 'en' }
  $script:Lang = $code
  $script:Tr = Read-LangFile $code
}
$script:TrRu = Read-LangFile 'ru'
$script:TrEn = Read-LangFile 'en'
if (-not $Lang) { try { $Lang = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName } catch { $Lang = 'en' } }
Set-KitLang $Lang
function L([string]$k) {
  $t = $script:Tr[$k]
  if (-not $t) { $t = $script:TrEn[$k] }
  if (-not $t) { $t = $script:TrRu[$k] }
  if (-not $t) { return $k }
  if ($args.Count) { return ($t -f @($args | ForEach-Object { [string]$_ })) }
  return $t
}

# ----------------------------------------------------------------- интерфейс в браузере
# Страница ui/index.html на этом же компьютере (127.0.0.1, случайный порт и ключ в адресе).
# Сервер — в отдельном потоке (runspace); общение — через синхронизированную таблицу $script:WebUi.
# Отвечать можно и на странице, и в консоли: что первое — то и принято.
$script:WebUi = $null
function Sync-Web {
  $w = $script:WebUi
  if (-not $w) { return }
  $lr = $w.langReq
  if ($lr) { $w.langReq = $null; Set-KitLang $lr; $w.lang = $script:Lang }
}
function Emit([string]$type, $data) {
  $w = $script:WebUi
  if (-not $w) { return }
  [System.Threading.Monitor]::Enter($w.SyncRoot)
  try { $w.seq = [int]$w.seq + 1; [void]$w.events.Add([ordered]@{ seq = $w.seq; type = $type; data = $data }) }
  finally { [System.Threading.Monitor]::Exit($w.SyncRoot) }
  Sync-Web
}
# kind: text | code6 | addr | menu | confirm | enter | plan;  options: @(@{ key; label }), extra: что угодно для страницы
function Ask([string]$prompt, [string]$kind = 'text', $options = $null, $extra = $null) {
  $w = $script:WebUi
  if (-not $w) { return ([string](Read-Host $prompt)).Trim() }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
  $q = [ordered]@{ id = $id; prompt = $prompt; kind = $kind; options = $options; extra = $extra }
  [System.Threading.Monitor]::Enter($w.SyncRoot)
  try { $w.answer = $null; $w.question = $q } finally { [System.Threading.Monitor]::Exit($w.SyncRoot) }
  Write-Host ($prompt + ': ') -NoNewline
  $buf = ''; $canKey = $true
  while ($true) {
    $ans = $null
    [System.Threading.Monitor]::Enter($w.SyncRoot)
    try { if ($w.answer -and $w.answer.id -eq $id) { $ans = [string]$w.answer.value; $w.answer = $null; $w.question = $null } }
    finally { [System.Threading.Monitor]::Exit($w.SyncRoot) }
    if ($null -ne $ans) { if ($kind -eq 'plan') { Write-Host '' } else { Write-Host $ans }; return $ans.Trim() }
    Sync-Web
    if ($canKey) {
      try {
        while ([Console]::KeyAvailable) {
          $k = [Console]::ReadKey($true)
          if ($k.Key -eq 'Enter') {
            Write-Host ''
            [System.Threading.Monitor]::Enter($w.SyncRoot); try { $w.question = $null } finally { [System.Threading.Monitor]::Exit($w.SyncRoot) }
            return $buf.Trim()
          } elseif ($k.Key -eq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1); Write-Host "`b `b" -NoNewline } }
          elseif ([int]$k.KeyChar -ge 32) { $buf += $k.KeyChar; Write-Host $k.KeyChar -NoNewline }
        }
      } catch { $canKey = $false }
    }
    Start-Sleep -Milliseconds 120
  }
}
function Opt([string]$key, [string]$label) { return [ordered]@{ key = $key; label = $label } }

$WebServer = {
  param($W, $Listener, $Html, $LangDir, $Token)
  function Send($c, [int]$code, [string]$ctype, [byte[]]$body) {
    $st = $c.GetStream()
    $h = "HTTP/1.1 $code OK`r`nContent-Type: $ctype`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $st.Write($hb, 0, $hb.Length); if ($body.Length) { $st.Write($body, 0, $body.Length) }; $st.Flush()
  }
  function SendText($c, [int]$code, [string]$ctype, [string]$text) { Send $c $code $ctype ([Text.Encoding]::UTF8.GetBytes($text)) }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  while (-not $W.stop) {
    try {
      if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 30; continue }
      $c = $Listener.AcceptTcpClient()
    } catch { Start-Sleep -Milliseconds 100; continue }
    try {
      $c.ReceiveTimeout = 3000; $c.SendTimeout = 3000
      $st = $c.GetStream()
      $buf = New-Object byte[] 16384; $ms = New-Object System.IO.MemoryStream; $hdrEnd = -1
      while ($hdrEnd -lt 0 -and $ms.Length -lt 65536) {
        $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $hdrEnd = [Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
      }
      if ($hdrEnd -lt 0) { continue }
      $all = $ms.ToArray()
      $head = [Text.Encoding]::ASCII.GetString($all, 0, $hdrEnd)
      $lines = $head -split "`r`n"
      $parts = $lines[0] -split ' '
      $method = $parts[0]; $target = $parts[1]
      $len = 0
      foreach ($hl in $lines) { if ($hl -match '^(?i)content-length:\s*(\d+)') { $len = [int]$Matches[1] } }
      $bodyBytes = New-Object System.IO.MemoryStream
      $have = $all.Length - ($hdrEnd + 4)
      if ($have -gt 0) { $bodyBytes.Write($all, $hdrEnd + 4, $have) }
      while ($bodyBytes.Length -lt $len -and $len -le 1048576) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $bodyBytes.Write($buf, 0, $n) }
      $body = $utf8.GetString($bodyBytes.ToArray())
      $path = $target; $query = ''
      $qi = $target.IndexOf('?'); if ($qi -ge 0) { $path = $target.Substring(0, $qi); $query = $target.Substring($qi + 1) }
      $qs = @{}
      foreach ($kv in ($query -split '&')) { $p2 = $kv -split '=', 2; if ($p2.Count -eq 2) { $qs[$p2[0]] = [Uri]::UnescapeDataString($p2[1]) } }
      if ($path -eq '/' -or $path -eq '/index.html') { SendText $c 200 'text/html; charset=utf-8' $Html; continue }
      if ($path -eq '/favicon.ico') { Send $c 404 'text/plain' (New-Object byte[] 0); continue }
      if (-not $path.StartsWith('/api/') -or $qs['t'] -ne $Token) { SendText $c 403 'text/plain' 'forbidden'; continue }
      if ($path -eq '/api/state' -and $method -eq 'GET') {
        $since = 0; [void][int]::TryParse([string]$qs['since'], [ref]$since)
        [System.Threading.Monitor]::Enter($W.SyncRoot)
        try {
          $evs = New-Object System.Collections.ArrayList
          foreach ($e in $W.events) { if ($e.seq -gt $since) { [void]$evs.Add($e) } }
          $resp = [ordered]@{ seq = $W.seq; events = $evs.ToArray(); question = $W.question; lang = $W.lang; finished = [bool]$W.finished; kit = $W.kit }
        } finally { [System.Threading.Monitor]::Exit($W.SyncRoot) }
        SendText $c 200 'application/json; charset=utf-8' ($resp | ConvertTo-Json -Depth 10 -Compress); continue
      }
      if ($path -eq '/api/client' -and $method -eq 'GET') {
        $cf = [string]$W.clientFile
        if ($cf -and (Test-Path -LiteralPath $cf)) { Send $c 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($cf)) } else { SendText $c 404 'text/plain' 'no report yet' }
        continue
      }
      if ($path -eq '/api/lang' -and $method -eq 'GET') {
        $code = [string]$qs['code']
        if ($code -notmatch '^[a-z]{2}$') { SendText $c 400 'text/plain' 'bad'; continue }
        $f = Join-Path $LangDir ($code + '.json')
        if (-not (Test-Path -LiteralPath $f)) { SendText $c 200 'application/json; charset=utf-8' '{}'; continue }
        Send $c 200 'application/json; charset=utf-8' ([IO.File]::ReadAllBytes($f)); continue
      }
      if ($method -eq 'POST') {
        $o = $null; try { $o = $body | ConvertFrom-Json } catch {}
        if ($path -eq '/api/answer' -and $o) {
          [System.Threading.Monitor]::Enter($W.SyncRoot)
          try { if ($W.question -and $W.question.id -eq [string]$o.id) { $W.answer = @{ id = [string]$o.id; value = [string]$o.value } } }
          finally { [System.Threading.Monitor]::Exit($W.SyncRoot) }
          SendText $c 200 'application/json' '{"ok":true}'; continue
        }
        if ($path -eq '/api/lang' -and $o -and ([string]$o.code -match '^[a-z]{2}$')) { $W.langReq = [string]$o.code; $W.lang = [string]$o.code; SendText $c 200 'application/json' '{"ok":true}'; continue }
        if ($path -eq '/api/close') { $W.closeReq = $true; SendText $c 200 'application/json' '{"ok":true}'; continue }
      }
      SendText $c 404 'text/plain' 'not found'
    } catch {
    } finally { try { $c.Close() } catch {} }
  }
  try { $Listener.Stop() } catch {}
}

function Start-Web {
  $uiFile = Join-Path (Join-Path $Root 'ui') 'index.html'
  if (-not (Test-Path -LiteralPath $uiFile)) { return $false }
  $html = [IO.File]::ReadAllText($uiFile, [Text.Encoding]::UTF8)
  $chars = 'abcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
  $token = -join (1..20 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
  $listener = $null; $port = 0
  foreach ($p in (8731..8760)) {
    try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p); $l.Start(); $listener = $l; $port = $p; break } catch {}
  }
  if (-not $listener) { return $false }
  $w = [hashtable]::Synchronized(@{ events = (New-Object System.Collections.ArrayList); seq = 0; question = $null; answer = $null; lang = $script:Lang; langReq = $null; stop = $false; finished = $false; closeReq = $false; kit = $KitVersion })
  $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript($WebServer).AddArgument($w).AddArgument($listener).AddArgument($html).AddArgument((Join-Path (Join-Path $Root 'data') 'lang')).AddArgument($token)
  $script:WebAsync = $ps.BeginInvoke(); $script:WebPs = $ps
  $script:WebUi = $w
  $script:WebUrl = "http://127.0.0.1:$port/?t=$token"
  Say (L 'w001' $script:WebUrl) 'Cyan'
  Say (L 'w002') 'DarkGray'
  if (-not $NoBrowser) {
    try {
      if ($IsWin) { Start-Process $script:WebUrl }
      elseif ($IsMac) { & open $script:WebUrl }
      else { & xdg-open $script:WebUrl 2>$null }
    } catch { Warn (L 'w003') }
  }
  return $true
}
function Stop-Web {
  $w = $script:WebUi
  if (-not $w) { return }
  $w.finished = $true
  Emit 'finished' @{}
  if (-not $NoPause) {
    Say (L 'w004') 'Cyan'
    $until = (Get-Date).AddMinutes(30)
    while (-not $w.closeReq -and (Get-Date) -lt $until) {
      try { if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); break } } catch {}
      Start-Sleep -Milliseconds 200
    }
  } else { Start-Sleep -Milliseconds 1500 }
  $w.stop = $true
  Start-Sleep -Milliseconds 300
  $script:WebUi = $null
}

# ----------------------------------------------------------------- вывод

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c; Emit 'log' @{ k = 'say'; c = $c; t = $t } }
function Title([string]$t) { Write-Host ''; Write-Host ('== ' + $t) -ForegroundColor Cyan; Emit 'log' @{ k = 'title'; t = $t } }
function Ok([string]$t) { Write-Host ('  [ok] ' + $t) -ForegroundColor Green; Emit 'log' @{ k = 'ok'; t = $t } }
function Warn([string]$t) { Write-Host ('  [!] ' + $t) -ForegroundColor Yellow; Emit 'log' @{ k = 'warn'; t = $t } }
function Bad([string]$t) { Write-Host ('  [x] ' + $t) -ForegroundColor Red; Emit 'log' @{ k = 'bad'; t = $t } }

function Finish([int]$code) {
  # Останавливаем свой adb-сервер: иначе adb остаётся в памяти и папку у клиента не удалить.
  if ($script:Adb -and $script:AdbStarted) {
    try { [void](Invoke-Adb @('kill-server') 10) } catch {}
  }
  if ($script:WebUi) { Stop-Web }
  elseif (-not $NoPause) { Write-Host ''; [void](Read-Host (L 'm001')) }
  exit $code
}

# ----------------------------------------------------------------- adb

function Quote-Arg([string]$a) {
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  $r = '"'; $bs = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq '\') { $bs++; continue }
    if ($ch -eq '"') { $r += ('\' * ($bs * 2 + 1)) + '"'; $bs = 0; continue }
    $r += ('\' * $bs) + $ch; $bs = 0
  }
  return $r + ('\' * ($bs * 2)) + '"'
}

function Invoke-Adb([string[]]$ArgList, [int]$TimeoutSec = 40) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:Adb
  $psi.Arguments = (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync()
  $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    return [pscustomobject]@{ Out = ''; Err = 'TIMEOUT'; Code = -1; TimedOut = $true }
  }
  $p.WaitForExit()
  return [pscustomobject]@{ Out = [string]$o.Result; Err = [string]$e.Result; Code = $p.ExitCode; TimedOut = $false }
}

# Белый список команд чтения. Всё, что не подходит, не отправляется на телефон.
$ReadOnlyPatterns = @(
  '^getprop$',
  '^getprop [A-Za-z0-9_.]+$',
  '^cat /proc/(meminfo|uptime|loadavg|version)$',
  '^cat /sys/devices/system/cpu/(present|possible)$',
  '^cat /sys/devices/system/cpu/cpu\d+/cpufreq/(cpuinfo_max_freq|scaling_cur_freq)$',
  '^df -k /data$',
  '^ps -A -o RSS,NAME$', '^ps -A$', '^ps$',
  '^pidof [A-Za-z0-9_.]+$',
  '^dumpsys (cpuinfo|usagestats|wifi|connectivity|accessibility|thermalservice|battery|role|device_policy|diskstats)$',
  '^dumpsys activity (activities|recents)$',
  '^dumpsys package [A-Za-z0-9_.]+$',
  '^pm list packages( -[sde3ui])*$',
  '^pm list (users|features)$',
  '^pm path [A-Za-z0-9_.]+$',
  '^cmd package (resolve-activity|query-activities) --brief -a [A-Za-z0-9_.]+ -c [A-Za-z0-9_.]+$',
  '^cmd role get-role-holders [A-Za-z0-9_.]+$',
  '^cmd appops query-op --user 0 [A-Z_]+ (allow|ignore|deny|default|foreground)$',
  '^cmd appops get [A-Za-z0-9_.]+ [A-Z_]+$',
  '^settings get (system|secure|global) [A-Za-z0-9_.]+$',
  '^logcat -d -b crash -t \d+$',
  '^wm (size|density)$',
  '^dumpsys batterystats$',
  '^pm list packages -U$',
  '^du -s -k( /sdcard/[A-Za-z0-9_./-]+)+$'
)
function Test-ReadOnly([string]$cmd) {
  if ($cmd -match '[;&|<>`$\\"*?]') { return $false }
  foreach ($p in $ReadOnlyPatterns) { if ($cmd -cmatch $p) { return $true } }
  return $false
}

function ShOn([string]$serial, [string]$cmd, [int]$TimeoutSec = 40) {
  if (-not (Test-ReadOnly $cmd)) { throw (L 'm002' $cmd) }
  $r = Invoke-Adb @('-s', $serial, 'shell', $cmd) $TimeoutSec
  if ($r.TimedOut) { if ($script:Notes) { [void]$script:Notes.Add((L 'm003' $TimeoutSec $cmd)) }; return '' }
  return ($r.Out -replace "`r", '')
}
function Sh([string]$cmd, [int]$TimeoutSec = 40) { return (ShOn $script:Serial $cmd $TimeoutSec) }

function Get-PlatformTools([string]$os, [string]$dest) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri ("https://dl.google.com/android/repository/platform-tools-latest-$os.zip") -OutFile $dest
}

function Get-AdbBinary {
  if ($AdbPath) {
    if (Test-Path $AdbPath) { return (Resolve-Path $AdbPath).Path }
    Bad (L 'm004' $AdbPath); Finish 1
  }
  $tools = Join-Path $Root 'tools'
  if ($IsWin) { $local = Join-Path $tools 'platform-tools/adb.exe' }
  else { $local = Join-Path $tools 'platform-tools-mac/platform-tools/adb' }
  if (Test-Path $local) {
    if (-not $IsWin) { try { & chmod +x $local } catch {} }
    return $local
  }
  if (-not $Prepare) {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Warn (L 'm005')
  }
  Say (L 'm006')
  try {
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    if ($IsWin) {
      $zip = Join-Path $env:TEMP 'platform-tools-latest-windows.zip'
      Get-PlatformTools 'windows' $zip
      Expand-Archive -Path $zip -DestinationPath $tools -Force
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } else {
      $zip = Join-Path $tools 'platform-tools-darwin.zip'
      Get-PlatformTools 'darwin' $zip
      $mdir = Join-Path $tools 'platform-tools-mac'
      New-Item -ItemType Directory -Force -Path $mdir | Out-Null
      & unzip -q -o $zip -d $mdir
      & chmod +x $local
    }
  } catch {
    Bad ((L 'm007') + $_.Exception.Message)
    Say (L 'm008')
    Finish 1
  }
  if (Test-Path $local) { Ok (L 'm009'); return $local }
  Bad (L 'm010'); Finish 1
}

# Подготовка папки у мастера: ADB для Windows и Mac, PowerShell для Mac (берём из соседнего tv-kit, если он есть)
function Invoke-Prepare {
  Say (L 'm011' $KitVersion) 'Cyan'
  $tools = Join-Path $Root 'tools'
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $tv = Join-Path (Split-Path $Root -Parent) 'tv-kit/tools'
  if (Test-Path $tv) {
    Say (L 'm012' $tv)
    foreach ($n in @('platform-tools', 'platform-tools-darwin.zip', 'pwsh-osx-arm64.tar.gz', 'pwsh-osx-x64.tar.gz', 'pwsh-7.4.6-hashes.sha256')) {
      $src = Join-Path $tv $n
      $dst = Join-Path $tools $n
      if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item -Path $src -Destination $dst -Recurse -Force; Ok (L 'm013' $n) }
    }
  }
  $script:Adb = Get-AdbBinary
  $macZip = Join-Path $tools 'platform-tools-darwin.zip'
  if ($IsWin -and -not (Test-Path $macZip)) {
    try { Say (L 'm014'); Get-PlatformTools 'darwin' $macZip; Ok (L 'm015') } catch { Warn ((L 'm016') + $_.Exception.Message) }
  }
  $ud = Join-Path $tools 'usb_driver'
  if ($IsWin -and -not (Test-Path (Join-Path $ud 'android_winusb.inf'))) {
    try {
      Say (L 'm017')
      $uz = Join-Path $env:TEMP 'usb_driver_r13-windows.zip'
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -UseBasicParsing -Uri 'https://dl.google.com/android/repository/usb_driver_r13-windows.zip' -OutFile $uz
      Expand-Archive -Path $uz -DestinationPath $tools -Force
      Remove-Item $uz -Force -ErrorAction SilentlyContinue
      if (Test-Path (Join-Path $ud 'android_winusb.inf')) { Ok (L 'm018') } else { Warn (L 'm019') }
    } catch { Warn ((L 'm020') + $_.Exception.Message) }
  }
  foreach ($arch in @('arm64', 'x64')) {
    $f = Join-Path $tools "pwsh-osx-$arch.tar.gz"
    if (-not (Test-Path $f)) {
      try {
        Say (L 'm021' $arch)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri ("https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-osx-$arch.tar.gz") -OutFile $f
        Ok (L 'm022' $arch)
      } catch { Warn ((L 'm023' $arch) + $_.Exception.Message) }
    }
  }
  $v = Invoke-Adb @('version') 15
  Ok ("ADB: " + $script:Adb)
  Say ('  ' + (($v.Out -split "`n")[0..1] -join ' / '))
  if (Test-Path (Join-Path $Root 'data/uad.tsv')) { Ok (L 'm024') } else { Warn (L 'm025') }
  Say (L 'm026') 'Cyan'
  Finish 0
}

# ----------------------------------------------------------------- подключение телефона

function Get-AdbDevices {
  $r = Invoke-Adb @('devices') 15
  $list = @()
  foreach ($l in ($r.Out -split "`n")) {
    $l = $l.Trim()
    if ($l -match '^(\S+)\s+(device|unauthorized|offline|authorizing|connecting|recovery|sideload|bootloader|no permissions.*)$') { $list += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] } }
  }
  return $list
}

function Get-Mdns {
  $r = Invoke-Adb @('mdns', 'services') 15
  $list = @()
  foreach ($l in (($r.Out + "`n" + $r.Err) -split "`n")) {
    if ($l -match '^\s*(\S+)\s+_adb-tls-(pairing|connect)\._tcp\.?\s+(\d{1,3}(?:\.\d{1,3}){3}:\d{2,5})') {
      $list += [pscustomobject]@{ Name = $Matches[1]; Kind = $Matches[2]; Addr = $Matches[3] }
    }
  }
  return $list
}

function Test-Addr([string]$a) { return ($a -match '^\d{1,3}(\.\d{1,3}){3}:\d{2,5}$') }
# Чистим ввод IP:порт: пробелы, запятые вместо точек, «IP 192.168.1.5 порт 41234»
function Read-Addr([string]$q) {
  while ($true) {
    $a = Ask $q 'addr'
    if ($a -eq '') { return '' }
    $a = ($a -replace ',', '.') -replace '\s+', ''
    if ($a -match '(\d{1,3}(?:\.\d{1,3}){3}):?(\d{2,5})') { $a = $Matches[1] + ':' + $Matches[2] }
    if (Test-Addr $a) { return $a }
    Warn (L 'm027')
  }
}

function Connect-Addr([string]$target) {
  if ($target -notmatch ':\d+$') { $target = "${target}:5555" }
  Say (L 'm028' $target)
  $r = Invoke-Adb @('connect', $target) 20
  $txt = ($r.Out + ' ' + $r.Err).Trim()
  if ($txt -match 'connected to|already connected') { return $target }
  Warn (L 'm029' $txt)
  if (-not $IsWin -and $txt -match 'No route to host|EHOSTUNREACH') { Show-MacLanHelp }
  return $null
}

function Wait-Authorized([string]$serial) {
  $shown = $false
  for ($i = 0; $i -lt 60; $i++) {
    $d = Get-AdbDevices | Where-Object { $_.Serial -eq $serial }
    if ($d -and $d.State -eq 'device') { return $true }
    if (-not $shown) {
      Warn (L 'm030')
      Warn (L 'm031')
      $shown = $true
    }
    Start-Sleep -Seconds 2
    if ($d -and $d.State -eq 'offline') {
      [void](Invoke-Adb @('reconnect', 'offline') 10)
      if ($i -eq 10) { Show-OfflineHelp }
    }
  }
  return $false
}

# Чужой adb (Mi Assistant, Android Studio, scrcpy, Связь с телефоном и т.п.) перехватывает телефон -> «offline»
function Show-OtherAdb {
  if (-not $IsWin) { return $false }
  $mine = ''; try { $mine = (Resolve-Path $script:Adb).Path } catch {}
  $others = @(Get-Process -Name adb -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -ne $mine })
  if (-not $others.Count) { return $false }
  Warn (L 'm032')
  foreach ($o in $others) { Say ("    {0}" -f $o.Path) }
  Say (L 'm033')
  if (Confirm-Yes (L 'm034') (L 'w010')) {
    foreach ($o in $others) { try { Stop-Process -Id $o.Id -Force; Ok ((L 'm035') -f $o.Path) } catch { Warn ((L 'm036') + $_.Exception.Message) } }
    [void](Invoke-Adb @('kill-server') 15); [void](Invoke-Adb @('start-server') 30)
  }
  return $true
}

function Show-OfflineHelp {
  Say ''
  Warn (L 'm037')
  [void](Show-OtherAdb)
  Say (L 'm038')
  Say (L 'm039')
  Say (L 'm040')
  Say (L 'm041')
}

function Show-MacLanHelp {
  Say ''
  Say (L 'm042') 'Yellow'
  Say (L 'm043') 'Yellow'
  Say (L 'm044') 'Yellow'
}


# Проверка кабельного подключения: что видит сама Windows (без драйверов adb не увидит телефон, даже если Windows его видит)
$PhoneVids = 'VID_(2717|04E8|18D1|22B8|12D1|339B|2A70|0BB4|1004|22D9|2D95|1EBF|1BBB|2B4C|19D2|17EF|0FCE|2AE5|29A9|2A45|1F3A|0502)'
function Show-UsbCheck {
  Title (L 'm045')
  if (-not $IsWin) {
    Say (L 'm046')
    Say (L 'm047')
    return
  }
  [void](Show-OtherAdb)
  $devs = @()
  try {
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
      $_.InstanceId -match $PhoneVids -or $_.Class -eq 'AndroidUsbDeviceClass' -or $_.FriendlyName -match 'ADB|Android'
    })
  } catch { Warn ((L 'm048') + $_.Exception.Message); return }
  if ($devs.Count -eq 0) {
    Warn (L 'm049')
    Say (L 'm050')
    Say (L 'm051')
    return
  }
  foreach ($d in $devs) { Say ("  {0}  [{1}]  {2}" -f $d.FriendlyName, $d.Status, $d.Class) }
  # Настоящий драйвер adb = класс AndroidUsbDeviceClass. «ADB Interface» в классе USBDevice — это общий WinUSB,
  # который Windows ставит сама: устройство есть, но adb его не видит (так у Xiaomi 14T Pro на Windows 11).
  $adbOk = @($devs | Where-Object { $_.Class -eq 'AndroidUsbDeviceClass' -and $_.Status -eq 'OK' })
  $adbGeneric = @($devs | Where-Object { $_.FriendlyName -match 'ADB' -and $_.Class -ne 'AndroidUsbDeviceClass' })
  $bad = @($devs | Where-Object { $_.Status -ne 'OK' -and $_.Class -ne 'WPD' })
  $drv = Join-Path $Root 'tools/usb_driver'
  if ($adbOk.Count) {
    Ok (L 'm052')
    Say (L 'm053')
    Say (L 'm054')
  } elseif ($adbGeneric.Count -or $bad.Count) {
    if ($adbGeneric.Count) { Warn (L 'm055') }
    else { Warn (L 'm056') }
    Say (L 'm057')
    Say (L 'm058')
    Say (L 'm059')
    Say (L 'm060')
    if (-not (Test-Path (Join-Path $drv 'android_winusb.inf'))) {
      Warn (L 'm061')
      Say (L 'm062')
    }
    try { Start-Process devmgmt.msc } catch {}
  } else {
    Warn (L 'm063')
    Say (L 'm064')
    Say (L 'm065')
    Say (L 'm066')
  }
}

function Show-EnableHelp {
  Say ''
  Say (L 'm067') 'White'
  Say (L 'm068')
  Say (L 'm069')
  Say (L 'm070')
  Say (L 'm071')
  Say (L 'm072')
  Say (L 'm073')
  Say (L 'm074')
  Say (L 'm075')
  Say (L 'm076')
  Say (L 'm077')
  Say (L 'm078')
  Say (L 'm079')
  Say (L 'm080')
}

function Get-Model([string]$serial) {
  $m = (ShOn $serial 'getprop ro.product.model' 10).Trim()
  $b = (ShOn $serial 'getprop ro.product.brand' 10).Trim()
  return (($b, $m | Where-Object { $_ }) -join ' ')
}

function Pair-Wifi {
  Say ''
  Say (L 'm081') 'White'
  Say (L 'm082') 'White'
  $before = @(Get-AdbDevices | ForEach-Object { $_.Serial })
  $pt = ''
  Say (L 'm083')
  $found = @()
  for ($i = 0; $i -lt 3 -and $found.Count -eq 0; $i++) { $found = @(Get-Mdns | Where-Object { $_.Kind -eq 'pairing' }); if (-not $found.Count) { Start-Sleep -Seconds 2 } }
  if ($found.Count -eq 1) { $pt = $found[0].Addr; Ok (L 'm084' $pt) }
  elseif ($found.Count -gt 1) {
    for ($i = 0; $i -lt $found.Count; $i++) { Say ("  {0}) {1}" -f ($i + 1), $found[$i].Addr) 'White' }
    $a = Ask (L 'm085') 'menu' @(for ($i = 0; $i -lt $found.Count; $i++) { Opt ([string]($i + 1)) $found[$i].Addr })
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $found.Count) { $pt = $found[[int]$a - 1].Addr }
  }
  if (-not $pt) {
    Say (L 'm086')
    Say (L 'm087') 'Yellow'
    $pt = Read-Addr (L 'm088')
    if (-not $pt) { return $null }
  }
  do { $code = Ask (L 'm089') 'code6' $null @{ addr = $pt } } until ($code -match '^\d{6}$')
  $r = Invoke-Adb @('pair', $pt, $code) 30
  $txt = ($r.Out + ' ' + $r.Err).Trim()
  if ($txt -notmatch 'Successfully paired') {
    Warn (L 'm090' $txt)
    if ($txt -match 'protocol fault|couldn.t read status') {
      Say (L 'm091') 'Yellow'
      Say (L 'm092') 'Yellow'
      Say (L 'm093') 'Yellow'
    } elseif ($txt -match 'Wrong password') { Say (L 'm094') 'Yellow' }
    elseif ($txt -match 'failed to connect|refused|timed out|No route') { Say (L 'm095') 'Yellow' }
    Say (L 'm096')
    Say (L 'm097')
    return $null
  }
  Ok (L 'm098')
  $ip = ($pt -split ':')[0]
  Say (L 'm099')
  for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep -Seconds 2
    foreach ($d in (Get-AdbDevices)) {
      if ($before -notcontains $d.Serial -and ($d.Serial.StartsWith($ip + ':') -or $d.Serial -match '_adb-tls-connect')) { return $d.Serial }
    }
    foreach ($m in (Get-Mdns | Where-Object { $_.Kind -eq 'connect' -and $_.Addr.StartsWith($ip + ':') })) {
      $s = Connect-Addr $m.Addr; if ($s) { return $s }
    }
  }
  Say (L 'm100')
  $ct = Read-Addr (L 'm101')
  if ($ct) { return (Connect-Addr $ct) }
  return $null
}

function Select-Phone {
  if ($Address) { $s = Connect-Addr $Address; if ($s) { return $s }; Show-EnableHelp; Finish 1 }
  $first = $true
  while ($true) {
    $devs = @(Get-AdbDevices)
    $ready = @($devs | Where-Object { $_.State -eq 'device' })
    if ($first -and $ready.Count -eq 1) {
      Ok ((L 'm102') -f (Get-Model $ready[0].Serial), $ready[0].Serial)
      return $ready[0].Serial
    }
    $first = $false
    Say ''
    if ($devs.Count -eq 0) { Warn (L 'm103') }
    for ($i = 0; $i -lt $devs.Count; $i++) {
      $d = $devs[$i]
      $lbl = $d.Serial
      if ($d.State -eq 'device') { $lbl = (Get-Model $d.Serial) + "  ($($d.Serial))" }
      elseif ($d.State -eq 'unauthorized') { $lbl += (L 'm104') }
      elseif ($d.State -eq 'offline') { $lbl += (L 'm105') }
      else { $lbl += "  ($($d.State))" }
      Say ("  {0}) {1}" -f ($i + 1), $lbl) 'White'
    }
    Say (L 'm106') 'White'
    Say (L 'm107') 'White'
    Say (L 'm108') 'White'
    Say (L 'm109') 'White'
    Say (L 'm110') 'White'
    $opts = @()
    for ($i = 0; $i -lt $devs.Count; $i++) { $d = $devs[$i]; $opts += (Opt ([string]($i + 1)) $(if ($d.State -eq 'device') { (Get-Model $d.Serial) + "  ($($d.Serial))" } else { "$($d.Serial)  ($($d.State))" })) }
    $opts += (Opt 'W' ((L 'm106') -replace '^\s*\w\)\s*', '')); $opts += (Opt 'I' ((L 'm107') -replace '^\s*\w\)\s*', ''))
    $opts += (Opt 'H' ((L 'm108') -replace '^\s*\w\)\s*', '')); $opts += (Opt 'U' ((L 'm109') -replace '^\s*\w\)\s*', ''))
    $opts += (Opt 'R' (L 'w020')); $opts += (Opt 'Q' (L 'w021'))
    $a = Ask (L 'm111') 'menu' $opts @{ screen = 'connect'; devices = $devs.Count }
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $devs.Count) { return $devs[[int]$a - 1].Serial }
    elseif ($a -match '^[WwЦц]$') { $s = Pair-Wifi; if ($s) { return $s } }
    elseif ($a -match '^[IiШш]$') {
      $t = Read-Addr (L 'm112')
      if ($t) { $s = Connect-Addr $t; if ($s) { return $s } }
    }
    elseif ($a -match '^[HhРр]$') { Show-EnableHelp }
    elseif ($a -match '^[UuГг]$') { Show-UsbCheck }
    elseif ($a -match '^[QqЙй]$') { Finish 0 }
  }
}

# ----------------------------------------------------------------- разбор

function Parse-Props([string]$txt) {
  $h = @{}
  foreach ($l in ($txt -split "`n")) { if ($l -match '^\[([^\]]+)\]: \[(.*)\]\s*$') { $h[$Matches[1]] = $Matches[2] } }
  return $h
}
function P([string]$k) { if ($script:Props.ContainsKey($k)) { return $script:Props[$k] } return '' }

function Parse-PkgList([string]$txt) {
  $s = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($l in ($txt -split "`n")) { if ($l -match '^package:([A-Za-z0-9_.]+)(\s|$)') { [void]$s.Add($Matches[1]) } }
  return ,$s
}

function Parse-Meminfo([string]$txt) {
  $h = @{}
  foreach ($l in ($txt -split "`n")) { if ($l -match '^(\w+):\s+(\d+) kB') { $h[$Matches[1]] = [int64]$Matches[2] } }
  return $h
}
function Mb([int64]$kb) { return [math]::Round($kb / 1024) }
# Размер для людей: 850 МБ / 3,4 ГБ (десятичный разделитель — по языку набора)
function Fmt-Mb([double]$mb) {
  if ($mb -ge 1024) {
    $v = ([math]::Round($mb / 1024, 1)).ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($script:Lang -ne 'en') { $v = $v.Replace('.', ',') }
    return (L 's010' $v)
  }
  return (L 's011' ([math]::Round($mb)))
}
# Короткий снимок для «было / стало»: свободная ОЗУ, число процессов, свободное место, отключённые пакеты
function Get-Snap {
  $s = [ordered]@{ memAvailMb = 0; procs = 0; dataFreeMb = 0; disabled = 0 }
  try {
    $m = Parse-Meminfo (Sh 'cat /proc/meminfo')
    if ($m['MemAvailable']) { $s.memAvailMb = Mb $m['MemAvailable'] }
    $s.procs = @(Parse-Ps (Sh $(if ($script:PsCmd) { $script:PsCmd } else { 'ps -A' }))).Count
    $s.dataFreeMb = Mb (Get-DataFree)
    $s.disabled = (Parse-PkgList (Sh 'pm list packages -d')).Count
  } catch {}
  return $s
}
# Подпись пакета для людей: наше пояснение -> имя из базы UAD -> сам пакет
function Get-PkgLabel([string]$p) {
  $n = $null
  if ($ruNote -and $ruNote[$p]) { $n = $ruNote[$p] }
  elseif ($uad -and $uad[$p] -and $uad[$p].name) { $n = $uad[$p].name }
  if ($n) { return $n }
  return $p
}

function Parse-Duration([string]$s) {
  $s = $s.Trim()
  if ($s -match '[dhms]' -and $s -match '^\+?(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?(?:\d+ms)?$') {
    return ([int]$Matches[1]) * 86400 + ([int]$Matches[2]) * 3600 + ([int]$Matches[3]) * 60 + ([int]$Matches[4])
  }
  $days = 0
  if ($s -match '^(\d+)d\s*(.*)$') { $days = [int]$Matches[1]; $s = $Matches[2] }
  $s = $s -replace '\.\d+$', ''
  $sec = 0
  foreach ($x in ($s -split ':')) { if ($x -match '^\d+$') { $sec = $sec * 60 + [int]$x } }
  return $days * 86400 + $sec
}
function Fmt-Dur([int64]$sec) {
  $h = [math]::Floor($sec / 3600); $m = [math]::Floor(($sec % 3600) / 60)
  if ($h -gt 0) { return (L 'm113' $h $m) } return (L 'm114' $m)
}

function Parse-Usage([string]$txt) {
  # По всем разделам (день/неделя/месяц/год): максимум времени и самый поздний запуск — осторожная оценка.
  $h = @{}
  foreach ($l in ($txt -split "`n")) {
    if ($l -match 'package=([A-Za-z0-9_.]+)\s+totalTime(?:Used)?="([^"]+)"') {
      $pkg = $Matches[1]; $t = Parse-Duration $Matches[2]
      $last = [datetime]::MinValue
      if ($l -match 'lastTime(?:Used)?="(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)"') { try { $last = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch {} }
      if (-not $h.ContainsKey($pkg)) { $h[$pkg] = [pscustomobject]@{ Pkg = $pkg; Sec = $t; Last = $last } }
      else {
        if ($h[$pkg].Sec -lt $t) { $h[$pkg].Sec = $t }
        if ($h[$pkg].Last -lt $last) { $h[$pkg].Last = $last }
      }
    }
  }
  return $h
}

function Parse-Roles([string]$txt) {
  # dumpsys role: для пользователя 0 — имя роли -> держатели
  $h = @{}; $name = ''; $user = '0'
  foreach ($l in ($txt -split "`n")) {
    if ($l -match 'user_id=(\d+)') { $user = $Matches[1]; continue }
    if ($user -ne '0') { continue }
    if ($l -match 'name=(android\.app\.role\.[A-Z_]+)') { $name = $Matches[1]; continue }
    if ($name -and $l -match 'holders=\[?([A-Za-z0-9_.,\s]*)\]?') {
      $hs = @($Matches[1] -split '[,\s]+' | Where-Object { $_ -match '^[A-Za-z0-9_.]+$' })
      if ($hs.Count) { $h[$name] = $hs }
      $name = ''
    }
  }
  return $h
}

function Redact([string]$t) {
  $t = [regex]::Replace($t, '(?i)\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', 'xx:xx:xx:xx:xx:xx')
  $t = [regex]::Replace($t, '(?m)^(\[[^\]]*(serial|imei|meid|iccid|msisdn|cpuid|wifimac|btmac|ethmac|macaddr|phone_number|\.sn)[^\]]*\]: )\[.*\]', (L 'm115'))
  $t = [regex]::Replace($t, '\b\d{15}\b', (L 'm116'))
  return $t
}

function Save-Raw([string]$name, [string]$txt) {
  $f = Join-Path $script:RawDir $name
  [IO.File]::WriteAllText($f, (Redact $txt), (New-Object Text.UTF8Encoding($false)))
}

# Пакеты, которые не предлагаем отключать никогда (система, связь, безопасность, аккаунты, обновления, дети, платежи...).
# Правила сильнее базы UAD: даже «Recommended» под эти правила не попадёт.
$ProtectedPatterns = @(
  '^android$',
  '^com\.android\.(systemui|settings|phone|server\..*|providers\..*|shell|bluetooth|nfc|packageinstaller|permissioncontroller|inputdevices|externalstorage|webview|networkstack.*|keychain|location\.fused|se|captiveportallogin|certinstaller|documentsui|vpndialogs|wallpaperbackup|backupconfirm|proxyhandler|sharedstoragebackup|dynsystem|localtransport|statementservice|mms\.service|cellbroadcast.*|emergency|incallui|dialer|contacts|mtp|carrierconfig|stk|ons|simappdialog|launcher3?|deskclock|calendar|vending|intentresolver|devicelockcontroller|healthconnect.*|adservices.*|rkpdapp|virtualmachine.*|credentialmanager|safetycenter.*|apex.*|modulemetadata|wifi.*|tethering.*|uwb.*|media(provider)?(\..*)?|camera2?)$',
  '^com\.google\.android\.(gms(\..*)?|gsf(\..*)?|webview|ext\..*|packageinstaller|permissioncontroller|inputmethod\..*|configupdater|networkstack.*|modulemetadata|overlay\..*|captiveportallogin|dialer|contacts|apps\.messaging|deskclock|calendar|apps\.restore|apps\.kids\..*|apps\.safetyhub|apps\.work\..*|partnersetup|setupwizard|onetimeinitializer|apps\.turbo|apps\.wellbeing|syncadapters\..*|backuptransport|apps\.nbu\.files|rkpdapp|healthconnect.*|adservices.*|providers\..*|tts|apps\.carrier\..*|ims|euicc.*|cellbroadcast.*)$',
  # клавиатуры, рабочий стол, системный интерфейс, настройки
  'inputmethod|keyboard|honeyboard|latinime|(^|[._])ime([._]|$)|swiftkey|launcher|quickstep|systemui|settings|setupwizard|provision',
  # связь и SIM
  'telephony|telecom|dialer|incallui|contacts|(^|[._])(mms|sms|messaging|ims|imsservice|epdg|volte|vowifi|wfc|euicc|carrier\w*|cellbroadcast\w*|emergency|stk|simsetting\w*)([._]|$)|networkui',
  # связь: Bluetooth, NFC, Wi-Fi, сеть, время
  'bluetooth|nfc|wifi|networkstack|connectivity|tethering|timezone|location|gnss|(^|[._])gps([._]|$)',
  # камера, галерея, биометрия, платежи, кошельки
  'camera|gallery|biometric|fingerprint|(^|[._])face(?!book)|bio\.face|smartface|wallet|(^|[._])s?pay(fw|ment)?([._]|$)|samsungpass|dkey',
  # дети и родительский контроль
  'supervision|familylink|parentalcare|kidshome|kidsinstaller|(^|[._])kids([._]|$)|wellbeing|(^|[._])forest([._]|$)',
  # безопасность, аккаунты, Knox, менеджеры системы
  'knox|klmsagent|ucs\.agent|kgclient|securefolder|secur(ity)?center|safecenter|securitycore|securityadd|systemmanager|phonemanager|permission|authfw|rampart|applock|^com\.osp\.app\.signin$|mobileservice|^com\.samsung\.android\.scs$|^com\.xiaomi\.(account|finddevice|xmsf)$|^com\.lbe\.security\.miui$|hwid|hihonor\.id|findmy(mobile|device)?|finddevice',
  # обновления прошивки и магазины производителя, которые обновляют системные приложения
  '(^|[._])\w*(update|upgrade)\w*([._]|$)|(^|[._])f?ota([._]|$)|wssyncmldm|soagent|omadm|samsungapps|^com\.xiaomi\.discover$|\.gru$|localeoverlay',
  # оформление системы, обои, ресурсы, оверлеи
  'overlay|resources|miwallpaper|wallpaper(backup|cropper)|dynamiclock|dressroom|aodservice|soundpicker|clipboard|smartcapture|screenshot|accessibility|talkback',
  # железо и слой производителя чипа
  'hardware|vendor\.|\.hal($|\.)|qualcomm|(^|[._])(qti|qcom|mediatek|mtk|slsi|exynos|unisoc|sprd)([._]|$)|gamedriver|gpudriver|vklayer|thermal|powerkeeper|joyose|(^|[._])game\.gos$',
  # хранилище, провайдеры данных, файлы, MTP
  'providers|storage|(^|[._])mtp\w*|cdfs|documentsui|externalstorage|backup(agent|transport)',
  # планшетные функции и окна
  '(^|[._])spen|aircommand|pentastic|desktopmode|(^|[._])dex([._]|$)|multiwindow|taskbar',
  # будильник и часы, календарь
  'clock|alarm|calendar',
  # диагностика Samsung, Обслуживание устройства, процедуры
  'diagmon|(^|[._])dsms([._]|$)|(^|[._])lool([._]|$)|sm\.policy|routines|smartsuggestions|brightnessbackup',
  'vpn|proxy|webview|webkit',
  # аутентификация, корпоративное управление, защищённый ввод, местоположение (найдено аудитом базы UAD)
  'fido|cmfa|teegris|(^|[._])tui([._]|$)|asksmanager|(^|[._])mdm|enterprise|androidforwork|dmagent|authenticator|(^|[._])odad$|securityhub|greenguard|sskds',
  'nlp$|(^|[._])supl([._]|$)|sarcontrol|(^|[._])sar([._]|$)|smsextra|poweroff|onetimeinitializer|emergency|^com\.samsung\.android\.sm(\.provider)?$'
)
function Test-Protected([string]$pkg) {
  # Наш проверенный список (data/ru.tsv) сильнее общих правил: «ok» — точно можно, «protect» — точно нельзя
  if ($script:RuLevel -and $script:RuLevel[$pkg] -eq 'ok') { return $false }
  foreach ($p in $ProtectedPatterns) { if ($pkg -match $p) { return $true } }
  if ($script:RuLevel -and $script:RuLevel[$pkg] -eq 'protect') { return $true }
  return $false
}

# Функции, которыми владелец может пользоваться: по умолчанию НЕ отмечаются
$AskPattern = 'assistant|voice|speech|hotword|bixby|music|video|youtube|netflix|spotify|browser|chrome|maps|photo|notes|memo|recorder|calculator|weather|email|mail|(^|[._])gm$|drive|docs|office|onedrive|skydrive|outlook|teams|cloud|share|sharing|mirror|cast|health|fit|watch|wear|buds|game|store|market|radio|(^|[._])fm([._]|$)|scanner|translate|lens|keep|meet|tachyon|duo|facebook\.(katana|orca|lite)|instagram|tiktok|amazon|prime|kids|book|reader|print|scan|compass|tv|remote|auto|wallpaper|widget|pay|wallet|rcs|enhanceservice|vvm|voicemail|firewall|block|spam|sound|audio|equali|dolby|magnif|one ?hand|accessory|beansmgr|peripheral|easysetup|stplatform|continuity|mcfds|mdx|nearby|halfsheet|(^|[._ ])key|uwb|secure wi-fi|smartcall|universalswitch|accesscontrol|detector|color adjust|app\.color|earphone|headset|brightness|hearing|handwriting|popupui|minimode|tracker|(^|[._])mt$|(^|[._])dsm([._]|$)|daemonapp|crane|call\+|(^|[._ ])v?sim|softsim|coreapps|deviceid|authservice|quicktool|fps|devicesecurity|theme|font|icon|search|backup|restore|tasks|bard|gemini|exchange|ar\.core|augmented|(^|[._])tag$|nfc|(^|[._])qr([._]|$)|phrase|privacy|carlink|carwith|smarthome|connect|boost|sysopt|trust|(^|[._ ])pass([._ ]|$)|find ?my|(^|[._])adm$|backdrop|screensaver|scone|5g|lte|network|location|dex|hs20|passpoint|hotspot|sms|secur|them(e|ing)|biometric|fingerprint|authenticat|soter|ifaa'
# Явный мусор (реклама, аналитика, сбор данных, партнёрские заглушки, тесты, снятые с поддержки) — по умолчанию отмечается
$AutoPattern = '(^|\W)ads?(\W|$)|advert|adservice|analytic|telemetry|tracking|spyware|collect|statistic|(^|\W)metrics?(\W|$)|recommend|partner|stub|promo|facebook|netflix|booking|linkedin|yahoo|flipboard|empty package|useless|discontinued|(^|\W)test|debug|hidden|diagnos|logging|logger|log collect|bug ?report|feedback|easter egg|china|chinese|korea|japan|verizon|t-mobile|sprint|preload|retail demo|tips|tutorial|user guide|user manual|ar zone|ar emoji|ar doodle|deco pic|sticker|news|shop|ecomm|community|forum|loan|(^|\W)vr(\W|$)|daydream|cardboard|yellow ?page|customi[sz]ation|visit in|(^|[._])msa([._]|$)|miui daemon|onetrack|vipaccount|o2o|youpin|mirecycle|quick apps|hybrid|app vault|minusscreen|taplus|carousel'

# Сторонние приложения, которым НЕ ограничиваем фон даже если ими не пользовались
$KeepBgPattern = 'photo|gallery|drive|cloud|music|spotify|podcast|radio|navi|maps|fit|sleep|whatsapp|telegram|viber|signal|messenger|orca|skype|zoom|teams|slack|discord|wechat|kakao|line\.android|bank|pay|wallet|money|finance|card|auth|otp|2fa|alarm|clock|calendar|kid|family|parent|life360|findmy|tracker|health|medic|vpn|keyboard|launcher|sms|dialer|call|contacts|mail|outlook|gmail|sync|backup|antivirus|security'

# Чистильщики/ускорители — обычно реклама, пользы нет
$CleanerPattern = 'clean|booster|boost|speed(up|er)|junk|cooler|cpu\.?cool|battery\.?(saver|doctor)|antivirus|virus|optimi[sz]er|ram\.?(clean|boost)|fast\.?charg'
# Магазины приложений
$StoreInstallers = '^(com\.android\.vending|com\.xiaomi\.discover|com\.sec\.android\.app\.samsungapps|com\.xiaomi\.(mipicks|market)|com\.huawei\.appmarket|com\.hihonor\.appmarket|com\.heytap\.market|com\.oppo\.market|com\.bbk\.appstore|com\.amazon\.venezia|com\.google\.android\.feedback|ru\.vk\.store|com\.transsion\.\w*store\w*|com\.motorola\.\w+)$'
$FileInstallers = 'packageinstaller'

# ----------------------------------------------------------------- изменения: оптимизация и откат

$AnimKeys = @('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')
$SettingKeys = 'window_animation_scale|transition_animation_scale|animator_duration_scale|private_dns_mode|private_dns_specifier'

# Белый список команд ЗАПИСИ. Всё остальное не отправляется.
$WritePatterns = @(
  '^pm disable-user --user 0 [A-Za-z0-9_.]+$',
  '^pm enable --user 0 [A-Za-z0-9_.]+$',
  '^pm uninstall -k --user 0 [A-Za-z0-9_.]+$',
  '^(cmd package|pm) install-existing --user 0 [A-Za-z0-9_.]+$',
  ('^settings put global (' + $SettingKeys + ') [A-Za-z0-9_.-]+$'),
  ('^settings delete global (' + $SettingKeys + ')$'),
  '^cmd appops set [A-Za-z0-9_.]+ RUN_ANY_IN_BACKGROUND (allow|ignore|default)$',
  '^pm trim-caches \d+G$',
  '^svc power reboot$',
  '^reboot$'
)
function Test-WriteAllowed([string]$cmd) {
  if ($cmd -match '[;&|<>`$\\"*?]') { return $false }
  foreach ($p in $WritePatterns) { if ($cmd -cmatch $p) { return $true } }
  return $false
}
function Log-Change([string]$t) {
  if (-not $script:ChangeLog) { return }
  [IO.File]::AppendAllText($script:ChangeLog, ((Get-Date -Format 'HH:mm:ss') + ' ' + $t + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}
function ShW([string]$cmd, [int]$TimeoutSec = 120) {
  if (-not (Test-WriteAllowed $cmd)) { throw (L 'm117' $cmd) }
  $r = Invoke-Adb @('-s', $script:Serial, 'shell', $cmd) $TimeoutSec
  $out = (($r.Out + ' ' + $r.Err) -replace "`r", '').Trim()
  if ($r.TimedOut) { $out = 'TIMEOUT ' + $out }
  Log-Change ("> $cmd`r`n           $out")
  return $out
}
function OptLog([string]$t, [string]$kind = 'info') {
  [void]$script:OptLines.Add($t)
  switch ($kind) { 'ok' { Ok $t } 'warn' { Warn $t } 'bad' { Bad $t } default { Say ('  ' + $t) } }
}
function Confirm-Yes([string]$q, [string]$webQ = '') {
  if ($script:WebUi -and $webQ) { $q = $webQ }
  $a = (Ask $q 'confirm').ToLower()
  # «да» на всех языках набора (и в английской раскладке): ru/uk/en/pt/es/fr/it/de/lv/pl
  return ($a -in @('да', 'д', 'lf', 'l', 'так', 'т', 'y', 'yes', 'sim', 's', 'sí', 'sì', 'si', 'oui', 'o', 'ja', 'j', 'jā', 'tak', 't'))
}

function Get-DisabledSet { return ,(Parse-PkgList (Sh 'pm list packages -d')) }
function Get-InstalledSet { return ,(Parse-PkgList (Sh 'pm list packages')) }
function Get-HomeComp {
  $t = Sh 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
  $c = ''
  foreach ($l in ($t -split "`n")) { if ($l -match '^\s*([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)\s*$') { $c = $Matches[1] } }
  return $c
}
function Test-HomeBad([string]$c) { return ((-not $c) -or ($c -match '^android/') -or ($c -match 'FallbackHome|ResolverActivity')) }

function Get-Health {
  $h = @{}
  $h.Model = (Sh 'getprop ro.product.model').Trim()
  $h.Home = Get-HomeComp
  $h.HomeBad = Test-HomeBad $h.Home
  $h.Settings = ((Sh 'cmd package resolve-activity --brief -a android.settings.SETTINGS -c android.intent.category.DEFAULT') -match '[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+')
  $imePkg = (((Sh 'settings get secure default_input_method').Trim()) -split '/')[0]
  $dis = Get-DisabledSet
  $h.Ime = ((-not $imePkg) -or ($imePkg -eq 'null') -or (-not $dis.Contains($imePkg)))
  $h.SysUi = [bool]((Sh 'pidof com.android.systemui').Trim())
  return $h
}
function Compare-Health($base, $now) {
  $p = @()
  if (-not $now.Model) { $p += (L 'm118') }
  if ($now.HomeBad -and -not $base.HomeBad) { $p += (L 'm119' $($now.Home)) }
  if ($base.Settings -and -not $now.Settings) { $p += (L 'm120') }
  if ($base.Ime -and -not $now.Ime) { $p += (L 'm121') }
  if ($base.SysUi -and -not $now.SysUi) { $p += (L 'm122') }
  return ,$p
}

# --- журнал изменений: всё, что сейчас применено и что умеем откатить
function Save-State {
  if (-not $script:State) { return }
  $json = $script:State | ConvertTo-Json -Depth 6
  foreach ($f in $script:StateFiles) { [IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding($false))) }
}
function Add-Journal($entry) { [void]$script:Journal.Add($entry); Save-State }

function Disable-Pkg([string]$pkg, [switch]$Third) {
  # Последняя проверка безопасности прямо перед командой
  if ($script:keepSet.Contains($pkg)) { OptLog (L 'm123' $pkg) 'warn'; return $false }
  if (-not $Third) {
    if (Test-Protected $pkg) { OptLog (L 'm124' $pkg) 'warn'; return $false }
    if ($script:third.Contains($pkg)) { OptLog (L 'm125' $pkg) 'warn'; return $false }
    if ($script:usedPkgs.Contains($pkg)) { OptLog (L 'm126' $pkg) 'warn'; return $false }
  }
  $out = ShW "pm disable-user --user 0 $pkg"
  $listed = (Get-DisabledSet).Contains($pkg)
  $said = ($out -match 'new state: disabled')
  # Журналим всегда, когда телефон подтвердил команду: иначе откат не узнает про это изменение
  if ($listed -or $said) { Add-Journal @{ t = 'disable'; pkg = $pkg } }
  if ($listed) { OptLog (L 'm127' $pkg) 'ok'; return $true }
  if ($said) { OptLog (L 'm128' ${pkg}) 'warn'; return $true }
  if ($Third) { OptLog (L 'm129' $pkg $out) 'warn'; return $false }
  # Прошивка не дала отключить (бывает на Xiaomi/Samsung) — удаляем только для пользователя 0, с сохранением; откат: install-existing
  $out2 = ShW "pm uninstall -k --user 0 $pkg"
  $gone = -not (Get-InstalledSet).Contains($pkg)
  if ($out2 -match 'Success' -or $gone) {
    Add-Journal @{ t = 'uninstall'; pkg = $pkg }
    if ($gone) { OptLog (L 'm130' $pkg) 'ok'; return $true }
    OptLog (L 'm131' ${pkg}) 'warn'; return $true
  }
  OptLog (L 'm132' $pkg $out $out2) 'warn'; return $false
}
function Enable-Pkg([string]$pkg) {
  $out = ShW "pm enable --user 0 $pkg"
  if (-not (Get-DisabledSet).Contains($pkg)) { OptLog (L 'm133' $pkg) 'ok'; return $true }
  OptLog (L 'm134' $pkg $out) 'bad'; return $false
}
function Restore-Pkg([string]$pkg) {
  $out = ShW "cmd package install-existing --user 0 $pkg"
  if (-not (Get-InstalledSet).Contains($pkg)) { $out += ' / ' + (ShW "pm install-existing --user 0 $pkg") }
  if ((Get-InstalledSet).Contains($pkg)) { OptLog (L 'm135' $pkg) 'ok'; return $true }
  OptLog (L 'm136' $pkg $out) 'bad'; return $false
}
function Set-GlobalSetting([string]$key, [string]$val) {
  $old = (Sh "settings get global $key").Trim()
  if ($old -eq $val) { return }
  [void](ShW "settings put global $key $val")
  Add-Journal @{ t = 'setting'; key = $key; old = $old; new = $val }
}
function Set-Anim([string]$val) {
  foreach ($k in $AnimKeys) { Set-GlobalSetting $k $val }
  OptLog (L 'm137' $val) 'ok'
}
function Test-NetBroken {
  $c = Sh 'dumpsys connectivity'
  return ($c -match 'PRIVATE_DNS_BROKEN')
}
function Set-Dns([string]$host_) {
  $start = $script:Journal.Count
  Set-GlobalSetting 'private_dns_specifier' $host_
  Set-GlobalSetting 'private_dns_mode' 'hostname'
  Say (L 'm138')
  Start-Sleep -Seconds 15
  if (Test-NetBroken) {
    OptLog (L 'm139' $host_) 'bad'
    Undo-Journal $start
    return $false
  }
  OptLog (L 'm140' $host_) 'ok'
  return $true
}
function Get-BgMode([string]$pkg) {
  $t = Sh "cmd appops get $pkg RUN_ANY_IN_BACKGROUND"
  if ($t -match 'RUN_ANY_IN_BACKGROUND: (\w+)') { return $Matches[1] }
  return 'default'
}
function Restrict-Bg([string]$pkg) {
  if ($script:keepSet.Contains($pkg)) { OptLog (L 'm141' $pkg) 'warn'; return $false }
  $old = Get-BgMode $pkg
  if ($old -eq 'ignore') { OptLog (L 'm142' ${pkg}) 'ok'; return $false }
  [void](ShW "cmd appops set $pkg RUN_ANY_IN_BACKGROUND ignore")
  if ((Get-BgMode $pkg) -eq 'ignore') {
    Add-Journal @{ t = 'appops'; pkg = $pkg; old = $old }
    OptLog (L 'm143' $pkg) 'ok'; return $true
  }
  OptLog (L 'm144' $pkg) 'warn'; return $false
}
function Clear-Caches {
  $f1 = Get-DataFree
  [void](ShW 'pm trim-caches 999G' 300)
  Start-Sleep -Seconds 3
  $f2 = Get-DataFree
  $d = [math]::Max(0, (Mb ($f2 - $f1)))
  $script:CacheFreedMb = $d
  OptLog (L 'm145' $d $(Mb $f2)) 'ok'
}
function Get-DataFree {
  foreach ($l in ((Sh 'df -k /data') -split "`n")) { if ($l -match '^\S+\s+\d+\s+\d+\s+(\d+)\s+\d+%') { return [int64]$Matches[1] } }
  return 0
}

function Undo-Entry($e) {
  switch ([string]$e.t) {
    'disable' { [void](Enable-Pkg ([string]$e.pkg)) }
    'uninstall' { [void](Restore-Pkg ([string]$e.pkg)) }
    'setting' {
      $old = [string]$e.old
      if (-not $old -or $old -eq 'null') { [void](ShW "settings delete global $($e.key)") } else { [void](ShW "settings put global $($e.key) $old") }
      OptLog (L 'm147' $($e.key) $(if ($old -and $old -ne 'null') { $old } else { (L 'm146') })) 'ok'
    }
    'appops' {
      $old = [string]$e.old
      if ($old -notin @('allow', 'ignore', 'default')) { $old = 'default' }
      [void](ShW "cmd appops set $($e.pkg) RUN_ANY_IN_BACKGROUND $old")
      OptLog (L 'm148' $($e.pkg)) 'ok'
    }
  }
}
function Undo-Selected([int[]]$idx) {
  foreach ($i in @($idx | Sort-Object -Descending)) {
    if ($i -lt 0 -or $i -ge $script:Journal.Count) { continue }
    Undo-Entry $script:Journal[$i]
    $script:Journal.RemoveAt($i); Save-State
  }
}
function Undo-Journal([int]$from = 0) {
  for ($i = $script:Journal.Count - 1; $i -ge $from; $i--) {
    Undo-Entry $script:Journal[$i]
    $script:Journal.RemoveAt($i); Save-State
  }
}

function Find-SameDevice([string]$sn) {
  foreach ($d in (Get-AdbDevices | Where-Object { $_.State -eq 'device' })) {
    if (-not $sn) { if ($d.Serial -eq $script:Serial) { return $d.Serial } else { continue } }
    if ((ShOn $d.Serial 'getprop ro.serialno' 10).Trim() -eq $sn) { return $d.Serial }
  }
  return ''
}

function Invoke-RebootCheck {
  $sn = (Sh 'getprop ro.serialno').Trim()
  $wifi = ($script:Serial -match ':\d+$' -or $script:Serial -match '_adb-tls-connect')
  OptLog (L 'm149')
  Say (L 'm150')
  Start-Sleep -Seconds 20
  $o = ShW 'svc power reboot' 20
  if ($o -match 'Unknown|not found|Error') { [void](ShW 'reboot' 20) }
  Say (L 'm151')
  if ($wifi) { Say (L 'm152') 'Yellow' }
  else { Say (L 'm153') 'Yellow' }
  Start-Sleep -Seconds 30
  $up = $false; $seen = $false; $hinted = $false; $tried = @{}; $ext = 0
  $tries = $(if ($wifi) { 45 } else { 27 })   # по Wi-Fi нужен человек: включить отладку и, возможно, ввести код
  for ($i = 0; $i -lt $tries; $i++) {
    if ($wifi -and -not $seen -and $i -eq $tries - 1) {
      $more = Ask (L 'm154') 'menu' @((Opt '' (L 'w022')), (Opt 'Q' (L 'w023')))
      if ($more -notmatch '^[QqЙй]$' -and $ext -lt 6) { $ext++; $tries += 30 }
    }
    $ms = @()
    if ($wifi) {
      $ms = @(Get-Mdns)
      foreach ($m in ($ms | Where-Object { $_.Kind -eq 'connect' })) { [void](Invoke-Adb @('connect', $m.Addr) 10) }
    }
    $s = Find-SameDevice $sn
    if ($s) {
      $seen = $true
      $script:Serial = $s
      if ((Sh 'getprop sys.boot_completed').Trim() -eq '1') { $up = $true; break }
    }
    if ($wifi -and -not $seen) {
      if (-not $hinted -and $i -ge 3) {
        $hinted = $true
        Say ''
        Say (L 'm155') 'Yellow'
        Say (L 'm156') 'Yellow'
        Say (L 'm157') 'Yellow'
        Say (L 'm158') 'Yellow'
      }
      $pw = @($ms | Where-Object { $_.Kind -eq 'pairing' -and -not $tried.ContainsKey($_.Addr) }) | Select-Object -First 1
      if ($pw) {
        $tried[$pw.Addr] = 1
        Ok (L 'm159' $($pw.Addr))
        $code = Ask (L 'm160') 'code6' $null @{ addr = $pw.Addr; skip = $true }
        if ($code -match '^\d{6}$') {
          $r = Invoke-Adb @('pair', $pw.Addr, $code) 30
          $txt = ($r.Out + ' ' + $r.Err).Trim()
          if ($txt -match 'Successfully paired') { Ok (L 'm161') }
          else { Warn (L 'm162' $txt) }
        }
        continue
      }
    }
    Start-Sleep -Seconds 10
  }
  $script:RebootOk = $up
  if (-not $up) {
    if ($seen) {
      OptLog (L 'm163') 'bad'
      if (Confirm-Yes (L 'm164') (L 'w011')) { Undo-Journal 0 }
      Say (L 'm165') 'Yellow'
    } else {
      if ($wifi) {
        OptLog (L 'm166') 'warn'
      } else {
        OptLog (L 'm167') 'warn'
      }
    }
    return
  }
  Start-Sleep -Seconds 15
  $dis = Get-DisabledSet; $inst = Get-InstalledSet
  $back = @()
  foreach ($e in $script:Journal) {
    if ($e.t -eq 'disable' -and -not $dis.Contains([string]$e.pkg)) { $back += [string]$e.pkg }
    if ($e.t -eq 'uninstall' -and $inst.Contains([string]$e.pkg)) { $back += [string]$e.pkg }
  }
  if ($back.Count) { OptLog ((L 'm168') + ($back -join ', ')) 'warn' }
  else { OptLog (L 'm169') 'ok' }
  $h = Get-Health
  if ($h.HomeBad) { OptLog (L 'm170' $($h.Home)) 'bad' } else { OptLog ((L 'm171') + $h.Home) 'ok' }
  if (-not $h.SysUi) { OptLog (L 'm172') 'bad' }
}

function Invoke-Optimization {
  Emit 'stage' @{ s = 'plan' }
  Title (L 'm173')
  $items = New-Object System.Collections.ArrayList
  function AddItem($kind, $pkg, $text, $on, $group, $tier = '') { [void]$items.Add([pscustomobject]@{ Kind = $kind; Pkg = $pkg; Text = $text; On = [bool]$on; Group = $group; Tier = $tier }) }

  $animNow = $set['anim_w']
  if ($animNow -notin @('0.5', '0.5f', '0', '0.0')) { AddItem 'anim' '' (L 'm174' $(if ($animNow -and $animNow -ne 'null') { $animNow } else { '1x' })) $true (L 'm175') }
  if ($set['dns_mode'] -ne 'hostname') {
    # Оба варианта; профиль «Ребёнок» на странице отмечает семейный. Отмечены оба — берётся семейный.
    if ($kids) { AddItem 'dns' 'family.adguard-dns.com' (L 'm176') $false (L 'm175'); AddItem 'dns' 'dns.adguard-dns.com' (L 'm177') $false (L 'm175') }
    else { AddItem 'dns' 'dns.adguard-dns.com' (L 'm177') $false (L 'm175'); AddItem 'dns' 'family.adguard-dns.com' (L 'm176') $false (L 'm175') }
  }
  $cacheTxt = (L 'm178')
  if ($cacheMb -gt 0) { $cacheTxt += (L 'm179' $cacheMb) }
  $cacheTxt += (L 'm180')
  AddItem 'cache' '' $cacheTxt ($dataPct -ge 85) (L 'm175')

  foreach ($s in $suspOk) { AddItem 'third' $s.Pkg ((L 'm181' $($s.Pkg) $($s.Why))) $false (L 'm182') }

  foreach ($c in $candOk) {
    $txt = (L 'm183' $($c.Pkg))
    if ($c.Note) { $txt += " — $($c.Note)" }
    if ($c.Mb -gt 0) { $txt += (L 'm184' $($c.Mb)) }
    if ($c.Ask) { $txt += "  ($($c.Ask))" }
    if ($c.Tier -eq 'base') { $txt += (L 'm185') }
    $grp = @{ 'auto' = (L 'm186'); 'base' = (L 'm187'); 'ask' = (L 'm188') }[$c.Tier]
    AddItem 'disable' $c.Pkg $txt ($c.Tier -eq 'auto') $grp $c.Tier
  }
  foreach ($b in $bgCands) { AddItem 'bg' $b.Pkg ((L 'm190' $($b.Pkg) $(if ($b.Mb -gt 0) { (L 'm189' $($b.Mb)) }))) $true (L 'm191') }

  if ($items.Count -eq 0) { OptLog (L 'm192') 'ok'; return }

  while ($true) {
    Say ''
    $g = ''
    for ($i = 0; $i -lt $items.Count; $i++) {
      $it = $items[$i]
      if ($it.Group -ne $g) { $g = $it.Group; Say ("  --- $g ---") 'Cyan' }
      if ($it.On) { Say ("  [x] {0,2}. {1}" -f ($i + 1), $it.Text) 'Green' } else { Say ("  [ ] {0,2}. {1}" -f ($i + 1), $it.Text) 'Gray' }
    }
    Say ''
    Say (L 'm193') 'Green'
    Say (L 'm194') 'Gray'
    Say (L 'm195') 'Cyan'
    Say (L 'm196') 'Cyan'
    $pl = @(for ($i = 0; $i -lt $items.Count; $i++) { $it = $items[$i]; [ordered]@{ n = $i + 1; kind = $it.Kind; pkg = $it.Pkg; text = $it.Text; on = [bool]$it.On; group = $it.Group; tier = $it.Tier } })
    $a = Ask (L 'm197') 'plan' $null @{ items = $pl }
    if ($a -eq '') { break }
    if ($a.StartsWith('=')) {
      # страница присылает итоговый выбор: =1,3,7 (или просто =) — и сразу дальше
      $nums = @($a.Substring(1) -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
      for ($i = 0; $i -lt $items.Count; $i++) { $items[$i].On = ($nums -contains ($i + 1)) }
      break
    }
    if ($a -match '^[QqЙй]$') { OptLog (L 'm198'); return }
    if ($a -match '^[AaФф]$') { foreach ($it in $items) { $it.On = $true }; continue }
    if ($a -match '^[BbИи]$') { foreach ($it in $items) { if ($it.Tier -eq 'base') { $it.On = $true } }; continue }
    if ($a -eq '0') { foreach ($it in $items) { $it.On = $false }; continue }
    $nums = New-Object System.Collections.ArrayList
    foreach ($n in ($a -split '[\s,;]+')) {
      if ($n -match '^(\d+)-(\d+)$') { for ($k = [int]$Matches[1]; $k -le [int]$Matches[2]; $k++) { [void]$nums.Add($k) } }
      elseif ($n -match '^\d+$') { [void]$nums.Add([int]$n) }
    }
    $off = @(); $onl = @()
    foreach ($k in $nums) {
      if ($k -lt 1 -or $k -gt $items.Count) { continue }
      $items[$k - 1].On = -not $items[$k - 1].On
      if ($items[$k - 1].On) { $onl += $k } else { $off += $k }
    }
    if ($off.Count -gt 0) { Say ((L 'm199') + ($off -join ' ')) 'Yellow' }
    if ($onl.Count -gt 0) { Say ((L 'm200') + ($onl -join ' ')) 'Green' }
    if ($off.Count -eq 0 -and $onl.Count -eq 0) { Warn (L 'm201') }
  }
  $sel = @($items | Where-Object { $_.On })
  if ($sel.Count -eq 0) { OptLog (L 'm202'); return }
  Say ''
  Say (L 'm203') 'White'
  foreach ($it in $sel) { Say ("  - " + $it.Text) }
  $autoOff = @($items | Where-Object { -not $_.On -and $_.Kind -eq 'disable' -and $_.Tier -eq 'auto' })
  if ($autoOff.Count -gt 0) { Warn ((L 'm204') -f $autoOff.Count, (($autoOff | ForEach-Object { $_.Pkg }) -join ', ')) }
  Say ((L 'm205') -f $sel.Count) 'White'
  if (-not (Confirm-Yes (L 'm206') (L 'w012'))) { OptLog (L 'm207'); return }

  # --- снимок «до» и журнал — до первого изменения
  $bdir = Join-Path $RepDir 'backup'
  $kdir = Join-Path $Root 'backups'
  New-Item -ItemType Directory -Force -Path $bdir, $kdir | Out-Null
  $script:StateFiles = @((Join-Path $bdir 'state.json'), (Join-Path $kdir ($repName + '.json')))
  $script:ChangeLog = Join-Path $RepDir 'changes.log'
  $script:Journal = New-Object System.Collections.ArrayList
  $script:State = [ordered]@{
    kit = "phone-kit $KitVersion"; created = (Get-Date -Format 's'); label = $Label; serial = $script:Serial; serialno = (P 'ro.serialno')
    model = $model; device = (P 'ro.product.device'); fingerprint = (P 'ro.build.fingerprint'); sdk = $script:sdk
    before = [ordered]@{ disabled = @($disabled | Sort-Object); uninstalled = @($preUninst | Sort-Object); home = $homeComp; anim = @($set['anim_w'], $set['anim_t'], $set['anim_d']); dns = @($set['dns_mode'], $set['dns_spec']) }
    journal = $script:Journal
  }
  Save-State
  OptLog ((L 'm208') + $script:StateFiles[0]) 'ok'
  $base = Get-Health
  if ($base.HomeBad) { OptLog (L 'm209' $($base.Home)) 'warn' }

  Emit 'stage' @{ s = 'run' }
  Title (L 'm210')
  $script:SnapBefore = Get-Snap
  $stopped = $false
  if ($sel | Where-Object { $_.Kind -eq 'anim' }) { Set-Anim '0.5' }
  $d = $sel | Where-Object { $_.Kind -eq 'dns' } | Sort-Object { if ($_.Pkg -like 'family*') { 0 } else { 1 } } | Select-Object -First 1
  if ($d) { [void](Set-Dns $d.Pkg) }
  if ($sel | Where-Object { $_.Kind -eq 'cache' }) { Clear-Caches }

  $pk = @($sel | Where-Object { $_.Kind -in @('disable', 'third') })
  for ($i = 0; $i -lt $pk.Count; $i += 5) {
    $batch = $pk[$i..([math]::Min($i + 4, $pk.Count - 1))]
    $start = $script:Journal.Count
    foreach ($x in $batch) { [void](Disable-Pkg $x.Pkg -Third:($x.Kind -eq 'third')) }
    Emit 'progress' @{ done = [math]::Min($i + 5, $pk.Count); total = $pk.Count }
    $prob = Compare-Health $base (Get-Health)
    if ($prob.Count) {
      OptLog ((L 'm211') + ($prob -join '; ') + (L 'm212')) 'bad'
      Undo-Journal $start; $stopped = $true; break
    }
    OptLog ((L 'm213') -f ([math]::Floor($i / 5) + 1)) 'ok'
  }
  if (-not $stopped) {
    foreach ($b in @($sel | Where-Object { $_.Kind -eq 'bg' })) { [void](Restrict-Bg $b.Pkg) }
  }

  Say ''
  if ($script:Journal.Count -eq 0) { OptLog (L 'm214') 'warn'; return }
  Start-Sleep -Seconds 10
  $script:SnapAfter = Get-Snap
  Emit 'compare' ([ordered]@{ before = $script:SnapBefore; after = $script:SnapAfter; reboot = $false })
  Say (L 'm215') 'Cyan'
  Say (L 'm216') 'Cyan'
  if (Confirm-Yes (L 'm217') (L 'w013')) {
    OptLog (L 'm218') 'warn'
    Undo-Journal 0
    OptLog ((L 'm219') + (Get-HomeComp)) 'ok'
    return
  }
  if (Confirm-Yes (L 'm220') (L 'w014')) {
    Invoke-RebootCheck
    if ($script:RebootOk) {
      Start-Sleep -Seconds 20
      $sa = Get-Snap
      if ($sa.memAvailMb -gt 0) { $script:SnapAfter = $sa; $script:SnapAfterReboot = $true; Emit 'compare' ([ordered]@{ before = $script:SnapBefore; after = $sa; reboot = $true }) }
    }
  }
  OptLog ((L 'm221') -f $script:Journal.Count, $repName) 'ok'
}

function Invoke-Restore {
  Emit 'stage' @{ s = 'restore' }
  Title (L 'm222')
  $script:Props = Parse-Props (Sh 'getprop')
  $script:sdk = 0; [void][int]::TryParse((P 'ro.build.version.sdk'), [ref]$script:sdk)
  $mdl = P 'ro.product.model'; $fp = P 'ro.build.fingerprint'; $sn = P 'ro.serialno'
  $found = @()
  foreach ($d in @((Join-Path $Root 'backups'), (Join-Path $Root 'reports'))) {
    if (-not (Test-Path $d)) { continue }
    foreach ($f in (Get-ChildItem -Path $d -Recurse -Filter '*.json' -File)) {
      try {
        $j = Get-Content -Raw -Encoding UTF8 -Path $f.FullName | ConvertFrom-Json
        if ($j.model -eq $mdl -and @($j.journal).Count -gt 0) {
          $same = (-not $j.serialno) -or (-not $sn) -or ($j.serialno -eq $sn)
          $found += [pscustomobject]@{ File = $f.FullName; J = $j; Key = ([string]$j.created + '|' + [string]$j.label); Same = $same }
        }
      } catch {}
    }
  }
  if ($found.Count -eq 0) {
    Warn (L 'm223' $mdl)
    Say (L 'm224')
    return
  }
  $groups = @($found | Group-Object Key | Sort-Object { $_.Group[0].J.created } -Descending)
  for ($i = 0; $i -lt $groups.Count; $i++) {
    $j = $groups[$i].Group[0].J
    $same = if ($j.fingerprint -eq $fp) { (L 'm225') } else { (L 'm226') }
    if (-not $groups[$i].Group[0].Same) { $same += (L 'm227') }
    $when = $j.created; if ($when -is [datetime]) { $when = $when.ToString('yyyy-MM-dd HH:mm') }
    Say ((L 'm228') -f ($i + 1), $when, $j.label, @($j.journal).Count, $same) 'White'
  }
  $ropts = @(for ($i = 0; $i -lt $groups.Count; $i++) { $j = $groups[$i].Group[0].J; $when = $j.created; if ($when -is [datetime]) { $when = $when.ToString('yyyy-MM-dd HH:mm') }; Opt ([string]($i + 1)) ("{0}  {1}  ({2})" -f $when, $j.label, @($j.journal).Count) })
  $ropts += (Opt 'Q' (L 'w021'))
  $a = Ask (L 'm229') 'menu' $ropts
  if ($a -match '^[QqЙй]$') { return }
  $n = 1; if ($a -match '^\d+$') { $n = [int]$a }
  if ($n -lt 1 -or $n -gt $groups.Count) { Warn (L 'm230'); return }
  $g = $groups[$n - 1]
  $j = $g.Group[0].J
  Say ''
  Say (L 'm231') 'White'
  $entries = @($j.journal)
  $pick = @()
  for ($i = 0; $i -lt $entries.Count; $i++) {
    $e = $entries[$i]
    $t = switch ([string]$e.t) {
      'disable' { (L 'm232' $($e.pkg)) }
      'uninstall' { (L 'm233' $($e.pkg)) }
      'setting' { (L 'm234' $($e.key) $(if ($e.old -and $e.old -ne 'null') { $e.old } else { (L 'm146') })) }
      'appops' { (L 'm235' $($e.pkg)) }
      default { [string]$e.t }
    }
    $t = ($t.Trim() -replace '^-\s*', '')
    Say ("{0,3}. {1}" -f ($i + 1), $t)
    $pick += [ordered]@{ n = $i + 1; text = $t; pkg = [string]$e.pkg; label = $(if ($e.pkg) { Get-PkgLabel ([string]$e.pkg) } else { '' }) }
  }
  # Выборочный откат: Enter — всё; номера — только они; страница присылает «=1,4,7»
  $sel = Ask (L 'r001') 'pick' $null @{ items = $pick }
  if ($sel -match '^[QqЙй]$' -or $sel -eq '=') { Say (L 'm237'); return }
  $only = $null
  $s2 = $sel.TrimStart('=')
  if ($s2 -match '\d') {
    $only = @($s2 -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 } | Where-Object { $_ -ge 0 -and $_ -lt $entries.Count } | Select-Object -Unique)
    if ($only.Count -eq 0) { Say (L 'm237'); return }
    Say (L 'r002' $only.Count $entries.Count) 'White'
  }
  if (-not $sel.StartsWith('=')) { if (-not (Confirm-Yes (L 'm236') (L 'w015'))) { Say (L 'm237'); return } }
  $stamp2 = Get-Date -Format 'yyyy-MM-dd_HH-mm'
  $rd = Join-Path $Root ("reports/" + $stamp2 + '_restore_' + ($mdl -replace '[^A-Za-z0-9_.-]', '_'))
  New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $script:ChangeLog = Join-Path $rd 'changes.log'
  $script:OptLines = New-Object System.Collections.ArrayList
  $script:StateFiles = @($g.Group | ForEach-Object { $_.File })
  $script:Journal = New-Object System.Collections.ArrayList
  foreach ($e in $entries) { [void]$script:Journal.Add($e) }
  $script:State = $j
  $script:State.journal = $script:Journal
  $script:keepSet = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($null -ne $only) { Undo-Selected $only } else { Undo-Journal 0 }
  if ($script:Journal.Count -gt 0) { OptLog (L 'r003' $script:Journal.Count) 'ok' }
  $h = Get-HomeComp
  if (Test-HomeBad $h) { OptLog (L 'm238' $h) 'warn' } else { OptLog (L 'm239' $h) 'ok' }
  OptLog (L 'm240')
  [IO.File]::WriteAllText((Join-Path $rd 'restore.txt'), ($script:OptLines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
  Ok ((L 'm241') + $rd)
}

# ----------------------------------------------------------------- старт

$script:Notes = New-Object System.Collections.ArrayList
$script:AdbStarted = $false
$script:RuLevel = @{}

if ($Prepare) { Invoke-Prepare }

Clear-Host
Say (L 'm242' $KitVersion) 'Cyan'
Say ((L 'm243' $Root))
$script:Adb = Get-AdbBinary
Ok "ADB: $script:Adb"

# База пакетов и наши пометки
$ruFile = Join-Path $Root 'data/ru.tsv'
$uadFile = Join-Path $Root 'data/uad.tsv'
$ruNote = @{}
if (Test-Path $ruFile) { foreach ($r in (Import-Csv -Path $ruFile -Delimiter "`t" -Encoding UTF8)) { $script:RuLevel[$r.package] = $r.level; $ruNote[$r.package] = $r.note } }
# Пояснения к пакетам на языке мастера: data/notes/<код>.tsv (package, note); нет файла — английский
if ($script:Lang -ne 'ru') {
  $nf = Join-Path (Join-Path $Root 'data') (Join-Path 'notes' ($script:Lang + '.tsv'))
  if (-not (Test-Path -LiteralPath $nf)) { $nf = Join-Path (Join-Path $Root 'data') (Join-Path 'notes' 'en.tsv') }
  if (Test-Path -LiteralPath $nf) { foreach ($r in (Import-Csv -Path $nf -Delimiter "`t" -Encoding UTF8)) { if ($r.note) { $ruNote[$r.package] = $r.note } } }
}

# Интерфейс: страница в браузере (по умолчанию), консоль — запасной вариант и для тестов
$useWeb = $Web -or (-not $Console -and -not [Console]::IsInputRedirected)
if ($useWeb) { if (-not (Start-Web)) { Warn (L 'w005') } }
# Новая версия на GitHub? (4 секунды максимум; без интернета — молча дальше)
if (-not $NoUpdateCheck) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uu = $(if ($UpdateUrl) { $UpdateUrl } else { 'https://api.github.com/repos/Meteoric-Potential-Unipessoal-Lda/phone-kit/releases/latest' })
    $rel = Invoke-RestMethod -Uri $uu -TimeoutSec 4 -UseBasicParsing -Headers @{ 'User-Agent' = 'phone-kit' }
    $tag = ([string]$rel.tag_name) -replace '^[vV]', ''
    $nv = $null; $cv = $null
    if ([version]::TryParse(($tag + '.0').Split('-')[0], [ref]$nv) -and [version]::TryParse($KitVersion + '.0', [ref]$cv) -and $nv -gt $cv) {
      $link = $(if ($rel.html_url) { [string]$rel.html_url } else { 'https://github.com/Meteoric-Potential-Unipessoal-Lda/phone-kit/releases/latest' })
      Warn (L 'u001' $tag $link)
      Emit 'update' @{ version = $tag; url = $link }
    }
  } catch {}
}
Emit 'stage' @{ s = 'start' }
$Mode = 'diag'
while ($true) {
  Say ''
  Say (L 'm244') 'White'
  Say (L 'm245') 'White'
  Say (L 'm246') 'White'
  Say (L 'm247') 'White'
  Say (L 'm248') 'White'
  $m = Ask (L 'm249') 'menu' @((Opt '1' ((L 'm245') -replace '^\s*\w\)\s*', '')), (Opt '2' ((L 'm246') -replace '^\s*\w\)\s*', '')), (Opt '3' ((L 'm247') -replace '^\s*\w\)\s*', '')), (Opt 'Q' ((L 'm248') -replace '^\s*\w\)\s*', ''))) @{ screen = 'start' }
  if ($m -eq '1') { $Mode = 'diag'; break }
  if ($m -eq '2') { $Mode = 'opt'; break }
  if ($m -eq '3') { $Mode = 'restore'; break }
  if ($m -match '^[QqЙй]$') { Finish 0 }
}
if (-not $Label -and $Mode -ne 'restore') { $Label = Ask (L 'm250') 'text' $null @{ optional = $true } }

# Встроенный поиск по сети (mDNS) в adb: на Windows без Bonjour работает только с этим ключом.
# Сервер перезапускаем, чтобы он подхватил ключ (если adb уже был запущен без него).
$env:ADB_MDNS_OPENSCREEN = '1'
[void](Invoke-Adb @('kill-server') 15)
[void](Invoke-Adb @('start-server') 30)
$script:AdbStarted = $true

Emit 'stage' @{ s = 'connect'; mode = $Mode }
Title (L 'm251')
$script:Serial = Select-Phone
if (-not (Wait-Authorized $script:Serial)) {
  Bad (L 'm252')
  Show-EnableHelp; Finish 1
}
Ok (L 'm253' $script:Serial)
Emit 'device' @{ model = (Get-Model $script:Serial); serial = $script:Serial; wifi = ($script:Serial -match ':\d+$|_adb-tls') }
if ((Sh 'getprop ro.build.characteristics') -match 'tv') {
  Warn (L 'm254')
  if (-not (Confirm-Yes (L 'm255') (L 'w016'))) { Finish 0 }
}
if ($Mode -eq 'restore') { Invoke-Restore; Finish 0 }
$script:OptLines = New-Object System.Collections.ArrayList

# ----------------------------------------------------------------- сбор

Emit 'stage' @{ s = 'diag'; mode = $Mode }
Title (L 'm256')
$propsTxt = Sh 'getprop'
$script:Props = Parse-Props $propsTxt
$model = P 'ro.product.model'
$safeModel = ($model -replace '[^A-Za-z0-9_.-]', '_')
if (-not $safeModel) { $safeModel = 'phone' }
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$safeLabel = ($Label -replace '[\\/:*?"<>|\s]+', '_').Trim('_')
$repName = ($stamp, $safeLabel, $safeModel | Where-Object { $_ }) -join '_'
$RepDir = Join-Path $Root ("reports/" + $repName)
$script:RawDir = Join-Path $RepDir 'raw'
New-Item -ItemType Directory -Force -Path $script:RawDir | Out-Null
Save-Raw 'getprop.txt' $propsTxt

$sdk = 0; [void][int]::TryParse((P 'ro.build.version.sdk'), [ref]$sdk)
$step = 0
function Step([string]$t) { $script:step++; Say ("  [{0}] {1}" -f $script:step, $t) }

Step (L 'm257')
$memTxt = Sh 'cat /proc/meminfo'; Save-Raw 'meminfo.txt' $memTxt
$mem = Parse-Meminfo $memTxt
$upTxt = Sh 'cat /proc/uptime'
$uptimeSec = 0; if ($upTxt -match '^(\d+)') { $uptimeSec = [int64]$Matches[1] }
$load = (Sh 'cat /proc/loadavg').Trim()
function Parse-Ps([string]$t) {
  $r = @()
  foreach ($l in ($t -split "`n")) {
    if ($l -match '^\s*(\d+)\s+(\S+)\s*$') { $r += [pscustomobject]@{ Kb = [int64]$Matches[1]; Name = $Matches[2] } }
    elseif ($l -match '^\S+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(\S+)\s*$') { $r += [pscustomobject]@{ Kb = [int64]$Matches[1]; Name = $Matches[2] } }
  }
  return ,$r
}
$procs = @(); $psTxt = ''
foreach ($pc in @('ps -A -o RSS,NAME', 'ps -A', 'ps')) {
  $psTxt = Sh $pc
  $procs = Parse-Ps $psTxt
  if ($procs.Count -ge 3) { $script:PsCmd = $pc; break }
}
Save-Raw 'ps.txt' $psTxt
$topProcs = $procs | Sort-Object Kb -Descending | Select-Object -First 15
function Get-PkgRssMb([string]$pkg) {
  $kb = 0
  foreach ($pr in $procs) { if ($pr.Name -eq $pkg -or $pr.Name.StartsWith($pkg + ':')) { $kb += $pr.Kb } }
  return (Mb $kb)
}
function Test-Running([string]$pkg) { foreach ($pr in $procs) { if ($pr.Name -eq $pkg -or $pr.Name.StartsWith($pkg + ':')) { return $true } }; return $false }

Step (L 'm258')
$cpuTxt = Sh 'dumpsys cpuinfo'; Save-Raw 'cpuinfo.txt' $cpuTxt
$cpuTotal = ''
if ($cpuTxt -match '(?m)^\s*([\d.]+)% TOTAL') { $cpuTotal = $Matches[1] }
$cpuTop = @()
foreach ($l in ($cpuTxt -split "`n")) { if ($l -match '^\s*([\d.]+)%\s+\d+/([^:]+):') { $cpuTop += [pscustomobject]@{ Pct = [double]$Matches[1]; Name = $Matches[2] } } }
$cpuTop = $cpuTop | Sort-Object Pct -Descending | Select-Object -First 8
$cores = @()
$present = (Sh 'cat /sys/devices/system/cpu/present').Trim()
$nCpu = 0; if ($present -match '^\d+-(\d+)$') { $nCpu = [int]$Matches[1] + 1 } elseif ($present -match '^\d+$') { $nCpu = 1 }
for ($c = 0; $c -lt [math]::Min($nCpu, 16); $c++) {
  $mx = (Sh "cat /sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq").Trim()
  $cu = (Sh "cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq").Trim()
  if ($mx -match '^\d+$') { $cores += [pscustomobject]@{ Cpu = $c; MaxMhz = [math]::Round([int64]$mx / 1000); CurMhz = $(if ($cu -match '^\d+$') { [math]::Round([int64]$cu / 1000) } else { 0 }) } }
}
$batTxt = Sh 'dumpsys battery'; Save-Raw 'battery.txt' $batTxt
# Расход батареи с последней зарядки по приложениям: «Estimated power use» из batterystats, uid -> пакет
$batApps = @(); $batSince = ''
try {
  $bsTxt = Sh 'dumpsys batterystats' 120
  $uidPk = @{}
  foreach ($l in ((Sh 'pm list packages -U') -split "`n")) { if ($l -match '^package:([A-Za-z0-9_.]+)\s+uid:(\d+)') { $u = [int]$Matches[2]; if (-not $uidPk.ContainsKey($u)) { $uidPk[$u] = $Matches[1] } } }
  if ($bsTxt -match '(?m)Time on battery:\s*([^(\r\n]+)') { $batSince = $Matches[1].Trim() }
  $at = $bsTxt.IndexOf('Estimated power use')
  if ($at -ge 0) {
    $seen = $false; $sum = @{}
    foreach ($l in ($bsTxt.Substring($at) -split "`n" | Select-Object -Skip 1)) {
      if (-not $l.Trim()) { if ($seen) { break } else { continue } }
      if ($l -match '^\s*(?:Uid|UID) (?:u(\d+)a(\d+)|(\d+)):\s*([\d.]+)') {
        $seen = $true
        $uid = if ($Matches[2]) { 10000 + [int]$Matches[2] } else { [int]$Matches[3] }
        $mah = 0.0; [void][double]::TryParse($Matches[4], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mah)
        if ($uid -ge 10000 -and $mah -gt 0) { $sum[$uid] = [double]$sum[$uid] + $mah }
      }
    }
    $tot = 0.0; foreach ($v in $sum.Values) { $tot += $v }
    $batApps = @($sum.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object {
      $pkg = $(if ($uidPk.ContainsKey([int]$_.Key)) { $uidPk[[int]$_.Key] } else { 'uid ' + $_.Key })
      [pscustomobject]@{ Pkg = $pkg; Mah = [math]::Round($_.Value, 1); Pct = $(if ($tot -gt 0) { [math]::Round(100 * $_.Value / $tot) } else { 0 }) }
    })
  }
  Save-Raw 'battery_usage.txt' ((@("since: $batSince") + @($batApps | ForEach-Object { "{0}`t{1}`t{2}%" -f $_.Pkg, $_.Mah, $_.Pct })) -join "`n")
} catch {}
$batLevel = ''; $batTemp = 0.0; $batHealth = ''; $batPlug = ''
if ($batTxt -match '(?m)^\s*level: (\d+)') { $batLevel = $Matches[1] }
if ($batTxt -match '(?m)^\s*temperature: (\d+)') { $batTemp = [double]$Matches[1] / 10 }
if ($batTxt -match '(?m)^\s*health: (\d+)') { $batHealth = $Matches[1] }
if ($batTxt -match '(?m)^\s*(AC|USB|Wireless) powered: true') { $batPlug = $Matches[1] }
$healthName = @{ '1' = (L 'm259'); '2' = (L 'm260'); '3' = (L 'm261'); '4' = (L 'm262'); '5' = (L 'm263'); '6' = (L 'm264'); '7' = (L 'm265') }[$batHealth]
$thTxt = Sh 'dumpsys thermalservice'; Save-Raw 'thermal.txt' $thTxt
$thStatus = 0; if ($thTxt -match 'Thermal Status: (\d+)') { $thStatus = [int]$Matches[1] }
$temps = @{}
$curSec = $thTxt
$ci = $thTxt.IndexOf('Current temperatures from HAL'); if ($ci -ge 0) { $curSec = $thTxt.Substring($ci); $cj = $curSec.IndexOf('Current cooling devices'); if ($cj -gt 0) { $curSec = $curSec.Substring(0, $cj) } }
foreach ($m in [regex]::Matches($curSec, 'mValue=([\d.]+), mType=(\d+)')) {
  $tn = @{ '0' = 'CPU'; '1' = 'GPU'; '2' = (L 'm266'); '3' = (L 'm267') }[$m.Groups[2].Value]
  if ($tn) { $v = [math]::Round([double]$m.Groups[1].Value, 1); if ($v -gt 0 -and $v -lt 150 -and (-not $temps.ContainsKey($tn) -or $temps[$tn] -lt $v)) { $temps[$tn] = $v } }
}

Step (L 'm268')
$dfTxt = Sh 'df -k /data'; Save-Raw 'df.txt' $dfTxt
$dataTotal = 0; $dataUsed = 0; $dataFree = 0
foreach ($l in ($dfTxt -split "`n")) { if ($l -match '^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%') { $dataTotal = [int64]$Matches[1]; $dataUsed = [int64]$Matches[2]; $dataFree = [int64]$Matches[3] } }
$dataPct = 0; if ($dataTotal -gt 0) { $dataPct = [math]::Round(100 * $dataUsed / $dataTotal) }
$dsTxt = Sh 'dumpsys diskstats' 60
$cacheMb = 0; $bigApps = @()
function Get-JsonArr([string]$name) { if ($dsTxt -match ('(?m)^' + [regex]::Escape($name) + ': \[(.*)\]')) { return @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"') }) } return @() }
$dsNames = Get-JsonArr 'App Package Names'; $dsApp = Get-JsonArr 'App Sizes'; $dsData = Get-JsonArr 'App Data Sizes'; $dsCache = Get-JsonArr 'Cache Sizes'
if ($dsNames.Count -gt 0 -and $dsCache.Count -eq $dsNames.Count) {
  $sumC = [int64]0
  for ($i = 0; $i -lt $dsNames.Count; $i++) {
    $cc = [int64]0; [void][int64]::TryParse($dsCache[$i], [ref]$cc); $sumC += $cc
    $aa = [int64]0; $dd = [int64]0
    if ($i -lt $dsApp.Count) { [void][int64]::TryParse($dsApp[$i], [ref]$aa) }
    if ($i -lt $dsData.Count) { [void][int64]::TryParse($dsData[$i], [ref]$dd) }
    $bigApps += [pscustomobject]@{ Pkg = $dsNames[$i]; Mb = [math]::Round(($aa + $dd + $cc) / 1MB); CacheMb = [math]::Round($cc / 1MB) }
  }
  $cacheMb = [math]::Round($sumC / 1MB)
  $bigApps = $bigApps | Sort-Object Mb -Descending | Select-Object -First 10
}
if ($dsTxt -match '(?m)^(Photos|Videos|Audio|Downloads|System|Other) Size') { Save-Raw 'diskstats_summary.txt' (($dsTxt -split "`n" | Where-Object { $_ -match '^(Data-Free|Cache-Free|System-Free|Latency|Photos|Videos|Audio|Downloads|System|Other) ' }) -join "`n") }
# Что занимает память: категории Android (diskstats) + папки мессенджеров и камеры (du, только чтение)
$storeCat = [ordered]@{}
foreach ($k in @('Photos', 'Videos', 'Audio', 'Downloads', 'App', 'App Data', 'App Cache', 'System', 'Other')) {
  if ($dsTxt -match ('(?m)^' + [regex]::Escape($k) + ' Size: (\d+)')) { $storeCat[$k] = [math]::Round([int64]$Matches[1] / 1MB) }
}
$msgDirs = [ordered]@{
  'WhatsApp' = @('/sdcard/Android/media/com.whatsapp/WhatsApp/Media', '/sdcard/WhatsApp/Media')
  'Telegram' = @('/sdcard/Android/media/org.telegram.messenger', '/sdcard/Telegram', '/sdcard/Android/data/org.telegram.messenger/files')
  'Viber' = @('/sdcard/Android/media/com.viber.voip', '/sdcard/viber')
  'DCIM' = @('/sdcard/DCIM'); 'Download' = @('/sdcard/Download'); 'Movies' = @('/sdcard/Movies')
}
$storeDirs = @()
try {
  $duTxt = Sh ('du -s -k ' + ((@($msgDirs.Values | ForEach-Object { $_ })) -join ' ')) 120
  $duKb = @{}; foreach ($l in ($duTxt -split "`n")) { if ($l -match '^(\d+)\s+(/\S+)') { $duKb[$Matches[2]] = [int64]$Matches[1] } }
  foreach ($k in $msgDirs.Keys) { $sk = [int64]0; foreach ($pth in $msgDirs[$k]) { if ($duKb.ContainsKey($pth)) { $sk += $duKb[$pth] } }; if ($sk -gt 0) { $storeDirs += [pscustomobject]@{ Name = $k; Mb = (Mb $sk) } } }
  Save-Raw 'storage_dirs.txt' $duTxt
} catch {}
function Dir-Mb([string]$n) { foreach ($d in $storeDirs) { if ($d.Name -eq $n) { return [double]$d.Mb } }; return 0 }
$storeTips = New-Object System.Collections.ArrayList
if ((Dir-Mb 'WhatsApp') -ge 1024) { [void]$storeTips.Add((L 's001' (Fmt-Mb (Dir-Mb 'WhatsApp')))) }
if ((Dir-Mb 'Telegram') -ge 1024) { [void]$storeTips.Add((L 's002' (Fmt-Mb (Dir-Mb 'Telegram')))) }
if ((Dir-Mb 'Viber') -ge 1024) { [void]$storeTips.Add((L 's003' (Fmt-Mb (Dir-Mb 'Viber')))) }
$pv = [double]$storeCat['Photos'] + [double]$storeCat['Videos']; if ($pv -lt (Dir-Mb 'DCIM')) { $pv = Dir-Mb 'DCIM' }
if ($pv -ge 5120) { [void]$storeTips.Add((L 's004' (Fmt-Mb $pv))) }
$dl = [math]::Max([double]$storeCat['Downloads'], (Dir-Mb 'Download')); if ($dl -ge 1024) { [void]$storeTips.Add((L 's005' (Fmt-Mb $dl))) }
if ($cacheMb -ge 1024) { [void]$storeTips.Add((L 's006' (Fmt-Mb $cacheMb))) }
if ($bigApps -and @($bigApps)[0].Mb -ge 3072) { [void]$storeTips.Add((L 's007' (@($bigApps)[0].Pkg) (Fmt-Mb (@($bigApps)[0].Mb)))) }

Step (L 'm269')
$all = Parse-PkgList (Sh 'pm list packages')
$allU = Parse-PkgList (Sh 'pm list packages -u')
$sys = Parse-PkgList (Sh 'pm list packages -s')
$third = Parse-PkgList (Sh 'pm list packages -3')
$disabled = Parse-PkgList (Sh 'pm list packages -d')
$preUninst = @($allU | Where-Object { -not $all.Contains($_) })
$instTxt = Sh 'pm list packages -i -3'
$installer = @{}
foreach ($l in ($instTxt -split "`n")) { if ($l -match '^package:([A-Za-z0-9_.]+)\s+installer=(\S+)') { $installer[$Matches[1]] = $Matches[2] } }
Save-Raw 'packages_all.txt' (($all | Sort-Object) -join "`n")
Save-Raw 'packages_3rdparty.txt' (($third | Sort-Object | ForEach-Object { "$_  installer=$($installer[$_])" }) -join "`n")
Save-Raw 'packages_disabled.txt' (($disabled | Sort-Object) -join "`n")
Save-Raw 'packages_uninstalled_user0.txt' (($preUninst | Sort-Object) -join "`n")
$launchable = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($l in ((Sh 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER') -split "`n")) {
  if ($l -match '^\s*([A-Za-z0-9_.]+)/') { [void]$launchable.Add($Matches[1]) }
}
$usersTxt = Sh 'pm list users'
$users = @(); foreach ($l in ($usersTxt -split "`n")) { if ($l -match 'UserInfo\{(\d+):([^:]*):') { $users += "$($Matches[1]) ($($Matches[2]))" } }
$featTxt = Sh 'pm list features'
$hasTel = ($featTxt -match 'feature:android\.hardware\.telephony(\s|$)')

Step (L 'm270')
$homeTxt = Sh 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
$homeComp = ''
foreach ($l in ($homeTxt -split "`n")) { if ($l -match '^\s*([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)\s*$') { $homeComp = $Matches[1] } }
$homePkg = ($homeComp -split '/')[0]
$roleTxt = ''; $roles = @{}
if ($sdk -ge 29) { $roleTxt = Sh 'dumpsys role'; $roles = Parse-Roles $roleTxt }
$ime = (Sh 'settings get secure default_input_method').Trim()
$imePkg = ($ime -split '/')[0]
$roleShort = [ordered]@{}
foreach ($rn in @('HOME', 'DIALER', 'SMS', 'BROWSER', 'ASSISTANT', 'WALLET', 'SYSTEM_SUPERVISION')) { $k = "android.app.role.$rn"; if ($roles.ContainsKey($k)) { $roleShort[$rn] = ($roles[$k] -join ', ') } }
Save-Raw 'roles.txt' ((($roleShort.Keys | ForEach-Object { "$_ = $($roleShort[$_])" }) -join "`n") + "`nHOME(resolve) = $homeComp`nIME = $ime")

Step (L 'm271')
$usageTxt = Sh 'dumpsys usagestats' 120
$usage = Parse-Usage $usageTxt
$usageOk = ($usage.Count -ge 5)
$usedPkgs = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($u in $usage.Values) { if ($u.Sec -ge 60 -or $u.Last -gt (Get-Date).AddDays(-30)) { [void]$usedPkgs.Add($u.Pkg) } }
$topUsage = $usage.Values | Where-Object { $_.Sec -ge 60 } | Sort-Object Sec -Descending | Select-Object -First 20
# В отчёт — только сводка (сам dumpsys usagestats содержит лишние подробности о жизни владельца)
Save-Raw 'usage_summary.txt' (($usage.Values | Sort-Object Sec -Descending | ForEach-Object { "{0}`t{1}`t{2}" -f $_.Pkg, $_.Sec, $(if ($_.Last -gt [datetime]::MinValue) { $_.Last.ToString('yyyy-MM-dd') } else { '' }) }) -join "`n")
if (-not $usageOk) { [void]$script:Notes.Add((L 'm272')) }

Step (L 'm273')
$a11y = (Sh 'settings get secure enabled_accessibility_services').Trim()
$nls = (Sh 'settings get secure enabled_notification_listeners').Trim()
function Pkgs-FromComponents([string]$s) { $r = @(); foreach ($x in ($s -split ':')) { if ($x -match '^([A-Za-z0-9_.]+)/') { $r += $Matches[1] } }; return ,$r }
$a11yPkgs = Pkgs-FromComponents $a11y
$nlsPkgs = Pkgs-FromComponents $nls
$dpTxt = Sh 'dumpsys device_policy'
$adminPkgs = @(); foreach ($m in [regex]::Matches($dpTxt, 'ComponentInfo\{([A-Za-z0-9_.]+)/')) { $adminPkgs += $m.Groups[1].Value }
$adminPkgs = @($adminPkgs | Select-Object -Unique)
$owner = ''
if ($dpTxt -match '(?m)Device Owner:\s*\r?\n?.*?admin=ComponentInfo\{([A-Za-z0-9_.]+)/') { $owner = (L 'm274' $($Matches[1])) }
elseif ($dpTxt -match 'Device Owner') { $owner = (L 'm275') }
Save-Raw 'device_policy_summary.txt' ("admins: " + ($adminPkgs -join ', ') + "`n" + $owner)
function Query-Op([string]$op) {
  $t = Sh "cmd appops query-op --user 0 $op allow"
  $r = @(); foreach ($l in ($t -split "`n")) { if ($l.Trim() -match '^[A-Za-z0-9_.]+$' -and $l.Trim() -match '\.') { $r += $l.Trim() } }
  return ,$r
}
$overlayPkgs = @(); $installPkgs = @()
if ($sdk -ge 29) { $overlayPkgs = Query-Op 'SYSTEM_ALERT_WINDOW'; $installPkgs = Query-Op 'REQUEST_INSTALL_PACKAGES' }

Step (L 'm276')
$connTxt = Sh 'dumpsys connectivity'
$netType = (L 'm277')
if ($connTxt -match 'Active default network: (\d+)') {
  $nid = $Matches[1]
  foreach ($l in ($connTxt -split "`n")) {
    if ($l -match "NetworkAgentInfo\{.*?network\{$nid\}" -or $l -match "NetworkAgentInfo \[.*?- $nid\]" -or $l -match "netId[:=] ?$nid\b") {
      if ($l -match 'WIFI') { $netType = 'Wi-Fi'; break }
      if ($l -match 'CELLULAR|MOBILE') { $netType = (L 'm278'); break }
      if ($l -match 'VPN') { $netType = 'VPN'; break }
    }
  }
}
$dnsBroken = ($connTxt -match 'PRIVATE_DNS_BROKEN')
function G([string]$ns, [string]$k) { return (Sh "settings get $ns $k").Trim() }
$set = [ordered]@{
  'anim_w' = (G global window_animation_scale)
  'anim_t' = (G global transition_animation_scale)
  'anim_d' = (G global animator_duration_scale)
  'low_power' = (G global low_power)
  'dns_mode' = (G global private_dns_mode)
  'dns_spec' = (G global private_dns_specifier)
  'finish_act' = (G global always_finish_activities)
  'bg_limit' = (G global background_process_limit)
  'verifier' = (G global package_verifier_enable)
  'adb' = (G global adb_enabled)
  'adb_wifi' = (G global adb_wifi_enabled)
  'ime' = $ime
}
$setLabel = [ordered]@{
  'anim_w' = (L 'm279')
  'anim_t' = (L 'm280')
  'anim_d' = (L 'm281')
  'low_power' = (L 'm282')
  'dns_mode' = (L 'm283')
  'dns_spec' = (L 'm284')
  'finish_act' = (L 'm285')
  'bg_limit' = (L 'm286')
  'verifier' = (L 'm287')
  'adb' = (L 'm288')
  'adb_wifi' = (L 'm289')
  'ime' = (L 'm290')
}
Save-Raw 'settings.txt' ((($set.Keys | ForEach-Object { "$_ = $($set[$_])" }) -join "`n") + "`naccessibility = $a11y`nnotification_listeners = $nls")

Step (L 'm291')
$crashTxt = Sh 'logcat -d -b crash -t 400'
Save-Raw 'crash_log.txt' $crashTxt
$crashes = @{}
foreach ($l in ($crashTxt -split "`n")) {
  if ($l -match 'Process: ([A-Za-z0-9_.:]+)') { $k = $Matches[1]; if ($crashes.ContainsKey($k)) { $crashes[$k]++ } else { $crashes[$k] = 1 } }
}
$oomBitmap = ($crashTxt -match 'OutOfMemoryError' -and $crashTxt -match '(?i)bitmap')

# ----------------------------------------------------------------- анализ

Title (L 'm292')
$manu = (P 'ro.product.manufacturer'); $brand = (P 'ro.product.brand')
$skin = ''
if (P 'ro.build.version.oneui') { $v = [int](P 'ro.build.version.oneui'); $skin = ('One UI {0}.{1}' -f [math]::Floor($v / 10000), [math]::Floor(($v % 10000) / 100)) }
elseif (P 'ro.mi.os.version.name') { $skin = 'HyperOS ' + (P 'ro.mi.os.version.name') + ' ' + (P 'ro.mi.os.version.incremental') }
elseif (P 'ro.miui.ui.version.name') { $skin = 'MIUI ' + (P 'ro.miui.ui.version.name') + ' ' + (P 'ro.build.version.incremental') }
elseif (P 'ro.build.version.realmeui') { $skin = 'realme UI ' + (P 'ro.build.version.realmeui') }
elseif (P 'ro.build.version.opporom') { $skin = 'ColorOS ' + (P 'ro.build.version.opporom') }
elseif (P 'ro.build.version.emui') { $skin = (P 'ro.build.version.emui') }
elseif (P 'ro.build.version.magic') { $skin = 'MagicOS ' + (P 'ro.build.version.magic') }
$isTablet = ((P 'ro.build.characteristics') -match 'tablet')
$devType = $(if ($isTablet) { (L 'm293') } else { (L 'm294') }) + $(if ($hasTel) { (L 'm295') } else { (L 'm296') })
$vb = P 'ro.boot.verifiedbootstate'
$hasGms = $all.Contains('com.google.android.gms')

$uad = @{}
if (Test-Path $uadFile) { foreach ($r in (Import-Csv -Path $uadFile -Delimiter "`t" -Encoding UTF8)) { $uad[$r.package] = $r } }
else { [void]$script:Notes.Add((L 'm297')) }

# Кого не трогать никогда на этом телефоне: приложения по умолчанию, клавиатура, спецвозможности, уведомления, администраторы
$roleSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($k in $roles.Keys) { foreach ($x in $roles[$k]) { [void]$roleSet.Add($x) } }
foreach ($x in @($homePkg, $imePkg)) { if ($x -and $x -ne 'null') { [void]$roleSet.Add($x) } }
$keepSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($x in $roleSet) { [void]$keepSet.Add($x) }
foreach ($x in @($a11yPkgs + $nlsPkgs + $adminPkgs)) { [void]$keepSet.Add($x) }
$script:keepSet = $roleSet   # для Disable-Pkg -Third (подозрительные сторонние) проверяем только роли
$kids = ($all.Contains('com.google.android.apps.kids.familylinkhelper') -or $roles.ContainsKey('android.app.role.SYSTEM_SUPERVISION') -or ($dpTxt -match '(?i)supervision|kids') -or $all.Contains('com.sec.android.app.kidshome'))
$launchOk = ($launchable.Count -ge 5)

# --- кандидаты: включённые системные пакеты из базы
$cands = @()
foreach ($pkg in $sys) {
  if ($disabled.Contains($pkg)) { continue }
  $u = $uad[$pkg]; $rl = $script:RuLevel[$pkg]
  if (-not $u -and $rl -notin @('ok', 'ask', 'protect')) { continue }
  $removal = if ($u) { $u.removal } elseif ($rl -eq 'ok') { 'Recommended' } else { 'Advanced' }
  if ($removal -in @('Expert', 'Unsafe') -and $rl -notin @('ok', 'ask')) { continue }
  $why = @()
  if (Test-Protected $pkg) { $why += (L 'm298') }
  if ($pkg -like 'com.android.*' -and $pkg -ne 'com.android.chrome' -and $removal -ne 'Recommended') { $why += (L 'm299') }
  if ($keepSet.Contains($pkg)) { $why += (L 'm300') }
  if ($usedPkgs.Contains($pkg)) { $why += (L 'm301') }
  if ($u -and $u.neededby) {
    $nb = @($u.neededby -split ',' | Where-Object { $_ -and $all.Contains($_) -and -not $disabled.Contains($_) })
    if ($nb.Count) { $why += ((L 'm302') + ($nb -join ', ')) }
  }
  $uname = ''; if ($u) { $uname = $u.name }
  $ask = ''
  if (-not $usageOk) { $ask = (L 'm303') }
  elseif ($launchOk -and $launchable.Contains($pkg)) { $ask = (L 'm304') }
  elseif (-not $launchOk) { $ask = (L 'm305') }
  elseif ($rl -eq 'ask') { $ask = (L 'm306') }
  elseif ($rl -ne 'ok' -and $removal -eq 'Advanced') { $ask = (L 'm307') }
  elseif ($rl -ne 'ok' -and ($pkg + ' ' + $uname) -match $AskPattern) { $ask = (L 'm308') }
  elseif ($kids -and $rl -ne 'ok') { $ask = (L 'm309') }
  # Уровень: auto — явный мусор (отмечен), base — база считает безопасным, но пользы мало (не отмечен), ask — спросить
  $tier = 'ask'
  if (-not $ask) { if ($rl -eq 'ok' -or ($pkg + ' ' + $uname) -match $AutoPattern) { $tier = 'auto' } else { $tier = 'base' } }
  $note = $ruNote[$pkg]; if (-not $note) { $note = $uname }
  $cands += [pscustomobject]@{ Pkg = $pkg; Removal = $removal; Note = $note; Mb = (Get-PkgRssMb $pkg); Ask = $ask; Tier = $tier; Skip = ($why -join '; ') }
}
$tierOrder = @{ 'auto' = 0; 'base' = 1; 'ask' = 2 }
$candOk = @($cands | Where-Object { -not $_.Skip } | Sort-Object @{ e = { $tierOrder[$_.Tier] } }, @{ e = { if ($_.Removal -eq 'Recommended') { 0 } else { 1 } } }, @{ e = { $_.Mb }; Descending = $true }, Pkg)
$candSkip = @($cands | Where-Object { $_.Skip })
$bloat3 = @($third | Where-Object { $uad[$_] -and $uad[$_].removal -eq 'Recommended' -and -not $usedPkgs.Contains($_) -and -not $disabled.Contains($_) } | Sort-Object)

# --- безопасность: сторонние приложения
$susp = @()
foreach ($pkg in $third) {
  if ($disabled.Contains($pkg)) { continue }   # уже отключено — значка нет, работать не может
  $strong = @(); $weak = @(); $side = $false
  $inst = [string]$installer[$pkg]
  $preinst = ($inst -eq 'android' -or ((-not $inst -or $inst -eq 'null') -and $uad[$pkg]))   # поставлено производителем
  if ($a11yPkgs -contains $pkg) { $strong += (L 'm310') }
  if ($adminPkgs -contains $pkg) { $strong += (L 'm311') }
  $webapk = ($pkg -like 'org.chromium.webapk.*')
  if (-not $webapk) {
    $store = ($inst -match $StoreInstallers)
    if ($inst -eq 'com.android.shell') { $strong += (L 'm312'); $side = $true }
    elseif ($inst -and $inst -ne 'null' -and -not $store -and -not $preinst) { $strong += (L 'm313' $inst); $side = $true }
    elseif ((-not $inst -or $inst -eq 'null') -and -not $preinst) { $weak += (L 'm314') }
    # Без значка — подозрительно только для поставленного не из магазина и не производителем (у сервисов из Play значка часто нет)
    if ($launchOk -and -not $launchable.Contains($pkg) -and -not $roleSet.Contains($pkg) -and -not $store -and -not $preinst) { $strong += (L 'm315') }
  }
  if ($nlsPkgs -contains $pkg) { $weak += (L 'm316') }
  if ($overlayPkgs -contains $pkg) { $weak += (L 'm317') }
  if ($installPkgs -contains $pkg) { $weak += (L 'm318') }
  $cleaner = ($pkg -match $CleanerPattern)
  if ($cleaner) { $strong += (L 'm319') }
  $lvl = ''
  if ($strong.Count -ge 2 -or ($side -and $weak.Count -ge 1) -or $cleaner) { $lvl = 'warn' }
  elseif ($strong.Count -ge 1 -or ($weak.Count -ge 2 -and $inst -notmatch $StoreInstallers)) { $lvl = 'check' }
  if ($webapk) { $lvl = 'check'; $weak += (L 'm320') }
  if ($lvl) { $susp += [pscustomobject]@{ Pkg = $pkg; Level = $lvl; Why = (($strong + $weak) -join '; '); Used = $usedPkgs.Contains($pkg); Mb = (Get-PkgRssMb $pkg) } }
}
$susp = @($susp | Sort-Object @{ e = { if ($_.Level -eq 'warn') { 0 } else { 1 } } }, Pkg)
$suspOk = @($susp | Where-Object { $_.Level -eq 'warn' -and -not $roleSet.Contains($_.Pkg) })

# --- фон: сторонние, которые больше месяца не открывали, но сейчас работают
$bgCands = @()
if ($usageOk) {
  foreach ($pkg in $third) {
    if ($keepSet.Contains($pkg) -or $usedPkgs.Contains($pkg) -or $disabled.Contains($pkg) -or $pkg -match $KeepBgPattern) { continue }
    if ($suspOk | Where-Object { $_.Pkg -eq $pkg }) { continue }
    if (-not (Test-Running $pkg)) { continue }
    $bgCands += [pscustomobject]@{ Pkg = $pkg; Mb = (Get-PkgRssMb $pkg) }
  }
  $bgCands = @($bgCands | Sort-Object Mb -Descending | Select-Object -First 15)
}

# --- наблюдения
$obs = New-Object System.Collections.ArrayList
$memTotal = $mem['MemTotal']; $memAvail = $mem['MemAvailable']
if ($memTotal) {
  $pct = [math]::Round(100 * $memAvail / $memTotal)
  if ($memAvail -lt 400 * 1024 -or $pct -lt 10) { [void]$obs.Add((L 'm321' $(Mb $memAvail) $(Mb $memTotal) $pct)) }
}
if ($mem['SwapTotal'] -gt 0) { $swUsed = $mem['SwapTotal'] - $mem['SwapFree']; if ($swUsed -gt 0.8 * $mem['SwapTotal']) { [void]$obs.Add((L 'm322' $(Mb $swUsed) $(Mb $mem['SwapTotal']))) } }
if ($uptimeSec -gt 14 * 86400) { [void]$obs.Add((L 'm323' $([math]::Floor($uptimeSec / 86400)))) }
if ($uptimeSec -lt 600) { [void]$obs.Add((L 'm324')) }
if ($dataPct -ge 85) { [void]$obs.Add((L 'm325' $dataPct $(Mb $dataFree))) }
if ($set['low_power'] -eq '1') { [void]$obs.Add((L 'm326')) }
if ($thStatus -gt 0) { [void]$obs.Add((L 'm327' $thStatus)) }
if ($batTemp -ge 40) { [void]$obs.Add((L 'm328' $batTemp)) }
if ($batHealth -and $batHealth -ne '2') { [void]$obs.Add((L 'm329' $healthName)) }
$patch = P 'ro.build.version.security_patch'
if ($patch -match '^\d{4}-\d\d-\d\d$') { $pd = [datetime]::ParseExact($patch, 'yyyy-MM-dd', $null); if ($pd -lt (Get-Date).AddMonths(-12)) { [void]$obs.Add((L 'm330' $patch)) } }
if ($set['finish_act'] -eq '1') { [void]$obs.Add((L 'm331')) }
if ($set['bg_limit'] -and $set['bg_limit'] -notin @('null', '-1', '')) { [void]$obs.Add((L 'm332' $($set['bg_limit']))) }
if ($set['verifier'] -eq '0') { [void]$obs.Add((L 'm333')) }
if ($vb -and $vb -ne 'green') { [void]$obs.Add((L 'm334' $vb)) }
if ($cpuTotal -and [double]$cpuTotal -gt 60) { [void]$obs.Add((L 'm335' $cpuTotal)) }
foreach ($pr in $topProcs) { if ($pr.Kb -gt 400 * 1024 -and $pr.Name -notmatch '^(system_server|com\.android\.systemui)$') { [void]$obs.Add((L 'm336' $($pr.Name) $(Mb $pr.Kb))) } }
foreach ($k in $crashes.Keys) { if ($crashes[$k] -ge 2) { [void]$obs.Add((L 'm337' $k $($crashes[$k]))) } }
if ($oomBitmap) { [void]$obs.Add((L 'm338')) }
if ($dnsBroken) { [void]$obs.Add((L 'm339')) }
if (@($susp | Where-Object { $_.Level -eq 'warn' }).Count) { [void]$obs.Add(((L 'm340') -f (@($susp | Where-Object { $_.Level -eq 'warn' } | ForEach-Object { $_.Pkg }) -join ', '))) }
if ($third.Count -gt 150) { [void]$obs.Add((L 'm341' $($third.Count))) }
if ($kids) { [void]$obs.Add((L 'm342')) }
if ($owner) { [void]$obs.Add((L 'm343' $owner)) }
if ($users.Count -gt 1) { [void]$obs.Add((L 'm344' $($users -join ', '))) }
if ($set['anim_w'] -in @('', 'null', '1', '1.0')) { [void]$obs.Add((L 'm345')) }

# ----------------------------------------------------------------- отчёт

$script:ReportLines = New-Object System.Collections.Generic.List[string]
function W([string]$t = '') { $script:ReportLines.Add($t) }
function Pkg-Name([string]$p) { $n = $ruNote[$p]; if (-not $n -and $uad[$p]) { $n = $uad[$p].name }; if ($n) { return "$p ($n)" } return $p }
if ($Mode -eq 'opt') { W (L 'm346' ${KitVersion}) } else { W (L 'm347' $KitVersion) }
W ((L 'm348') + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
if ($Label) { W ((L 'm349') + $Label) }
W ((L 'm350') + $(if ($script:Serial -match ':\d+$|_adb-tls') { 'Wi-Fi' } else { (L 'm351') }))
W ''
W (L 'm352')
W ((L 'm353') -f $brand, $model, (P 'ro.product.device'), $manu)
W ((L 'm354' $devType))
W ((L 'm355') -f (P 'ro.build.version.release'), $sdk, $patch)
W ((L 'm356') -f $(if ($skin) { $skin } else { (L 'm357') }))
W ((L 'm358') -f (P 'ro.build.display.id'))
W ((L 'm359') -f (P 'ro.build.fingerprint'))
W ((L 'm360') -f $vb, (P 'ro.boot.flash.locked'))
W ((L 'm361') -f (P 'ro.hardware'), (P 'ro.board.platform'), (P 'ro.product.cpu.abilist'))
W ((L 'm362') -f $(if ($hasGms) { (L 'm363') } else { (L 'm364') }))
W ((L 'm365') -f ($users -join ', '))
W ''
W (L 'm366')
W ((L 'm367') -f $batLevel, $batTemp, $healthName, $(if ($batPlug) { (L 'm368' $batPlug) } else { '' }))
if ($batApps.Count) {
  W (L 'b001' $(if ($batSince) { $batSince } else { '?' }))
  foreach ($a in $batApps) { W ("    {0,4}%  {1,7} mAh  {2}" -f $a.Pct, $a.Mah, $a.Pkg) }
}
W ((L 'm369') -f $(if ($set['low_power'] -eq '1') { (L 'm370') } else { (L 'm371') }))
W ((L 'm372') -f $thStatus, $(if ($temps.Count) { '; ' + (($temps.Keys | ForEach-Object { "$_ $($temps[$_]) °C" }) -join ', ') } else { '' }))
if ($cores) { W ((L 'm373') + (($cores | ForEach-Object { "$($_.CurMhz)/$($_.MaxMhz)" }) -join '  ')) }
W ((L 'm374') -f $load, $cpuTotal)
if ($cpuTop) { W (L 'm375'); foreach ($c in $cpuTop) { W ("    {0,5}%  {1}" -f $c.Pct, $c.Name) } }
W ''
W (L 'm376')
W ((L 'm377') -f (Mb $memTotal), (Mb $memAvail))
W ((L 'm378') -f (Mb $mem['SwapTotal']), (Mb $mem['SwapFree']))
W ((L 'm379') -f [math]::Floor($uptimeSec / 86400), [math]::Floor(($uptimeSec % 86400) / 3600))
W ((L 'm380') -f (Mb $dataTotal), (Mb $dataUsed), $dataPct, (Mb $dataFree), $cacheMb)
if ($bigApps) { W (L 'm381'); foreach ($b in $bigApps) { W ((L 'm382') -f $b.Mb, $b.Pkg, $b.CacheMb) } }
if ($storeCat.Count -or $storeDirs.Count) {
  W (L 's020')
  $catKey = @{ 'Photos' = 's021'; 'Videos' = 's022'; 'Audio' = 's023'; 'Downloads' = 's024'; 'App' = 's025'; 'App Data' = 's026'; 'App Cache' = 's027'; 'System' = 's028'; 'Other' = 's029' }
  foreach ($k in $storeCat.Keys) { W ("    {0,-24} {1}" -f (L $catKey[$k]), (Fmt-Mb $storeCat[$k])) }
  foreach ($d in $storeDirs) { W ("    {0,-24} {1}" -f ('/sdcard: ' + $d.Name), (Fmt-Mb $d.Mb)) }
  foreach ($t in $storeTips) { W ('    -> ' + $t) }
}
W (L 'm383')
foreach ($pr in $topProcs) { W ((L 'm384') -f (Mb $pr.Kb), $pr.Name) }
W ''
W (L 'm385')
if ($topUsage) { foreach ($u in $topUsage) { W ((L 'm386') -f (Fmt-Dur $u.Sec), $u.Pkg, $(if ($u.Last -gt [datetime]::MinValue) { $u.Last.ToString('yyyy-MM-dd') } else { '?' })) } }
else { W (L 'm387') }
W ''
W ((L 'm388') -f $all.Count, $sys.Count, $third.Count, $disabled.Count, $preUninst.Count)
W ((L 'm389') + (($third | Sort-Object) -join ', '))
if ($disabled.Count) { W ((L 'm390') + (($disabled | Sort-Object) -join ', ')) }
if ($preUninst.Count) { W ((L 'm391') + (($preUninst | Sort-Object) -join ', ')) }
if ($bloat3.Count) { W ((L 'm392') + (($bloat3 | ForEach-Object { Pkg-Name $_ }) -join ', ')) }
W ''
W (L 'm393')
W ((L 'm394') -f $(if ($set['verifier'] -eq '0') { (L 'm395') } else { (L 'm396') }))
W ((L 'm397') -f $(if ($a11y -and $a11y -ne 'null') { $a11y } else { (L 'm364') }))
W ((L 'm398') -f $(if ($nls -and $nls -ne 'null') { $nls } else { (L 'm364') }))
W ((L 'm399') -f $(if ($adminPkgs.Count) { $adminPkgs -join ', ' } else { (L 'm364') }))
if ($owner) { W "  $owner" }
W ((L 'm400') -f ((@($overlayPkgs | Where-Object { $third.Contains($_) })) -join ', '))
W ((L 'm401') -f ((@($installPkgs | Where-Object { $third.Contains($_) })) -join ', '))
W ((L 'm402') -f $(if ($kids) { (L 'm403') } else { (L 'm364') }))
if ($susp.Count) {
  W (L 'm404')
  foreach ($s in $susp) { W ("    [{0}] {1}{2} — {3}" -f $(if ($s.Level -eq 'warn') { (L 'm405') } else { (L 'm406') }), $s.Pkg, $(if ($s.Used) { (L 'm407') } else { (L 'm408') }), $s.Why) }
  W (L 'm409')
} else { W (L 'm410') }
W ''
W (L 'm411')
foreach ($k in $set.Keys) { W ("  {0}: {1}" -f $setLabel[$k], $set[$k]) }
W ((L 'm412') -f $homeComp)
foreach ($k in $roleShort.Keys) { W ((L 'm413') -f $k, $roleShort[$k]) }
W ((L 'm414') -f $netType)
W ''
W (L 'm415')
if ($obs.Count) { foreach ($o in $obs) { W "  - $o" } } else { W (L 'm416') }
W ''
W (L 'm417')
W (L 'm418')
W (L 'm419')
foreach ($c in $candOk) { W ((L 'm420') -f $c.Pkg, $c.Tier, $c.Removal, $c.Mb, $c.Note, $(if ($c.Ask) { "  [$($c.Ask)]" } else { '' })) }
if ($candSkip) {
  W ''
  W (L 'm421')
  foreach ($c in $candSkip) { W ("  {0,-50} {1}" -f $c.Pkg, $c.Skip) }
}
W ''
W (L 'm422')
if ($bgCands) { foreach ($b in $bgCands) { W ((L 'm423') -f $b.Pkg, $b.Mb) } } else { W (L 'm424') }
if ($script:Notes.Count) { W ''; W (L 'm425'); foreach ($n in $script:Notes) { W "  - $n" } }
W ''
W (L 'm426')

$repTxt = Join-Path $RepDir 'report.txt'
$zip = $RepDir + '.zip'
# Отчёт для клиента: одна страница HTML на языке набора (печатается в PDF), кладётся в папку отчёта и в архив
function Save-ClientReport {
  try {
    $H = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $sb = New-Object System.Text.StringBuilder
    $done = New-Object System.Collections.ArrayList
    if ($script:Journal) {
      $anim = $false; $dnsV = ''
      foreach ($e in $script:Journal) {
        switch ([string]$e.t) {
          'disable' { [void]$done.Add((L 'c020' (Get-PkgLabel ([string]$e.pkg)))) }
          'uninstall' { [void]$done.Add((L 'c020' (Get-PkgLabel ([string]$e.pkg)))) }
          'appops' { [void]$done.Add((L 'c021' (Get-PkgLabel ([string]$e.pkg)))) }
          'setting' { if ([string]$e.key -like '*animation*' -or [string]$e.key -like 'animator*') { $anim = $true } elseif ([string]$e.key -eq 'private_dns_specifier') { $dnsV = [string]$e.new } }
        }
      }
      if ($anim) { [void]$done.Insert(0, (L 'c022')) }
      if ($dnsV) { [void]$done.Insert(0, (L 'c023' $dnsV)) }
    }
    if ($script:CacheFreedMb) { [void]$done.Insert(0, (L 'c024' (Fmt-Mb $script:CacheFreedMb))) }
    $tips = New-Object System.Collections.ArrayList
    foreach ($t in $storeTips) { [void]$tips.Add($t) }
    if ($uptimeSec -gt 7 * 86400 -or $Mode -eq 'opt') { [void]$tips.Add((L 'c030')) }
    if ($dataPct -ge 85) { [void]$tips.Add((L 'c031' $dataPct)) }
    foreach ($a in @($batApps | Select-Object -First 1)) { if ($a.Pct -ge 25) { [void]$tips.Add((L 'c032' (Get-PkgLabel $a.Pkg) $a.Pct)) } }
    [void]$sb.Append('<!doctype html><html lang="' + $script:Lang + '"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>' + (& $H (L 'c010')) + '</title><style>')
    [void]$sb.Append('body{margin:0;background:#F3F5F8;color:#111827;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif}.w{max-width:820px;margin:0 auto;padding:28px 20px}.c{background:#fff;border:1px solid #E2E6EC;border-radius:16px;padding:22px;margin-top:16px}h1{font-size:26px;margin:0}h2{font-size:18px;margin:0 0 10px}.m{color:#4B5563}ul{margin:0;padding-left:20px}li{margin:6px 0}table{border-collapse:collapse;width:100%}td{padding:8px 0;border-bottom:1px solid #F0F2F5}td.n{text-align:right;white-space:nowrap}.up{color:#05603A;font-weight:700}.ok{background:#ECFDF3;border-color:#ABEFC6}.f{font-size:12px;color:#6B7280;margin-top:18px}.b{display:inline-block;margin-top:14px;padding:10px 16px;border-radius:10px;background:#1D4ED8;color:#fff;text-decoration:none;font-weight:600;border:0;cursor:pointer;font-size:15px}@media print{body{background:#fff}.c{border-color:#ccc}.np{display:none}}')
    [void]$sb.Append('</style></head><body><div class="w">')
    [void]$sb.Append('<h1>' + (& $H (L 'c010')) + '</h1><p class="m">' + (& $H ("{0} {1} · {2}" -f $brand, $model, (Get-Date -Format 'yyyy-MM-dd'))) + $(if ($Label) { ' · ' + (& $H (L 'c011' $Label)) } else { '' }) + '</p>')
    if ($done.Count) {
      [void]$sb.Append('<div class="c ok"><h2>' + (& $H (L 'c012')) + '</h2><ul>')
      foreach ($d in $done) { [void]$sb.Append('<li>' + (& $H $d) + '</li>') }
      [void]$sb.Append('</ul></div>')
    } else { [void]$sb.Append('<div class="c"><h2>' + (& $H (L 'c013')) + '</h2><p class="m">' + (& $H (L 'c014')) + '</p></div>') }
    if ($script:SnapBefore -and $script:SnapAfter) {
      $b0 = $script:SnapBefore; $a0 = $script:SnapAfter
      [void]$sb.Append('<div class="c"><h2>' + (& $H $(if ($script:SnapAfterReboot) { (L 'c015') } else { (L 'c016') })) + '</h2><table>')
      foreach ($row in @(@((L 'c003'), (Fmt-Mb $b0.memAvailMb), (Fmt-Mb $a0.memAvailMb), ($a0.memAvailMb -gt $b0.memAvailMb)), @((L 'c004'), $b0.procs, $a0.procs, ($a0.procs -lt $b0.procs)), @((L 'c005'), (Fmt-Mb $b0.dataFreeMb), (Fmt-Mb $a0.dataFreeMb), ($a0.dataFreeMb -gt $b0.dataFreeMb)))) {
        [void]$sb.Append('<tr><td>' + (& $H $row[0]) + '</td><td class="n">' + (& $H $row[1]) + ' → <span class="' + $(if ($row[3]) { 'up' } else { '' }) + '">' + (& $H $row[2]) + '</span></td></tr>')
      }
      [void]$sb.Append('</table></div>')
    }
    [void]$sb.Append('<div class="c"><h2>' + (& $H (L 'c017')) + '</h2><table>')
    [void]$sb.Append('<tr><td>' + (& $H (L 'c005')) + '</td><td class="n">' + (& $H (L 'c018' $dataPct (Fmt-Mb (Mb $dataFree)))) + '</td></tr>')
    [void]$sb.Append('<tr><td>' + (& $H (L 'c019')) + '</td><td class="n">' + (& $H ("{0}% · {1} °C" -f $batLevel, $(if ($script:Lang -eq 'en') { [string]$batTemp } else { ([string]$batTemp).Replace('.', ',') }))) + '</td></tr></table></div>')
    if ($tips.Count) {
      [void]$sb.Append('<div class="c"><h2>' + (& $H (L 'c025')) + '</h2><ul>')
      foreach ($t in $tips) { [void]$sb.Append('<li>' + (& $H $t) + '</li>') }
      [void]$sb.Append('</ul></div>')
    }
    [void]$sb.Append('<div class="c"><p>' + (& $H (L 'c026')) + '</p><button class="b np" onclick="window.print()">' + (& $H (L 'c027')) + '</button></div>')
    [void]$sb.Append('<p class="f">phone-kit ' + $KitVersion + ' · github.com/Meteoric-Potential-Unipessoal-Lda/phone-kit</p></div></body></html>')
    $cf = Join-Path $RepDir 'client_report.html'
    [IO.File]::WriteAllText($cf, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    $script:ClientReport = $cf
    if ($script:WebUi) { $script:WebUi.clientFile = $cf; Emit 'client' @{ file = $cf } }
    Ok (L 'c028' $cf)
  } catch { Warn ((L 'c029') + $_.Exception.Message) }
}

function Save-Report([switch]$NoZip) {
  [IO.File]::WriteAllText($repTxt, ($script:ReportLines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
  if ($NoZip) { return }
  try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $za = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
      $base = (Resolve-Path $RepDir).Path.TrimEnd('\', '/')
      foreach ($f in (Get-ChildItem -Path $RepDir -Recurse -File)) {
        $rel = $f.FullName.Substring($base.Length + 1) -replace '\\', '/'
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $f.FullName, $rel)
      }
    } finally { $za.Dispose() }
  } catch { Warn ((L 'm427') + $_.Exception.Message) }
}
Save-Report -NoZip

# Сводка для страницы
$sumApps = @($topUsage | Select-Object -First 6 | ForEach-Object { [ordered]@{ pkg = $_.Pkg; min = [math]::Round($_.Sec / 60) } })
Emit 'summary' ([ordered]@{
  model = $model; brand = $brand; android = (P 'ro.build.version.release'); skin = $skin; type = $devType
  dataPct = $dataPct; dataFreeMb = (Mb $dataFree); dataTotalMb = (Mb $dataTotal); cacheMb = $cacheMb
  memAvailMb = (Mb $memAvail); memTotalMb = (Mb $memTotal); bat = $batLevel; batTemp = $batTemp
  upDays = [math]::Floor($uptimeSec / 86400); obs = @($obs); apps = $sumApps
  cand = $candOk.Count; candAuto = @($candOk | Where-Object { $_.Tier -eq 'auto' }).Count
  susp = @($susp | Where-Object { $_.Level -eq 'warn' } | ForEach-Object { [ordered]@{ pkg = $_.Pkg; why = $_.Why } })
  storage = [ordered]@{ cat = $storeCat; dirs = @($storeDirs | ForEach-Object { [ordered]@{ name = $_.Name; mb = $_.Mb } }); tips = @($storeTips); apps = @($bigApps | Select-Object -First 5 | ForEach-Object { [ordered]@{ pkg = $_.Pkg; mb = $_.Mb } }) }
  battery = [ordered]@{ since = $batSince; apps = @($batApps | ForEach-Object { [ordered]@{ pkg = $_.Pkg; mah = $_.Mah; pct = $_.Pct } }) }
})
# Краткая сводка на экран
Say ''
Say ("{0} {1} — {2}, Android {3}{4}" -f $brand, $model, $devType, (P 'ro.build.version.release'), $(if ($skin) { ", $skin" } else { '' })) 'White'
Say ((L 'm428') -f (Mb $memAvail), (Mb $memTotal), $dataPct, $batLevel, $batTemp) 'White'
if ($obs.Count) { foreach ($o in $obs) { Warn $o } }
foreach ($s in @($susp | Where-Object { $_.Level -eq 'warn' })) { Bad ((L 'm429' $($s.Pkg) $($s.Why))) }
Say ((L 'm430') -f $candOk.Count, @($candOk | Where-Object { $_.Tier -eq 'auto' }).Count, @($candOk | Where-Object { $_.Tier -eq 'base' }).Count, @($candOk | Where-Object { $_.Tier -eq 'ask' }).Count, $bgCands.Count) 'White'

if ($Mode -eq 'opt') {
  Say ''
  Say (L 'm431') 'Cyan'
  Say (L 'm432') 'Cyan'
  Invoke-Optimization
  if ($script:OptLines.Count) {
    W ''
    W (L 'm433')
    foreach ($t in $script:OptLines) { W "  - $t" }
    if ($script:ChangeLog) { W (L 'm434') }
  }
  if ($script:SnapBefore -and $script:SnapAfter) {
    W ''
    W $(if ($script:SnapAfterReboot) { (L 'c001') } else { (L 'c002') })
    $b0 = $script:SnapBefore; $a0 = $script:SnapAfter
    W ("  {0,-28} {1,10} -> {2}" -f (L 'c003'), (Fmt-Mb $b0.memAvailMb), (Fmt-Mb $a0.memAvailMb))
    W ("  {0,-28} {1,10} -> {2}" -f (L 'c004'), $b0.procs, $a0.procs)
    W ("  {0,-28} {1,10} -> {2}" -f (L 'c005'), (Fmt-Mb $b0.dataFreeMb), (Fmt-Mb $a0.dataFreeMb))
    W ("  {0,-28} {1,10} -> {2}" -f (L 'c006'), $b0.disabled, $a0.disabled)
  }
}
Save-ClientReport
Save-Report

Ok (L 'm435' $zip)
Emit 'report' @{ zip = $zip; txt = $repTxt; mode = $Mode; journal = $(if ($script:Journal) { $script:Journal.Count } else { 0 }) }
Emit 'stage' @{ s = 'done'; mode = $Mode }
Ok (L 'm436' $repTxt)
Say ''
if ($Mode -ne 'opt') { Say (L 'm437') 'Yellow' }
Say (L 'm438') 'Cyan'
Say (L 'm439') 'Cyan'
if ($Mode -eq 'opt' -and $script:Journal -and $script:Journal.Count) {
  Say (L 'm440') 'Cyan'
}
Say (L 'm441') 'Cyan'
Say (L 'm442') 'Cyan'
Say (L 'm443') 'Cyan'
if ($IsWin) {
  try { Start-Process notepad.exe -ArgumentList ('"' + $repTxt + '"') } catch {}
  try { Start-Process explorer.exe -ArgumentList ('/select,"' + $zip + '"') } catch {}
} elseif ($IsMac) {
  try { & open -e $repTxt } catch {}
  try { & open -R $zip } catch {}
}
Finish 0
