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

  База пакетов (data/uad.tsv) — из Universal Android Debloater Next Generation
  (github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation, GPL-3.0),
  русские пояснения и наши правила — data/ru.tsv.
#>
param(
  [switch]$Prepare,
  [string]$Address = '',
  [string]$Label = '',
  [string]$AdbPath = '',
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$KitVersion = '0.8'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$IsWin = ($env:OS -eq 'Windows_NT')
$IsMac = (-not $IsWin) -and (Test-Path '/System/Library/CoreServices/Finder.app')

# ----------------------------------------------------------------- вывод

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Title([string]$t) { Write-Host ''; Write-Host ('== ' + $t) -ForegroundColor Cyan }
function Ok([string]$t) { Write-Host ('  [ok] ' + $t) -ForegroundColor Green }
function Warn([string]$t) { Write-Host ('  [!] ' + $t) -ForegroundColor Yellow }
function Bad([string]$t) { Write-Host ('  [x] ' + $t) -ForegroundColor Red }

function Finish([int]$code) {
  # Останавливаем свой adb-сервер: иначе adb остаётся в памяти и папку у клиента не удалить.
  if ($script:Adb -and $script:AdbStarted) {
    try { [void](Invoke-Adb @('kill-server') 10) } catch {}
  }
  if (-not $NoPause) { Write-Host ''; [void](Read-Host 'Enter — закрыть окно') }
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
  '^wm (size|density)$'
)
function Test-ReadOnly([string]$cmd) {
  if ($cmd -match '[;&|<>`$\\"*?]') { return $false }
  foreach ($p in $ReadOnlyPatterns) { if ($cmd -cmatch $p) { return $true } }
  return $false
}

function ShOn([string]$serial, [string]$cmd, [int]$TimeoutSec = 40) {
  if (-not (Test-ReadOnly $cmd)) { throw "Команда не из списка чтения, не отправлена: $cmd" }
  $r = Invoke-Adb @('-s', $serial, 'shell', $cmd) $TimeoutSec
  if ($r.TimedOut) { if ($script:Notes) { [void]$script:Notes.Add("Команда не ответила за $TimeoutSec с: $cmd") }; return '' }
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
    Bad "Не найден adb: $AdbPath"; Finish 1
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
    Warn 'В папке tools нет ADB для этой системы — качаю сейчас.'
  }
  Say 'Скачиваю ADB (platform-tools) с сайта Google, ~15 МБ...'
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
    Bad ('Не удалось скачать ADB: ' + $_.Exception.Message)
    Say 'Скачайте вручную: https://developer.android.com/tools/releases/platform-tools'
    Finish 1
  }
  if (Test-Path $local) { Ok 'ADB скачан'; return $local }
  Bad 'ADB скачан, но adb не найден'; Finish 1
}

# Подготовка папки у мастера: ADB для Windows и Mac, PowerShell для Mac (берём из соседнего tv-kit, если он есть)
function Invoke-Prepare {
  Say "Телефон-набор $KitVersion — подготовка папки (у себя, один раз)" 'Cyan'
  $tools = Join-Path $Root 'tools'
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $tv = Join-Path (Split-Path $Root -Parent) 'tv-kit/tools'
  if (Test-Path $tv) {
    Say "Нашёл соседний tv-kit — беру ADB и PowerShell для Mac оттуда: $tv"
    foreach ($n in @('platform-tools', 'platform-tools-darwin.zip', 'pwsh-osx-arm64.tar.gz', 'pwsh-osx-x64.tar.gz', 'pwsh-7.4.6-hashes.sha256')) {
      $src = Join-Path $tv $n
      $dst = Join-Path $tools $n
      if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item -Path $src -Destination $dst -Recurse -Force; Ok "скопировано: $n" }
    }
  }
  $script:Adb = Get-AdbBinary
  $macZip = Join-Path $tools 'platform-tools-darwin.zip'
  if ($IsWin -and -not (Test-Path $macZip)) {
    try { Say 'Скачиваю ADB для Mac...'; Get-PlatformTools 'darwin' $macZip; Ok 'ADB для Mac скачан' } catch { Warn ('ADB для Mac не скачался: ' + $_.Exception.Message) }
  }
  $ud = Join-Path $tools 'usb_driver'
  if ($IsWin -and -not (Test-Path (Join-Path $ud 'android_winusb.inf'))) {
    try {
      Say 'Скачиваю Google USB Driver (для телефонов, которые Windows не видит по кабелю)...'
      $uz = Join-Path $env:TEMP 'usb_driver_r13-windows.zip'
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -UseBasicParsing -Uri 'https://dl.google.com/android/repository/usb_driver_r13-windows.zip' -OutFile $uz
      Expand-Archive -Path $uz -DestinationPath $tools -Force
      Remove-Item $uz -Force -ErrorAction SilentlyContinue
      if (Test-Path (Join-Path $ud 'android_winusb.inf')) { Ok 'Google USB Driver в tools/usb_driver' } else { Warn 'Google USB Driver распакован, но android_winusb.inf не найден' }
    } catch { Warn ('Google USB Driver не скачался: ' + $_.Exception.Message) }
  }
  foreach ($arch in @('arm64', 'x64')) {
    $f = Join-Path $tools "pwsh-osx-$arch.tar.gz"
    if (-not (Test-Path $f)) {
      try {
        Say "Скачиваю PowerShell 7.4.6 для Mac ($arch) с GitHub..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri ("https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-osx-$arch.tar.gz") -OutFile $f
        Ok "PowerShell для Mac ($arch) скачан"
      } catch { Warn ("PowerShell для Mac ($arch) не скачался: " + $_.Exception.Message) }
    }
  }
  $v = Invoke-Adb @('version') 15
  Ok ("ADB: " + $script:Adb)
  Say ('  ' + (($v.Out -split "`n")[0..1] -join ' / '))
  if (Test-Path (Join-Path $Root 'data/uad.tsv')) { Ok 'База пакетов data/uad.tsv на месте' } else { Warn 'Нет data/uad.tsv — без неё набор не предложит, что отключать' }
  Say 'Готово. Папку phone-kit целиком копируйте клиенту через AnyDesk (Windows: start.bat, Mac: start.command).' 'Cyan'
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
    $a = ([string](Read-Host $q)).Trim()
    if ($a -eq '') { return '' }
    $a = ($a -replace ',', '.') -replace '\s+', ''
    if ($a -match '(\d{1,3}(?:\.\d{1,3}){3}):?(\d{2,5})') { $a = $Matches[1] + ':' + $Matches[2] }
    if (Test-Addr $a) { return $a }
    Warn 'Нужно IP и порт через двоеточие, например 192.168.1.50:37123 (не шестизначный код).'
  }
}

function Connect-Addr([string]$target) {
  if ($target -notmatch ':\d+$') { $target = "${target}:5555" }
  Say "  подключаюсь к $target ..."
  $r = Invoke-Adb @('connect', $target) 20
  $txt = ($r.Out + ' ' + $r.Err).Trim()
  if ($txt -match 'connected to|already connected') { return $target }
  Warn "Не подключилось: $txt"
  if (-not $IsWin -and $txt -match 'No route to host|EHOSTUNREACH') { Show-MacLanHelp }
  return $null
}

function Wait-Authorized([string]$serial) {
  $shown = $false
  for ($i = 0; $i -lt 60; $i++) {
    $d = Get-AdbDevices | Where-Object { $_.Serial -eq $serial }
    if ($d -and $d.State -eq 'device') { return $true }
    if (-not $shown) {
      Warn 'Разблокируй телефон: на экране должен появиться запрос «Разрешить отладку по USB?».'
      Warn 'Отметь «Всегда разрешать с этого компьютера» и нажми «Разрешить». Жду до 2 минут...'
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
  Warn 'Работает чужой adb — его запустила другая программа, он перехватывает телефон (отсюда «offline»):'
  foreach ($o in $others) { Say ("    {0}" -f $o.Path) }
  Say '  Обычно это Mi Assistant / Xiaomi PC Suite, Samsung Smart Switch, HiSuite, Android Studio, scrcpy, Vysor. Закрой программу.'
  if (Confirm-Yes 'Остановить чужие adb сейчас? (да / Enter — нет)') {
    foreach ($o in $others) { try { Stop-Process -Id $o.Id -Force; Ok ("остановлен {0}" -f $o.Path) } catch { Warn ('не остановился: ' + $_.Exception.Message) } }
    [void](Invoke-Adb @('kill-server') 15); [void](Invoke-Adb @('start-server') 30)
  }
  return $true
}

function Show-OfflineHelp {
  Say ''
  Warn 'Телефон виден, но «offline» — связь по USB есть, а договориться adb с телефоном не может.'
  [void](Show-OtherAdb)
  Say '  1) Разблокируй телефон и посмотри, нет ли окна «Разрешить отладку по USB?» — нажми «Разрешить» (галочка «Всегда»).'
  Say '  2) Окна нет: «Для разработчиков» -> «Отозвать авторизацию отладки по USB», выключить и включить «Отладку по USB», вынуть и вставить кабель.'
  Say '  3) Не помогло: другой порт (прямо в ноутбуке, лучше USB 2.0) и другой кабель — «offline» часто из-за кабеля или хаба.'
  Say '  Набор продолжает ждать — сделай шаги, он подхватит телефон сам.'
}

function Show-MacLanHelp {
  Say ''
  Say 'macOS не пускает Терминал в локальную сеть (защита «Локальная сеть»).' 'Yellow'
  Say '  Системные настройки -> Конфиденциальность и безопасность -> Локальная сеть -> включить «Терминал»,' 'Yellow'
  Say '  потом полностью закрыть Терминал (Cmd+Q) и запустить набор заново.' 'Yellow'
}


# Проверка кабельного подключения: что видит сама Windows (без драйверов adb не увидит телефон, даже если Windows его видит)
$PhoneVids = 'VID_(2717|04E8|18D1|22B8|12D1|339B|2A70|0BB4|1004|22D9|2D95|1EBF|1BBB|2B4C|19D2|17EF|0FCE|2AE5|29A9|2A45|1F3A|0502)'
function Show-UsbCheck {
  Title 'Проверка кабеля: что видит компьютер'
  if (-not $IsWin) {
    Say '  На Mac драйверы не нужны. Если телефона нет в списке: другой кабель (с передачей данных), порт прямо в Mac без хаба,'
    Say '  на телефоне в шторке «USB» -> «Передача файлов», разблокировать экран и принять «Разрешить отладку по USB?».'
    return
  }
  [void](Show-OtherAdb)
  $devs = @()
  try {
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
      $_.InstanceId -match $PhoneVids -or $_.Class -eq 'AndroidUsbDeviceClass' -or $_.FriendlyName -match 'ADB|Android'
    })
  } catch { Warn ('Не удалось прочитать список устройств Windows: ' + $_.Exception.Message); return }
  if ($devs.Count -eq 0) {
    Warn 'Windows вообще не видит телефон по USB.'
    Say '  Причины: кабель только для зарядки (самая частая), порт/хаб, или на телефоне режим «Только зарядка».'
    Say '  Сделать: родной кабель или другой с передачей данных, порт прямо в ноутбуке; в шторке телефона «USB» -> «Передача файлов».'
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
    Ok 'Драйвер adb стоит (Android ADB Interface).'
    Say '  Значит телефон ждёт разрешения: разблокируй экран и нажми «Разрешить» в окне «Разрешить отладку по USB?» (галочка «Всегда»).'
    Say '  Окна нет: «Для разработчиков» -> «Отозвать авторизацию отладки по USB», вынуть и вставить кабель. Потом R.'
  } elseif ($adbGeneric.Count -or $bad.Count) {
    if ($adbGeneric.Count) { Warn 'ADB Interface есть, но с общим драйвером Windows (WinUSB) — adb такой интерфейс не видит. Нужен драйвер Google.' }
    else { Warn 'Есть устройство телефона без драйвера (в Диспетчере устройств с жёлтым знаком).' }
    Say '  Диспетчер устройств -> «ADB Interface» (раздел «Устройства USB» или «Другие устройства») -> правой кнопкой «Обновить драйвер» ->'
    Say '  «Найти драйверы на этом компьютере» -> «Выбрать драйвер из списка доступных» -> «Установить с диска» -> «Обзор» ->'
    Say '  папка tools\usb_driver набора, файл android_winusb.inf -> «Android ADB Interface» -> Далее -> «Да» на предупреждение.'
    Say '  Потом вынуть и вставить кабель, разблокировать телефон, «Разрешить», и R.'
    if (-not (Test-Path (Join-Path $drv 'android_winusb.inf'))) {
      Warn 'В наборе нет tools\usb_driver. Скачай драйвер: https://dl.google.com/android/repository/usb_driver_r13-windows.zip (распаковать), или запусти prepare.bat у себя.'
      Say '  Без драйвера можно по Wi-Fi (W) — там драйвер не нужен.'
    }
    try { Start-Process devmgmt.msc } catch {}
  } else {
    Warn 'Телефон виден (как накопитель или зарядка), но ADB-интерфейса нет.'
    Say '  На телефоне: шторка -> уведомление USB -> «Передача файлов»;'
    Say '  «Для разработчиков» -> выключить и снова включить «Отладку по USB» (на Xiaomi она иногда сама выключается);'
    Say '  вынуть и вставить кабель, разблокировать экран, принять запрос. Потом R.'
  }
}

function Show-EnableHelp {
  Say ''
  Say 'Как включить отладку на телефоне:' 'White'
  Say '  1. Режим разработчика — 7 раз нажать на номер сборки:'
  Say '     Samsung:  Настройки -> Сведения о телефоне -> Сведения о ПО -> «Номер сборки», ввести PIN'
  Say '     Xiaomi / Redmi / Poco:  Настройки -> О телефоне -> «Версия MIUI» или «Версия ОС» (HyperOS)'
  Say '     Realme / OPPO / OnePlus:  Настройки -> Об устройстве -> Версия -> «Номер сборки»'
  Say '     Honor / Huawei:  Настройки -> О телефоне -> «Номер сборки»'
  Say '     Pixel / Motorola / Nokia и др.:  Настройки -> О телефоне -> «Номер сборки»'
  Say '  2. Включить «Отладка по USB» в «Параметры разработчика» / «Для разработчиков»'
  Say '     (Samsung — в самом низу настроек; Xiaomi — «Расширенные настройки»; Realme/OPPO — «Дополнительные настройки»; Huawei/Honor — «Система»).'
  Say '  3. Samsung One UI 6+: временно выключить «Автоблокировщик» (Безопасность и конфиденциальность), в конце включить обратно.'
  Say '     Huawei/Honor: включить ещё «Разрешить отладку ADB в режиме "Только зарядка"».'
  Say '  КАБЕЛЬ: кабель с передачей данных; в уведомлении USB выбрать «Передача файлов»; разрешить отладку на экране.'
  Say '     Если на Windows телефон не виден (часто Samsung без драйвера) — проще подключить по Wi-Fi (пункт W).'
  Say '  WI-FI (Android 11+): «Беспроводная отладка» -> включить -> «Подключить устройство по коду». Телефон и компьютер в одной сети.'
}

function Get-Model([string]$serial) {
  $m = (ShOn $serial 'getprop ro.product.model' 10).Trim()
  $b = (ShOn $serial 'getprop ro.product.brand' 10).Trim()
  return (($b, $m | Where-Object { $_ }) -join ' ')
}

function Pair-Wifi {
  Say ''
  Say 'На телефоне: Параметры разработчика -> «Беспроводная отладка» -> включить -> «Подключить устройство по коду».' 'White'
  Say 'Окно с кодом НЕ закрывать до конца сопряжения.' 'White'
  $before = @(Get-AdbDevices | ForEach-Object { $_.Serial })
  $pt = ''
  Say '  ищу окно сопряжения в сети (несколько секунд)...'
  $found = @()
  for ($i = 0; $i -lt 3 -and $found.Count -eq 0; $i++) { $found = @(Get-Mdns | Where-Object { $_.Kind -eq 'pairing' }); if (-not $found.Count) { Start-Sleep -Seconds 2 } }
  if ($found.Count -eq 1) { $pt = $found[0].Addr; Ok "нашёл окно сопряжения: $pt" }
  elseif ($found.Count -gt 1) {
    for ($i = 0; $i -lt $found.Count; $i++) { Say ("  {0}) {1}" -f ($i + 1), $found[$i].Addr) 'White' }
    $a = ([string](Read-Host 'Какой адрес совпадает с окном на телефоне (номер)')).Trim()
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $found.Count) { $pt = $found[[int]$a - 1].Addr }
  }
  if (-not $pt) {
    Say '  Автоматически не нашёл (бывает: брандмауэр, Mac «Локальная сеть», разные сети).'
    Say '  Нужен IP:порт из ВСПЛЫВАЮЩЕГО окна с кодом (под шестью цифрами), а не с экрана «Беспроводная отладка» — там порт другой.' 'Yellow'
    $pt = Read-Addr 'IP:порт из окна с кодом (например 192.168.1.50:37123), Enter — отмена'
    if (-not $pt) { return $null }
  }
  do { $code = ([string](Read-Host 'Код из 6 цифр с экрана телефона')).Trim() } until ($code -match '^\d{6}$')
  $r = Invoke-Adb @('pair', $pt, $code) 30
  $txt = ($r.Out + ' ' + $r.Err).Trim()
  if ($txt -notmatch 'Successfully paired') {
    Warn "Сопряжение не прошло: $txt"
    if ($txt -match 'protocol fault|couldn.t read status') {
      Say '  Почти всегда это одно из двух:' 'Yellow'
      Say '   1) введён порт с главного экрана «Беспроводная отладка», а нужен порт из окна с кодом;' 'Yellow'
      Say '   2) окно с кодом уже закрылось (погас экран, переключились на другое приложение, прошло больше минуты).' 'Yellow'
    } elseif ($txt -match 'Wrong password') { Say '  Неверный код — коды одноразовые, у каждого окна свой.' 'Yellow' }
    elseif ($txt -match 'failed to connect|refused|timed out|No route') { Say '  Компьютер не достучался до телефона: разные сети, гостевой Wi-Fi или VPN на телефоне. Проще кабелем.' 'Yellow' }
    Say '  Открой «Подключить устройство по коду» снова (новый код и порт), экран телефона не гасить, и сразу W.'
    Say '  Не выходит со второго раза — подключи кабелем: это надёжнее всего.'
    return $null
  }
  Ok 'Сопряжение прошло'
  $ip = ($pt -split ':')[0]
  Say '  жду подключения (до 15 секунд)...'
  for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep -Seconds 2
    foreach ($d in (Get-AdbDevices)) {
      if ($before -notcontains $d.Serial -and ($d.Serial.StartsWith($ip + ':') -or $d.Serial -match '_adb-tls-connect')) { return $d.Serial }
    }
    foreach ($m in (Get-Mdns | Where-Object { $_.Kind -eq 'connect' -and $_.Addr.StartsWith($ip + ':') })) {
      $s = Connect-Addr $m.Addr; if ($s) { return $s }
    }
  }
  Say '  Сам не подключился. На главном экране «Беспроводной отладки» есть «IP-адрес и порт» (порт другой, чем в окне с кодом).'
  $ct = Read-Addr 'IP:порт с главного экрана «Беспроводной отладки», Enter — отмена'
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
      Ok ("Найден телефон: {0}  ({1})" -f (Get-Model $ready[0].Serial), $ready[0].Serial)
      return $ready[0].Serial
    }
    $first = $false
    Say ''
    if ($devs.Count -eq 0) { Warn 'Телефон не виден. Подключи кабелем (и разреши отладку на экране) или по Wi-Fi — пункт W. Кабель есть, а телефона нет — пункт U.' }
    for ($i = 0; $i -lt $devs.Count; $i++) {
      $d = $devs[$i]
      $lbl = $d.Serial
      if ($d.State -eq 'device') { $lbl = (Get-Model $d.Serial) + "  ($($d.Serial))" }
      elseif ($d.State -eq 'unauthorized') { $lbl += '  (ждёт разрешения на экране телефона)' }
      elseif ($d.State -eq 'offline') { $lbl += '  (offline — выбери номер: набор подождёт и подскажет, что делать)' }
      else { $lbl += "  ($($d.State))" }
      Say ("  {0}) {1}" -f ($i + 1), $lbl) 'White'
    }
    Say '  W) подключить по Wi-Fi кодом (Android 11+, без драйверов)' 'White'
    Say '  I) ввести IP:порт вручную' 'White'
    Say '  H) как включить отладку на телефоне' 'White'
    Say '  U) кабель подключён, а телефона нет — проверить, что видит компьютер' 'White'
    Say '  R) обновить список (после подключения кабеля / разрешения на экране)      Q) выход' 'White'
    $a = ([string](Read-Host 'Ваш выбор')).Trim()
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $devs.Count) { return $devs[[int]$a - 1].Serial }
    elseif ($a -match '^[WwЦц]$') { $s = Pair-Wifi; if ($s) { return $s } }
    elseif ($a -match '^[IiШш]$') {
      $t = Read-Addr 'IP:порт (например 192.168.1.50:41235)'
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
  if ($h -gt 0) { return "$h ч $m мин" } return "$m мин"
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
  $t = [regex]::Replace($t, '(?m)^(\[[^\]]*(serial|imei|meid|iccid|msisdn|cpuid|wifimac|btmac|ethmac|macaddr|phone_number|\.sn)[^\]]*\]: )\[.*\]', '$1[скрыто]')
  $t = [regex]::Replace($t, '\b\d{15}\b', '[скрыто]')
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
  if (-not (Test-WriteAllowed $cmd)) { throw "Команда записи не из белого списка, не отправлена: $cmd" }
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
function Confirm-Yes([string]$q) {
  $a = ([string](Read-Host $q)).Trim().ToLower()
  return ($a -in @('да', 'д', 'lf', 'l', 'y', 'yes'))
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
  if (-not $now.Model) { $p += 'телефон не отвечает' }
  if ($now.HomeBad -and -not $base.HomeBad) { $p += "сломался рабочий стол ($($now.Home))" }
  if ($base.Settings -and -not $now.Settings) { $p += 'не находятся Настройки' }
  if ($base.Ime -and -not $now.Ime) { $p += 'отключилась клавиатура' }
  if ($base.SysUi -and -not $now.SysUi) { $p += 'не работает системный интерфейс (SystemUI)' }
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
  if ($script:keepSet.Contains($pkg)) { OptLog "пропуск $pkg — приложение по умолчанию / спецвозможности / администратор" 'warn'; return $false }
  if (-not $Third) {
    if (Test-Protected $pkg) { OptLog "пропуск $pkg — защищён" 'warn'; return $false }
    if ($script:third.Contains($pkg)) { OptLog "пропуск $pkg — приложение пользователя" 'warn'; return $false }
    if ($script:usedPkgs.Contains($pkg)) { OptLog "пропуск $pkg — им пользовались" 'warn'; return $false }
  }
  $out = ShW "pm disable-user --user 0 $pkg"
  $listed = (Get-DisabledSet).Contains($pkg)
  $said = ($out -match 'new state: disabled')
  # Журналим всегда, когда телефон подтвердил команду: иначе откат не узнает про это изменение
  if ($listed -or $said) { Add-Journal @{ t = 'disable'; pkg = $pkg } }
  if ($listed) { OptLog "отключён $pkg" 'ok'; return $true }
  if ($said) { OptLog "${pkg}: телефон ответил «отключён», но в списке отключённых его нет — записан в журнал" 'warn'; return $true }
  if ($Third) { OptLog "не отключился $pkg ($out) — удалить обычным способом в Настройках" 'warn'; return $false }
  # Прошивка не дала отключить (бывает на Xiaomi/Samsung) — удаляем только для пользователя 0, с сохранением; откат: install-existing
  $out2 = ShW "pm uninstall -k --user 0 $pkg"
  $gone = -not (Get-InstalledSet).Contains($pkg)
  if ($out2 -match 'Success' -or $gone) {
    Add-Journal @{ t = 'uninstall'; pkg = $pkg }
    if ($gone) { OptLog "убран для пользователя $pkg (отключить прошивка не дала; вернуть можно откатом)" 'ok'; return $true }
    OptLog "${pkg}: телефон ответил Success, но пакет ещё в списке — записан в журнал" 'warn'; return $true
  }
  OptLog "не отключился $pkg ($out / $out2) — это нормально, прошивка защищает пакет" 'warn'; return $false
}
function Enable-Pkg([string]$pkg) {
  $out = ShW "pm enable --user 0 $pkg"
  if (-not (Get-DisabledSet).Contains($pkg)) { OptLog "включён обратно $pkg" 'ok'; return $true }
  OptLog "не включился $pkg ($out)" 'bad'; return $false
}
function Restore-Pkg([string]$pkg) {
  $out = ShW "cmd package install-existing --user 0 $pkg"
  if (-not (Get-InstalledSet).Contains($pkg)) { $out += ' / ' + (ShW "pm install-existing --user 0 $pkg") }
  if ((Get-InstalledSet).Contains($pkg)) { OptLog "возвращён $pkg" 'ok'; return $true }
  OptLog "не вернулся $pkg ($out)" 'bad'; return $false
}
function Set-GlobalSetting([string]$key, [string]$val) {
  $old = (Sh "settings get global $key").Trim()
  if ($old -eq $val) { return }
  [void](ShW "settings put global $key $val")
  Add-Journal @{ t = 'setting'; key = $key; old = $old }
}
function Set-Anim([string]$val) {
  foreach ($k in $AnimKeys) { Set-GlobalSetting $k $val }
  OptLog "анимации -> $val" 'ok'
}
function Test-NetBroken {
  $c = Sh 'dumpsys connectivity'
  return ($c -match 'PRIVATE_DNS_BROKEN')
}
function Set-Dns([string]$host_) {
  $start = $script:Journal.Count
  Set-GlobalSetting 'private_dns_specifier' $host_
  Set-GlobalSetting 'private_dns_mode' 'hostname'
  Say '  проверяю, что интернет работает с новым DNS (15 с)...'
  Start-Sleep -Seconds 15
  if (Test-NetBroken) {
    OptLog "частный DNS $host_ не работает в этой сети — возвращаю как было" 'bad'
    Undo-Journal $start
    return $false
  }
  OptLog "частный DNS -> $host_ (реклама и трекеры режутся на уровне DNS)" 'ok'
  return $true
}
function Get-BgMode([string]$pkg) {
  $t = Sh "cmd appops get $pkg RUN_ANY_IN_BACKGROUND"
  if ($t -match 'RUN_ANY_IN_BACKGROUND: (\w+)') { return $Matches[1] }
  return 'default'
}
function Restrict-Bg([string]$pkg) {
  if ($script:keepSet.Contains($pkg)) { OptLog "пропуск $pkg — приложение по умолчанию / спецвозможности" 'warn'; return $false }
  $old = Get-BgMode $pkg
  if ($old -eq 'ignore') { OptLog "${pkg}: фон уже ограничен" 'ok'; return $false }
  [void](ShW "cmd appops set $pkg RUN_ANY_IN_BACKGROUND ignore")
  if ((Get-BgMode $pkg) -eq 'ignore') {
    Add-Journal @{ t = 'appops'; pkg = $pkg; old = $old }
    OptLog "фон запрещён: $pkg" 'ok'; return $true
  }
  OptLog "фон не ограничился: $pkg" 'warn'; return $false
}
function Clear-Caches {
  $f1 = Get-DataFree
  [void](ShW 'pm trim-caches 999G' 300)
  Start-Sleep -Seconds 3
  $f2 = Get-DataFree
  $d = [math]::Max(0, (Mb ($f2 - $f1)))
  OptLog "кэш приложений очищен, освободилось ~$d МБ (свободно стало $(Mb $f2) МБ)" 'ok'
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
      OptLog "настройка $($e.key) -> $(if ($old -and $old -ne 'null') { $old } else { 'по умолчанию' })" 'ok'
    }
    'appops' {
      $old = [string]$e.old
      if ($old -notin @('allow', 'ignore', 'default')) { $old = 'default' }
      [void](ShW "cmd appops set $($e.pkg) RUN_ANY_IN_BACKGROUND $old")
      OptLog "фон снова разрешён: $($e.pkg)" 'ok'
    }
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
  OptLog 'перезагрузка телефона для проверки'
  Say '  Сохраняю изменения перед перезагрузкой (20 секунд)...'
  Start-Sleep -Seconds 20
  $o = ShW 'svc power reboot' 20
  if ($o -match 'Unknown|not found|Error') { [void](ShW 'reboot' 20) }
  Say '  Телефон перезагружается, жду до 5 минут...'
  if ($wifi) { Say '  По Wi-Fi: после загрузки разблокируй телефон и включи «Беспроводную отладку» снова (Xiaomi и многие другие её выключают).' 'Yellow' }
  else { Say '  После загрузки разблокируй телефон (если спросит PIN).' 'Yellow' }
  Start-Sleep -Seconds 30
  $up = $false; $seen = $false; $hinted = $false; $tried = @{}; $ext = 0
  $tries = $(if ($wifi) { 45 } else { 27 })   # по Wi-Fi нужен человек: включить отладку и, возможно, ввести код
  for ($i = 0; $i -lt $tries; $i++) {
    if ($wifi -and -not $seen -and $i -eq $tries - 1) {
      $more = ([string](Read-Host '  Телефон по Wi-Fi ещё не подключился. Подождать ещё? (Enter — ждать дальше, Q — закончить)')).Trim()
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
        Say '  Телефон по Wi-Fi пока не виден — после перезагрузки «Беспроводная отладка» выключилась. Это нормально:' 'Yellow'
        Say '   1) разблокируй телефон -> Параметры разработчика -> снова включи «Беспроводная отладка»;' 'Yellow'
        Say '   2) не подключился за 20 секунд — нажми «Подключить устройство по коду»: набор сам найдёт окно и спросит 6 цифр.' 'Yellow'
        Say '   Удалять компьютер из списка сопряжённых НЕ нужно. Набор ждёт 7 минут, потом спросит, ждать ли ещё.' 'Yellow'
      }
      $pw = @($ms | Where-Object { $_.Kind -eq 'pairing' -and -not $tried.ContainsKey($_.Addr) }) | Select-Object -First 1
      if ($pw) {
        $tried[$pw.Addr] = 1
        Ok "вижу окно сопряжения на телефоне: $($pw.Addr)"
        $code = ([string](Read-Host '  Код из 6 цифр с экрана телефона (Enter — пропустить)')).Trim()
        if ($code -match '^\d{6}$') {
          $r = Invoke-Adb @('pair', $pw.Addr, $code) 30
          $txt = ($r.Out + ' ' + $r.Err).Trim()
          if ($txt -match 'Successfully paired') { Ok 'Сопряжение прошло, подключаюсь...' }
          else { Warn "Сопряжение не прошло: $txt — открой «Подключить устройство по коду» ещё раз (новый код)." }
        }
        continue
      }
    }
    Start-Sleep -Seconds 10
  }
  if (-not $up) {
    if ($seen) {
      OptLog 'телефон виден по ADB, но за 5 минут не догрузился — похоже на зацикливание загрузки' 'bad'
      if (Confirm-Yes 'Попробовать откатить ВСЁ сделанное прямо сейчас? (да / Enter — нет)') { Undo-Journal 0 }
      Say '  Если не поможет: подождать 10 минут, принудительная перезагрузка (питание + громкость вниз 10-15 с), потом снова пункт 3 «Откат». Сброс к заводским НЕ делать.' 'Yellow'
    } else {
      if ($wifi) {
        OptLog 'телефон не вернулся по Wi-Fi за 7 минут. Обычно это нормально: после перезагрузки Xiaomi и многие другие сами выключают «Беспроводную отладку». Если телефон загрузился и работает — изменения сохранены. Проверить: включи «Беспроводную отладку», запусти набор, пункт 1 — отключённое будет в «Уже отключены».' 'warn'
      } else {
        OptLog 'телефон не вернулся в ADB за 5 минут. Проверь экран телефона: если загрузился — включи отладку снова, запусти набор и сделай диагностику (пункт 1) или откат (пункт 3).' 'warn'
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
  if ($back.Count) { OptLog ('прошивка вернула после перезагрузки: ' + ($back -join ', ')) 'warn' }
  else { OptLog 'после перезагрузки всё отключённое осталось отключённым' 'ok' }
  $h = Get-Health
  if ($h.HomeBad) { OptLog "внимание: рабочий стол после перезагрузки: $($h.Home)" 'bad' } else { OptLog ('рабочий стол после перезагрузки: ' + $h.Home) 'ok' }
  if (-not $h.SysUi) { OptLog 'внимание: SystemUI не запущен' 'bad' }
}

function Invoke-Optimization {
  Title 'Оптимизация: план'
  $items = New-Object System.Collections.ArrayList
  function AddItem($kind, $pkg, $text, $on, $group) { [void]$items.Add([pscustomobject]@{ Kind = $kind; Pkg = $pkg; Text = $text; On = [bool]$on; Group = $group }) }

  $animNow = $set['Анимация окон']
  if ($animNow -notin @('0.5', '0.5f', '0', '0.0')) { AddItem 'anim' '' "Анимации интерфейса -> 0.5x (сейчас $(if ($animNow -and $animNow -ne 'null') { $animNow } else { '1x' }))" $true 'Настройки' }
  if ($set['Частный DNS (режим)'] -ne 'hostname') {
    if ($kids) { AddItem 'dns' 'family.adguard-dns.com' 'Частный DNS AdGuard «Семейный»: режет рекламу и взрослые сайты (family.adguard-dns.com) — по желанию родителей' $false 'Настройки' }
    else { AddItem 'dns' 'dns.adguard-dns.com' 'Частный DNS AdGuard: режет рекламу в приложениях и браузере, на сайтах с фильмами — большую часть (dns.adguard-dns.com) — по желанию клиента' $false 'Настройки' }
  }
  $cacheTxt = 'Очистить кэш всех приложений'
  if ($cacheMb -gt 0) { $cacheTxt += " (~$cacheMb МБ)" }
  $cacheTxt += ' — необратимо, но безопасно: данные и вход в приложения не трогает'
  AddItem 'cache' '' $cacheTxt ($dataPct -ge 85) 'Настройки'

  foreach ($s in $suspOk) { AddItem 'third' $s.Pkg ("Отключить подозрительное приложение $($s.Pkg) — $($s.Why)  (спросить владельца; потом удалить обычным способом)") $false 'Безопасность' }

  foreach ($c in $candOk) {
    $txt = "Отключить $($c.Pkg)"
    if ($c.Note) { $txt += " — $($c.Note)" }
    if ($c.Mb -gt 0) { $txt += " [$($c.Mb) МБ]" }
    if ($c.Ask) { $txt += "  ($($c.Ask))" }
    if ($c.Tier -eq 'base') { $txt += '  (база: можно, пользы немного — по желанию; B — отметить все такие)' }
    $grp = @{ 'auto' = 'Лишнее системное: реклама, сбор данных, мусор'; 'base' = 'Лишнее системное: можно, но не обязательно'; 'ask' = 'Функции и приложения: только если владелец не пользуется' }[$c.Tier]
    AddItem 'disable' $c.Pkg $txt ($c.Tier -eq 'auto') $grp
  }
  foreach ($b in $bgCands) { AddItem 'bg' $b.Pkg ("Запретить работу в фоне: $($b.Pkg) — не открывали больше месяца$(if ($b.Mb -gt 0) { ", сейчас занимает $($b.Mb) МБ" })") $true 'Фон' }

  if ($items.Count -eq 0) { OptLog 'Менять нечего.' 'ok'; return }

  while ($true) {
    Say ''
    $g = ''
    for ($i = 0; $i -lt $items.Count; $i++) {
      $it = $items[$i]
      if ($it.Group -ne $g) { $g = $it.Group; Say ("  --- $g ---") 'Cyan' }
      if ($it.On) { Say ("  [x] {0,2}. {1}" -f ($i + 1), $it.Text) 'Green' } else { Say ("  [ ] {0,2}. {1}" -f ($i + 1), $it.Text) 'Gray' }
    }
    Say ''
    Say '[x] — уже выбрано, будет сделано. Чтобы выполнить отмеченное — просто Enter.' 'Green'
    Say '[ ] — не выбрано, но ДОСТУПНО: введи номер, чтобы включить (например, DNS против рекламы).' 'Gray'
    Say 'Номер (через пробел, можно 5-12) ПЕРЕКЛЮЧАЕТ галочку: у отмеченного снимает, у пустого ставит.' 'Cyan'
    Say 'B — отметить все «база: можно»; A — всё; 0 — снять всё; Q — выйти без изменений' 'Cyan'
    $a = ([string](Read-Host 'Ввод (Enter — выполнить отмеченное)')).Trim()
    if ($a -eq '') { break }
    if ($a -match '^[QqЙй]$') { OptLog 'Выход из оптимизации без изменений.'; return }
    if ($a -match '^[AaФф]$') { foreach ($it in $items) { $it.On = $true }; continue }
    if ($a -match '^[BbИи]$') { foreach ($it in $items) { if ($it.Text -like '*(база: можно*') { $it.On = $true } }; continue }
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
    if ($off.Count -gt 0) { Say ("  Галочка СНЯТА (не будет сделано): " + ($off -join ' ')) 'Yellow' }
    if ($onl.Count -gt 0) { Say ("  Галочка ПОСТАВЛЕНА (будет сделано): " + ($onl -join ' ')) 'Green' }
    if ($off.Count -eq 0 -and $onl.Count -eq 0) { Warn 'Не понял ввод. Номера пунктов через пробел, или Enter — выполнить отмеченное.' }
  }
  $sel = @($items | Where-Object { $_.On })
  if ($sel.Count -eq 0) { OptLog 'Ничего не отмечено — ничего не менялось.'; return }
  Say ''
  Say 'Будет сделано:' 'White'
  foreach ($it in $sel) { Say ("  - " + $it.Text) }
  $autoOff = @($items | Where-Object { -not $_.On -and $_.Kind -eq 'disable' -and $_.Group -like 'Лишнее системное: реклама*' })
  if ($autoOff.Count -gt 0) { Warn ("С {0} пунктов «реклама, сбор данных, мусор» галочка снята — они останутся включены: {1}" -f $autoOff.Count, (($autoOff | ForEach-Object { $_.Pkg }) -join ', ')) }
  Say ("Пунктов: {0}. Всё, кроме очистки кэша, обратимо: пункт 3 в меню («Откат»)." -f $sel.Count) 'White'
  if (-not (Confirm-Yes 'Выполнить? Введи «да»')) { OptLog 'Отменено — ничего не менялось.'; return }

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
    before = [ordered]@{ disabled = @($disabled | Sort-Object); uninstalled = @($preUninst | Sort-Object); home = $homeComp; anim = @($set['Анимация окон'], $set['Анимация переходов'], $set['Длительность анимаций']); dns = @($set['Частный DNS (режим)'], $set['Частный DNS (адрес)']) }
    journal = $script:Journal
  }
  Save-State
  OptLog ('снимок «до» и журнал: ' + $script:StateFiles[0]) 'ok'
  $base = Get-Health
  if ($base.HomeBad) { OptLog "внимание: рабочий стол уже до изменений не в порядке ($($base.Home))" 'warn' }

  Title 'Оптимизация: выполняю'
  $stopped = $false
  if ($sel | Where-Object { $_.Kind -eq 'anim' }) { Set-Anim '0.5' }
  $d = $sel | Where-Object { $_.Kind -eq 'dns' } | Select-Object -First 1
  if ($d) { [void](Set-Dns $d.Pkg) }
  if ($sel | Where-Object { $_.Kind -eq 'cache' }) { Clear-Caches }

  $pk = @($sel | Where-Object { $_.Kind -in @('disable', 'third') })
  for ($i = 0; $i -lt $pk.Count; $i += 5) {
    $batch = $pk[$i..([math]::Min($i + 4, $pk.Count - 1))]
    $start = $script:Journal.Count
    foreach ($x in $batch) { [void](Disable-Pkg $x.Pkg -Third:($x.Kind -eq 'third')) }
    $prob = Compare-Health $base (Get-Health)
    if ($prob.Count) {
      OptLog ('проблема после партии: ' + ($prob -join '; ') + ' — откатываю партию и останавливаюсь') 'bad'
      Undo-Journal $start; $stopped = $true; break
    }
    OptLog ("партия {0}: проверка рабочего стола / Настроек / клавиатуры / SystemUI — ок" -f ([math]::Floor($i / 5) + 1)) 'ok'
  }
  if (-not $stopped) {
    foreach ($b in @($sel | Where-Object { $_.Kind -eq 'bg' })) { [void](Restrict-Bg $b.Pkg) }
  }

  Say ''
  if ($script:Journal.Count -eq 0) { OptLog 'Обратимых изменений нет.' 'warn'; return }
  Say 'Проверь телефон (клиент — руками): рабочий стол и жесты, звонок и SMS (если есть SIM), уведомления мессенджеров и банков,' 'Cyan'
  Say '  камера, разблокировка отпечатком/лицом, клавиатура, Wi-Fi/Bluetooth, Google Play, основные приложения клиента.' 'Cyan'
  if (Confirm-Yes 'Что-то сломалось и надо откатить всё сделанное сейчас? (да / Enter — всё ок)') {
    OptLog 'мастер попросил откат' 'warn'
    Undo-Journal 0
    OptLog ('откат выполнен, рабочий стол: ' + (Get-HomeComp)) 'ok'
    return
  }
  if (Confirm-Yes 'Перезагрузить телефон и проверить, что всё загружается и прошивка ничего не вернула? Рекомендую. (да / Enter — нет)') { Invoke-RebootCheck }
  OptLog ("готово, записей в журнале изменений: {0}. Откат — пункт 3 в меню (журнал: backups/{1}.json)" -f $script:Journal.Count, $repName) 'ok'
}

function Invoke-Restore {
  Title 'Откат изменений'
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
    Warn "Для этой модели ($mdl) нет журналов с изменениями."
    Say '  Если оптимизация делалась с другого компьютера: положи state.json из архива отчёта (папка backup) в папку backups и запусти откат снова.'
    return
  }
  $groups = @($found | Group-Object Key | Sort-Object { $_.Group[0].J.created } -Descending)
  for ($i = 0; $i -lt $groups.Count; $i++) {
    $j = $groups[$i].Group[0].J
    $same = if ($j.fingerprint -eq $fp) { 'та же прошивка' } else { 'ДРУГАЯ прошивка' }
    if (-not $groups[$i].Group[0].Same) { $same += ', ДРУГОЙ экземпляр телефона' }
    $when = $j.created; if ($when -is [datetime]) { $when = $when.ToString('yyyy-MM-dd HH:mm') }
    Say ("  {0}) {1}  {2}  записей: {3}  ({4})" -f ($i + 1), $when, $j.label, @($j.journal).Count, $same) 'White'
  }
  $a = ([string](Read-Host 'Какой откатить (номер, Enter — 1, Q — выход)')).Trim()
  if ($a -match '^[QqЙй]$') { return }
  $n = 1; if ($a -match '^\d+$') { $n = [int]$a }
  if ($n -lt 1 -or $n -gt $groups.Count) { Warn 'Нет такого номера.'; return }
  $g = $groups[$n - 1]
  $j = $g.Group[0].J
  Say ''
  Say 'Будет откатано (в обратном порядке):' 'White'
  $entries = @($j.journal)
  for ($i = $entries.Count - 1; $i -ge 0; $i--) {
    $e = $entries[$i]
    switch ([string]$e.t) {
      'disable' { Say "  - включить обратно $($e.pkg)" }
      'uninstall' { Say "  - вернуть $($e.pkg)" }
      'setting' { Say "  - вернуть $($e.key) = $(if ($e.old -and $e.old -ne 'null') { $e.old } else { 'по умолчанию' })" }
      'appops' { Say "  - разрешить фон $($e.pkg)" }
    }
  }
  if (-not (Confirm-Yes 'Откатить? Введи «да»')) { Say 'Отменено.'; return }
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
  Undo-Journal 0
  $h = Get-HomeComp
  if (Test-HomeBad $h) { OptLog "внимание: рабочий стол после отката: $h — проверь на телефоне" 'warn' } else { OptLog "откат завершён, рабочий стол: $h" 'ok' }
  OptLog 'Перезагрузи телефон, чтобы всё вернулось окончательно.'
  [IO.File]::WriteAllText((Join-Path $rd 'restore.txt'), ($script:OptLines -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
  Ok ("Журнал отката: " + $rd)
}

# ----------------------------------------------------------------- старт

$script:Notes = New-Object System.Collections.ArrayList
$script:AdbStarted = $false
$script:RuLevel = @{}

if ($Prepare) { Invoke-Prepare }

Clear-Host
Say "Телефон-набор $KitVersion (Android: Samsung, Xiaomi, Realme, Honor и др.)" 'Cyan'
Say ("Папка: $Root")
$script:Adb = Get-AdbBinary
Ok "ADB: $script:Adb"

# База пакетов и наши пометки
$ruFile = Join-Path $Root 'data/ru.tsv'
$uadFile = Join-Path $Root 'data/uad.tsv'
$ruNote = @{}
if (Test-Path $ruFile) { foreach ($r in (Import-Csv -Path $ruFile -Delimiter "`t" -Encoding UTF8)) { $script:RuLevel[$r.package] = $r.level; $ruNote[$r.package] = $r.note } }

$Mode = 'diag'
while ($true) {
  Say ''
  Say 'Что делаем?' 'White'
  Say '  1) Диагностика (только чтение, ничего не меняет)' 'White'
  Say '  2) Оптимизация: диагностика -> план -> твоё «да» -> изменения партиями с проверкой' 'White'
  Say '  3) Откат изменений, сделанных пунктом 2' 'White'
  Say '  Q) Выход' 'White'
  $m = ([string](Read-Host 'Выбор')).Trim()
  if ($m -eq '1') { $Mode = 'diag'; break }
  if ($m -eq '2') { $Mode = 'opt'; break }
  if ($m -eq '3') { $Mode = 'restore'; break }
  if ($m -match '^[QqЙй]$') { Finish 0 }
}
if (-not $Label -and $Mode -ne 'restore') { $Label = ([string](Read-Host 'Метка клиента для папки отчёта (например: Максим), Enter — без метки')).Trim() }

# Встроенный поиск по сети (mDNS) в adb: на Windows без Bonjour работает только с этим ключом.
# Сервер перезапускаем, чтобы он подхватил ключ (если adb уже был запущен без него).
$env:ADB_MDNS_OPENSCREEN = '1'
[void](Invoke-Adb @('kill-server') 15)
[void](Invoke-Adb @('start-server') 30)
$script:AdbStarted = $true

Title 'Подключение телефона'
$script:Serial = Select-Phone
if (-not (Wait-Authorized $script:Serial)) {
  Bad 'Телефон не разрешил отладку (нет подтверждения на экране).'
  Show-EnableHelp; Finish 1
}
Ok "Подключено: $script:Serial"
if ((Sh 'getprop ro.build.characteristics') -match 'tv') {
  Warn 'Похоже, это телевизор или приставка. Для них есть tv-kit — там другие правила и лаунчер.'
  if (-not (Confirm-Yes 'Всё равно продолжить телефонным набором? (да / Enter — выход)')) { Finish 0 }
}
if ($Mode -eq 'restore') { Invoke-Restore; Finish 0 }
$script:OptLines = New-Object System.Collections.ArrayList

# ----------------------------------------------------------------- сбор

Title 'Собираю сведения (1–2 минуты, телефон можно не трогать)'
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

Step 'память и процессы'
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
  if ($procs.Count -ge 3) { break }
}
Save-Raw 'ps.txt' $psTxt
$topProcs = $procs | Sort-Object Kb -Descending | Select-Object -First 15
function Get-PkgRssMb([string]$pkg) {
  $kb = 0
  foreach ($pr in $procs) { if ($pr.Name -eq $pkg -or $pr.Name.StartsWith($pkg + ':')) { $kb += $pr.Kb } }
  return (Mb $kb)
}
function Test-Running([string]$pkg) { foreach ($pr in $procs) { if ($pr.Name -eq $pkg -or $pr.Name.StartsWith($pkg + ':')) { return $true } }; return $false }

Step 'процессор, батарея, нагрев'
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
$batLevel = ''; $batTemp = 0.0; $batHealth = ''; $batPlug = ''
if ($batTxt -match '(?m)^\s*level: (\d+)') { $batLevel = $Matches[1] }
if ($batTxt -match '(?m)^\s*temperature: (\d+)') { $batTemp = [double]$Matches[1] / 10 }
if ($batTxt -match '(?m)^\s*health: (\d+)') { $batHealth = $Matches[1] }
if ($batTxt -match '(?m)^\s*(AC|USB|Wireless) powered: true') { $batPlug = $Matches[1] }
$healthName = @{ '1' = 'неизвестно'; '2' = 'хорошее'; '3' = 'ПЕРЕГРЕВ'; '4' = 'ИЗНОШЕНА'; '5' = 'перенапряжение'; '6' = 'неисправность'; '7' = 'переохлаждение' }[$batHealth]
$thTxt = Sh 'dumpsys thermalservice'; Save-Raw 'thermal.txt' $thTxt
$thStatus = 0; if ($thTxt -match 'Thermal Status: (\d+)') { $thStatus = [int]$Matches[1] }
$temps = @{}
$curSec = $thTxt
$ci = $thTxt.IndexOf('Current temperatures from HAL'); if ($ci -ge 0) { $curSec = $thTxt.Substring($ci); $cj = $curSec.IndexOf('Current cooling devices'); if ($cj -gt 0) { $curSec = $curSec.Substring(0, $cj) } }
foreach ($m in [regex]::Matches($curSec, 'mValue=([\d.]+), mType=(\d+)')) {
  $tn = @{ '0' = 'CPU'; '1' = 'GPU'; '2' = 'батарея'; '3' = 'корпус' }[$m.Groups[2].Value]
  if ($tn) { $v = [math]::Round([double]$m.Groups[1].Value, 1); if ($v -gt 0 -and $v -lt 150 -and (-not $temps.ContainsKey($tn) -or $temps[$tn] -lt $v)) { $temps[$tn] = $v } }
}

Step 'хранилище'
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

Step 'приложения'
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

Step 'рабочий стол и приложения по умолчанию'
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

Step 'чем пользуются (статистика использования)'
$usageTxt = Sh 'dumpsys usagestats' 120
$usage = Parse-Usage $usageTxt
$usageOk = ($usage.Count -ge 5)
$usedPkgs = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($u in $usage.Values) { if ($u.Sec -ge 60 -or $u.Last -gt (Get-Date).AddDays(-30)) { [void]$usedPkgs.Add($u.Pkg) } }
$topUsage = $usage.Values | Where-Object { $_.Sec -ge 60 } | Sort-Object Sec -Descending | Select-Object -First 20
# В отчёт — только сводка (сам dumpsys usagestats содержит лишние подробности о жизни владельца)
Save-Raw 'usage_summary.txt' (($usage.Values | Sort-Object Sec -Descending | ForEach-Object { "{0}`t{1}`t{2}" -f $_.Pkg, $_.Sec, $(if ($_.Last -gt [datetime]::MinValue) { $_.Last.ToString('yyyy-MM-dd') } else { '' }) }) -join "`n")
if (-not $usageOk) { [void]$script:Notes.Add('Статистика использования недоступна — все пункты отключения помечены «спросить», ограничение фона не предлагается') }

Step 'безопасность: спецвозможности, администраторы, доступы'
$a11y = (Sh 'settings get secure enabled_accessibility_services').Trim()
$nls = (Sh 'settings get secure enabled_notification_listeners').Trim()
function Pkgs-FromComponents([string]$s) { $r = @(); foreach ($x in ($s -split ':')) { if ($x -match '^([A-Za-z0-9_.]+)/') { $r += $Matches[1] } }; return ,$r }
$a11yPkgs = Pkgs-FromComponents $a11y
$nlsPkgs = Pkgs-FromComponents $nls
$dpTxt = Sh 'dumpsys device_policy'
$adminPkgs = @(); foreach ($m in [regex]::Matches($dpTxt, 'ComponentInfo\{([A-Za-z0-9_.]+)/')) { $adminPkgs += $m.Groups[1].Value }
$adminPkgs = @($adminPkgs | Select-Object -Unique)
$owner = ''
if ($dpTxt -match '(?m)Device Owner:\s*\r?\n?.*?admin=ComponentInfo\{([A-Za-z0-9_.]+)/') { $owner = "владелец устройства (организация): $($Matches[1])" }
elseif ($dpTxt -match 'Device Owner') { $owner = 'есть владелец устройства (управляется организацией)' }
Save-Raw 'device_policy_summary.txt' ("admins: " + ($adminPkgs -join ', ') + "`n" + $owner)
function Query-Op([string]$op) {
  $t = Sh "cmd appops query-op --user 0 $op allow"
  $r = @(); foreach ($l in ($t -split "`n")) { if ($l.Trim() -match '^[A-Za-z0-9_.]+$' -and $l.Trim() -match '\.') { $r += $l.Trim() } }
  return ,$r
}
$overlayPkgs = @(); $installPkgs = @()
if ($sdk -ge 29) { $overlayPkgs = Query-Op 'SYSTEM_ALERT_WINDOW'; $installPkgs = Query-Op 'REQUEST_INSTALL_PACKAGES' }

Step 'сеть и настройки'
$connTxt = Sh 'dumpsys connectivity'
$netType = 'не определён'
if ($connTxt -match 'Active default network: (\d+)') {
  $nid = $Matches[1]
  foreach ($l in ($connTxt -split "`n")) {
    if ($l -match "NetworkAgentInfo\{.*?network\{$nid\}" -or $l -match "NetworkAgentInfo \[.*?- $nid\]" -or $l -match "netId[:=] ?$nid\b") {
      if ($l -match 'WIFI') { $netType = 'Wi-Fi'; break }
      if ($l -match 'CELLULAR|MOBILE') { $netType = 'мобильный интернет'; break }
      if ($l -match 'VPN') { $netType = 'VPN'; break }
    }
  }
}
$dnsBroken = ($connTxt -match 'PRIVATE_DNS_BROKEN')
function G([string]$ns, [string]$k) { return (Sh "settings get $ns $k").Trim() }
$set = [ordered]@{
  'Анимация окон'          = (G global window_animation_scale)
  'Анимация переходов'     = (G global transition_animation_scale)
  'Длительность анимаций'  = (G global animator_duration_scale)
  'Энергосбережение'       = (G global low_power)
  'Частный DNS (режим)'    = (G global private_dns_mode)
  'Частный DNS (адрес)'    = (G global private_dns_specifier)
  'Не сохранять действия'  = (G global always_finish_activities)
  'Лимит фоновых процессов' = (G global background_process_limit)
  'Play Защита (проверка приложений)' = (G global package_verifier_enable)
  'Отладка по USB'         = (G global adb_enabled)
  'Беспроводная отладка'   = (G global adb_wifi_enabled)
  'Клавиатура'             = $ime
}
Save-Raw 'settings.txt' ((($set.Keys | ForEach-Object { "$_ = $($set[$_])" }) -join "`n") + "`naccessibility = $a11y`nnotification_listeners = $nls")

Step 'сбои приложений'
$crashTxt = Sh 'logcat -d -b crash -t 400'
Save-Raw 'crash_log.txt' $crashTxt
$crashes = @{}
foreach ($l in ($crashTxt -split "`n")) {
  if ($l -match 'Process: ([A-Za-z0-9_.:]+)') { $k = $Matches[1]; if ($crashes.ContainsKey($k)) { $crashes[$k]++ } else { $crashes[$k] = 1 } }
}
$oomBitmap = ($crashTxt -match 'OutOfMemoryError' -and $crashTxt -match '(?i)bitmap')

# ----------------------------------------------------------------- анализ

Title 'Анализ'
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
$devType = $(if ($isTablet) { 'планшет' } else { 'телефон' }) + $(if ($hasTel) { ', есть SIM-модуль' } else { ', без SIM-модуля' })
$vb = P 'ro.boot.verifiedbootstate'
$hasGms = $all.Contains('com.google.android.gms')

$uad = @{}
if (Test-Path $uadFile) { foreach ($r in (Import-Csv -Path $uadFile -Delimiter "`t" -Encoding UTF8)) { $uad[$r.package] = $r } }
else { [void]$script:Notes.Add('Нет data/uad.tsv — кандидаты на отключение не подобраны') }

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
  if (Test-Protected $pkg) { $why += 'защищён правилами набора' }
  if ($pkg -like 'com.android.*' -and $pkg -ne 'com.android.chrome' -and $removal -ne 'Recommended') { $why += 'системный пакет Android' }
  if ($keepSet.Contains($pkg)) { $why += 'приложение по умолчанию / спецвозможности / уведомления / администратор' }
  if ($usedPkgs.Contains($pkg)) { $why += 'им пользовались' }
  if ($u -and $u.neededby) {
    $nb = @($u.neededby -split ',' | Where-Object { $_ -and $all.Contains($_) -and -not $disabled.Contains($_) })
    if ($nb.Count) { $why += ('нужен для ' + ($nb -join ', ')) }
  }
  $uname = ''; if ($u) { $uname = $u.name }
  $ask = ''
  if (-not $usageOk) { $ask = 'нет статистики использования — спросить' }
  elseif ($launchOk -and $launchable.Contains($pkg)) { $ask = 'это приложение со значком — спросить владельца' }
  elseif (-not $launchOk) { $ask = 'не удалось проверить, приложение ли это — спросить' }
  elseif ($rl -eq 'ask') { $ask = 'спросить владельца' }
  elseif ($rl -ne 'ok' -and $removal -eq 'Advanced') { $ask = 'продвинутый уровень — только по согласию' }
  elseif ($rl -ne 'ok' -and ($pkg + ' ' + $uname) -match $AskPattern) { $ask = 'функция — спросить владельца' }
  elseif ($kids -and $rl -ne 'ok') { $ask = 'детское устройство — спросить родителей' }
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
  if ($a11yPkgs -contains $pkg) { $strong += 'включена служба спецвозможностей (видит экран, нажимает за человека)' }
  if ($adminPkgs -contains $pkg) { $strong += 'администратор устройства' }
  $webapk = ($pkg -like 'org.chromium.webapk.*')
  if (-not $webapk) {
    $store = ($inst -match $StoreInstallers)
    if ($inst -eq 'com.android.shell') { $strong += 'установлено через ADB с компьютера'; $side = $true }
    elseif ($inst -and $inst -ne 'null' -and -not $store -and -not $preinst) { $strong += "установлено не из магазина (через $inst)"; $side = $true }
    elseif ((-not $inst -or $inst -eq 'null') -and -not $preinst) { $weak += 'источник установки неизвестен' }
    # Без значка — подозрительно только для поставленного не из магазина и не производителем (у сервисов из Play значка часто нет)
    if ($launchOk -and -not $launchable.Contains($pkg) -and -not $roleSet.Contains($pkg) -and -not $store -and -not $preinst) { $strong += 'нет значка в меню' }
  }
  if ($nlsPkgs -contains $pkg) { $weak += 'читает уведомления' }
  if ($overlayPkgs -contains $pkg) { $weak += 'показывается поверх других окон' }
  if ($installPkgs -contains $pkg) { $weak += 'может устанавливать другие приложения' }
  $cleaner = ($pkg -match $CleanerPattern)
  if ($cleaner) { $strong += 'чистильщик / ускоритель (обычно реклама, пользы нет)' }
  $lvl = ''
  if ($strong.Count -ge 2 -or ($side -and $weak.Count -ge 1) -or $cleaner) { $lvl = 'ВНИМАНИЕ' }
  elseif ($strong.Count -ge 1 -or ($weak.Count -ge 2 -and $inst -notmatch $StoreInstallers)) { $lvl = 'проверить' }
  if ($webapk) { $lvl = 'проверить'; $weak += 'веб-приложение из Chrome («Установить приложение»)' }
  if ($lvl) { $susp += [pscustomobject]@{ Pkg = $pkg; Level = $lvl; Why = (($strong + $weak) -join '; '); Used = $usedPkgs.Contains($pkg); Mb = (Get-PkgRssMb $pkg) } }
}
$susp = @($susp | Sort-Object @{ e = { if ($_.Level -eq 'ВНИМАНИЕ') { 0 } else { 1 } } }, Pkg)
$suspOk = @($susp | Where-Object { $_.Level -eq 'ВНИМАНИЕ' -and -not $roleSet.Contains($_.Pkg) })

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
  if ($memAvail -lt 400 * 1024 -or $pct -lt 10) { [void]$obs.Add("Мало свободной памяти: $(Mb $memAvail) МБ из $(Mb $memTotal) ($pct%). Главная причина тормозов на слабых телефонах.") }
}
if ($mem['SwapTotal'] -gt 0) { $swUsed = $mem['SwapTotal'] - $mem['SwapFree']; if ($swUsed -gt 0.8 * $mem['SwapTotal']) { [void]$obs.Add("Подкачка почти заполнена: $(Mb $swUsed) из $(Mb $mem['SwapTotal']) МБ.") } }
if ($uptimeSec -gt 14 * 86400) { [void]$obs.Add("Телефон не перезагружался $([math]::Floor($uptimeSec / 86400)) дн. Перезагрузка раз в неделю помогает.") }
if ($uptimeSec -lt 600) { [void]$obs.Add('Телефон включён меньше 10 минут — цифры памяти и процессора могут быть смещены (идёт оптимизация после загрузки).') }
if ($dataPct -ge 85) { [void]$obs.Add("Память телефона заполнена на $dataPct%: свободно $(Mb $dataFree) МБ. При заполнении больше 90% Android сильно тормозит.") }
if ($set['Энергосбережение'] -eq '1') { [void]$obs.Add('Включено энергосбережение — оно режет скорость процессора. Если тормоза важнее батареи — выключить (Настройки -> Батарея).') }
if ($thStatus -gt 0) { [void]$obs.Add("Телефон греется: тепловой статус $thStatus (0 — норма), частоты снижаются.") }
if ($batTemp -ge 40) { [void]$obs.Add("Батарея горячая: $batTemp °C.") }
if ($batHealth -and $batHealth -ne '2') { [void]$obs.Add("Состояние батареи: $healthName.") }
$patch = P 'ro.build.version.security_patch'
if ($patch -match '^\d{4}-\d\d-\d\d$') { $pd = [datetime]::ParseExact($patch, 'yyyy-MM-dd', $null); if ($pd -lt (Get-Date).AddMonths(-12)) { [void]$obs.Add("Патч безопасности старый: $patch. Проверить «Обновление ПО»; если обновлений нет — телефон больше не поддерживается.") } }
if ($set['Не сохранять действия'] -eq '1') { [void]$obs.Add('Включено «Не сохранять действия» (для разработчиков) — приложения перезапускаются при каждом переключении. Выключить вручную.') }
if ($set['Лимит фоновых процессов'] -and $set['Лимит фоновых процессов'] -notin @('null', '-1', '')) { [void]$obs.Add("Задан «Лимит фоновых процессов» = $($set['Лимит фоновых процессов']) — уведомления могут опаздывать. Лучше «Стандартное ограничение».") }
if ($set['Play Защита (проверка приложений)'] -eq '0') { [void]$obs.Add('Play Защита выключена — включить: Google Play -> профиль -> Play Защита.') }
if ($vb -and $vb -ne 'green') { [void]$obs.Add("Загрузчик/прошивка не стоковые (verifiedbootstate=$vb): root или кастомная прошивка — быть особенно осторожным.") }
if ($cpuTotal -and [double]$cpuTotal -gt 60) { [void]$obs.Add("Высокая загрузка процессора в покое: $cpuTotal%.") }
foreach ($pr in $topProcs) { if ($pr.Kb -gt 400 * 1024 -and $pr.Name -notmatch '^(system_server|com\.android\.systemui)$') { [void]$obs.Add("Тяжёлый процесс: $($pr.Name) — $(Mb $pr.Kb) МБ.") } }
foreach ($k in $crashes.Keys) { if ($crashes[$k] -ge 2) { [void]$obs.Add("Приложение падало: $k — $($crashes[$k]) раз(а) в журнале сбоев.") } }
if ($oomBitmap) { [void]$obs.Add('В журнале сбоев «OutOfMemoryError ... Bitmap»: часто виновато веб-приложение из Chrome с огромной иконкой (org.chromium.webapk.*) — удалить его.') }
if ($dnsBroken) { [void]$obs.Add('Частный DNS сейчас не работает (PRIVATE_DNS_BROKEN) — сайты/приложения могут не открываться.') }
if (@($susp | Where-Object { $_.Level -eq 'ВНИМАНИЕ' }).Count) { [void]$obs.Add(("Подозрительные приложения: {0} — см. раздел 6." -f (@($susp | Where-Object { $_.Level -eq 'ВНИМАНИЕ' } | ForEach-Object { $_.Pkg }) -join ', '))) }
if ($third.Count -gt 150) { [void]$obs.Add("Установлено очень много приложений: $($third.Count).") }
if ($kids) { [void]$obs.Add('Детское устройство (Family Link / Samsung Kids): родительский контроль не трогаем, отключения — только по согласию родителей.') }
if ($owner) { [void]$obs.Add("Телефон управляется организацией: $owner. Ничего не менять без согласия администратора.") }
if ($users.Count -gt 1) { [void]$obs.Add("На телефоне несколько пользователей/пространств: $($users -join ', '). Изменения касаются только основного (0).") }
if ($set['Анимация окон'] -in @('', 'null', '1', '1.0')) { [void]$obs.Add('Анимации на стандартной скорости (1x) — можно ускорить до 0.5x.') }

# ----------------------------------------------------------------- отчёт

$script:ReportLines = New-Object System.Collections.Generic.List[string]
function W([string]$t = '') { $script:ReportLines.Add($t) }
function Pkg-Name([string]$p) { $n = $ruNote[$p]; if (-not $n -and $uad[$p]) { $n = $uad[$p].name }; if ($n) { return "$p ($n)" } return $p }
if ($Mode -eq 'opt') { W "ОТЧЁТ ТЕЛЕФОН-НАБОРА ${KitVersion}: диагностика «до» + оптимизация (что сделано — раздел 11)" } else { W "ОТЧЁТ ТЕЛЕФОН-НАБОРА $KitVersion (только диагностика, на телефоне ничего не менялось)" }
W ("Дата: " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
if ($Label) { W ("Клиент: " + $Label) }
W ("Подключение: " + $(if ($script:Serial -match ':\d+$|_adb-tls') { 'Wi-Fi' } else { 'кабель USB' }))
W ''
W '1. УСТРОЙСТВО'
W ("  Марка / модель:   {0} / {1}  (устройство: {2}, производитель: {3})" -f $brand, $model, (P 'ro.product.device'), $manu)
W ("  Тип:              $devType")
W ("  Android:          {0} (SDK {1}), патч безопасности {2}" -f (P 'ro.build.version.release'), $sdk, $patch)
W ("  Оболочка:         {0}" -f $(if ($skin) { $skin } else { 'не определена' }))
W ("  Прошивка:         {0}" -f (P 'ro.build.display.id'))
W ("  Отпечаток:        {0}" -f (P 'ro.build.fingerprint'))
W ("  Загрузчик:        verifiedbootstate={0}, flash.locked={1}" -f $vb, (P 'ro.boot.flash.locked'))
W ("  Платформа:        {0} {1}, ABI: {2}" -f (P 'ro.hardware'), (P 'ro.board.platform'), (P 'ro.product.cpu.abilist'))
W ("  Сервисы Google:   {0}" -f $(if ($hasGms) { 'есть' } else { 'нет' }))
W ("  Пользователи:     {0}" -f ($users -join ', '))
W ''
W '2. БАТАРЕЯ, НАГРЕВ, ПРОЦЕССОР'
W ("  Батарея:          {0}%, {1} °C, состояние: {2}{3}" -f $batLevel, $batTemp, $healthName, $(if ($batPlug) { ", заряжается ($batPlug)" } else { '' }))
W ("  Энергосбережение: {0}" -f $(if ($set['Энергосбережение'] -eq '1') { 'ВКЛЮЧЕНО' } else { 'выключено' }))
W ("  Тепловой статус:  {0} (0 — норма){1}" -f $thStatus, $(if ($temps.Count) { '; ' + (($temps.Keys | ForEach-Object { "$_ $($temps[$_]) °C" }) -join ', ') } else { '' }))
if ($cores) { W ("  Ядра (МГц сейчас/макс): " + (($cores | ForEach-Object { "$($_.CurMhz)/$($_.MaxMhz)" }) -join '  ')) }
W ("  Нагрузка:         loadavg {0}; CPU TOTAL {1}%" -f $load, $cpuTotal)
if ($cpuTop) { W '  Больше всего процессора:'; foreach ($c in $cpuTop) { W ("    {0,5}%  {1}" -f $c.Pct, $c.Name) } }
W ''
W '3. ПАМЯТЬ И ХРАНИЛИЩЕ'
W ("  ОЗУ:              всего {0} МБ, доступно {1} МБ" -f (Mb $memTotal), (Mb $memAvail))
W ("  Подкачка:         всего {0} МБ, свободно {1} МБ" -f (Mb $mem['SwapTotal']), (Mb $mem['SwapFree']))
W ("  Без перезагрузки: {0} дн. {1} ч" -f [math]::Floor($uptimeSec / 86400), [math]::Floor(($uptimeSec % 86400) / 3600))
W ("  Память телефона:  всего {0} МБ, занято {1} МБ ({2}%), свободно {3} МБ; кэш приложений ~{4} МБ" -f (Mb $dataTotal), (Mb $dataUsed), $dataPct, (Mb $dataFree), $cacheMb)
if ($bigApps) { W '  Самые большие приложения (программа + данные + кэш):'; foreach ($b in $bigApps) { W ("    {0,6} МБ  {1}  (кэш {2} МБ)" -f $b.Mb, $b.Pkg, $b.CacheMb) } }
W '  Самые тяжёлые процессы (ОЗУ):'
foreach ($pr in $topProcs) { W ("    {0,6} МБ  {1}" -f (Mb $pr.Kb), $pr.Name) }
W ''
W '4. ЧЕМ ПОЛЬЗУЮТСЯ (по статистике телефона)'
if ($topUsage) { foreach ($u in $topUsage) { W ("  {0,-12} {1}   (последний раз: {2})" -f (Fmt-Dur $u.Sec), $u.Pkg, $(if ($u.Last -gt [datetime]::MinValue) { $u.Last.ToString('yyyy-MM-dd') } else { '?' })) } }
else { W '  Статистика недоступна или пуста.' }
W ''
W ("5. ПРИЛОЖЕНИЯ: всего {0}, системных {1}, установленных пользователем {2}, отключённых {3}, убранных для пользователя {4}" -f $all.Count, $sys.Count, $third.Count, $disabled.Count, $preUninst.Count)
W ('  Установлены пользователем: ' + (($third | Sort-Object) -join ', '))
if ($disabled.Count) { W ('  Уже отключены (до нас — обратно не включаем): ' + (($disabled | Sort-Object) -join ', ')) }
if ($preUninst.Count) { W ('  Уже убраны для пользователя (до нас): ' + (($preUninst | Sort-Object) -join ', ')) }
if ($bloat3.Count) { W ('  Предустановленные, которыми не пользуются (если не нужны — удалить обычным способом в Настройках): ' + (($bloat3 | ForEach-Object { Pkg-Name $_ }) -join ', ')) }
W ''
W '6. БЕЗОПАСНОСТЬ'
W ("  Play Защита: {0}" -f $(if ($set['Play Защита (проверка приложений)'] -eq '0') { 'ВЫКЛЮЧЕНА' } else { 'включена' }))
W ("  Спецвозможности: {0}" -f $(if ($a11y -and $a11y -ne 'null') { $a11y } else { 'нет' }))
W ("  Доступ к уведомлениям: {0}" -f $(if ($nls -and $nls -ne 'null') { $nls } else { 'нет' }))
W ("  Администраторы устройства: {0}" -f $(if ($adminPkgs.Count) { $adminPkgs -join ', ' } else { 'нет' }))
if ($owner) { W "  $owner" }
W ("  Поверх других окон (сторонние): {0}" -f ((@($overlayPkgs | Where-Object { $third.Contains($_) })) -join ', '))
W ("  Могут ставить приложения (сторонние): {0}" -f ((@($installPkgs | Where-Object { $third.Contains($_) })) -join ', '))
W ("  Детский режим / Family Link: {0}" -f $(if ($kids) { 'да' } else { 'нет' }))
if ($susp.Count) {
  W '  Сторонние приложения, на которые стоит посмотреть:'
  foreach ($s in $susp) { W ("    [{0}] {1}{2} — {3}" -f $s.Level, $s.Pkg, $(if ($s.Used) { ' (пользуются)' } else { ' (не пользуются)' }), $s.Why) }
  W '    ВНИМАНИЕ — показать владельцу и, если он не знает, что это, удалить обычным способом (или отключить из плана).'
} else { W '  Подозрительных сторонних приложений не найдено.' }
W ''
W '7. НАСТРОЙКИ И ПРИЛОЖЕНИЯ ПО УМОЛЧАНИЮ'
foreach ($k in $set.Keys) { W ("  {0}: {1}" -f $k, $set[$k]) }
W ("  Рабочий стол (HOME): {0}" -f $homeComp)
foreach ($k in $roleShort.Keys) { W ("  Роль {0}: {1}" -f $k, $roleShort[$k]) }
W ("  Сеть: {0}" -f $netType)
W ''
W '8. НАБЛЮДЕНИЯ'
if ($obs.Count) { foreach ($o in $obs) { W "  - $o" } } else { W '  Явных проблем не видно.' }
W ''
W '9. КАНДИДАТЫ НА ОТКЛЮЧЕНИЕ (база UAD-ng + наши правила; ничего не отключалось)'
W '   Уровень: Recommended — безопасно почти всем, Advanced — по согласию. «спросить» — по умолчанию не отмечено.'
W '   Колонка: auto — явный мусор (в плане отмечен), base — база считает безопасным (не отмечен), ask — спросить владельца.'
foreach ($c in $candOk) { W ("  {0,-50} {1,-4} {2,-11} {3,4} МБ  {4}{5}" -f $c.Pkg, $c.Tier, $c.Removal, $c.Mb, $c.Note, $(if ($c.Ask) { "  [$($c.Ask)]" } else { '' })) }
if ($candSkip) {
  W ''
  W '   Есть в базе, но здесь НЕ трогать:'
  foreach ($c in $candSkip) { W ("  {0,-50} {1}" -f $c.Pkg, $c.Skip) }
}
W ''
W '10. ФОН: сторонние приложения, которые больше месяца не открывали, но они работают'
if ($bgCands) { foreach ($b in $bgCands) { W ("  {0,-50} {1} МБ" -f $b.Pkg, $b.Mb) } } else { W '  Нет.' }
if ($script:Notes.Count) { W ''; W 'ЗАМЕТКИ СКРИПТА'; foreach ($n in $script:Notes) { W "  - $n" } }
W ''
W 'Папка raw — исходные данные для разбора. MAC-адреса, серийные номера и IMEI скрыты; статистика использования — только сводка.'

$repTxt = Join-Path $RepDir 'report.txt'
$zip = $RepDir + '.zip'
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
  } catch { Warn ('Архив не создан: ' + $_.Exception.Message) }
}
if ($Mode -eq 'opt') { Save-Report -NoZip } else { Save-Report }

# Краткая сводка на экран
Say ''
Say ("{0} {1} — {2}, Android {3}{4}" -f $brand, $model, $devType, (P 'ro.build.version.release'), $(if ($skin) { ", $skin" } else { '' })) 'White'
Say ("ОЗУ: доступно {0} из {1} МБ; память телефона занята на {2}%; батарея {3}%, {4} °C" -f (Mb $memAvail), (Mb $memTotal), $dataPct, $batLevel, $batTemp) 'White'
if ($obs.Count) { foreach ($o in $obs) { Warn $o } }
foreach ($s in @($susp | Where-Object { $_.Level -eq 'ВНИМАНИЕ' })) { Bad ("подозрительное: $($s.Pkg) — $($s.Why)") }
Say ("Кандидатов на отключение: {0} (явный мусор, отмечается сам: {1}; можно по желанию: {2}; спросить владельца: {3}); фон: {4}" -f $candOk.Count, @($candOk | Where-Object { $_.Tier -eq 'auto' }).Count, @($candOk | Where-Object { $_.Tier -eq 'base' }).Count, @($candOk | Where-Object { $_.Tier -eq 'ask' }).Count, $bgCands.Count) 'White'

if ($Mode -eq 'opt') {
  Say ''
  Say '================ ДИАГНОСТИКА ГОТОВА — ДАЛЬШЕ ПЛАН ОПТИМИЗАЦИИ ================' 'Cyan'
  Say '  Архив отчёта появится только в самом конце — после плана и проверки.' 'Cyan'
  Invoke-Optimization
  if ($script:OptLines.Count) {
    W ''
    W '11. ОПТИМИЗАЦИЯ'
    foreach ($t in $script:OptLines) { W "  - $t" }
    if ($script:ChangeLog) { W '  Все команды записи с ответами телефона — changes.log; журнал для отката — backup/state.json' }
  }
  Save-Report
}

Ok "Архив: $zip"
Ok "Отчёт: $repTxt"
Say ''
if ($Mode -ne 'opt') { Say 'Это была только ДИАГНОСТИКА — на телефоне ничего не отключено. Чтобы отключить — запусти снова и выбери 2 «Оптимизация».' 'Yellow' }
Say 'Дальше:' 'Cyan'
Say '  - Перетащи архив .zip к себе через AnyDesk (на свой ПК в C:\cleanmytv\reports) — Claude его разберёт.' 'Cyan'
if ($Mode -eq 'opt' -and $script:Journal -and $script:Journal.Count) {
  Say '  - Журнал для отката лежит в архиве (backup/state.json) и в папке backups набора — забери папку backups к себе.' 'Cyan'
}
Say '  - На телефоне: выключить «Отладку по USB» / «Беспроводную отладку» (в Параметрах разработчика);' 'Cyan'
Say '    Samsung — включить обратно «Автоблокировщик», если выключали.' 'Cyan'
Say '  - Закончил у клиента: закрой окно (adb остановится) и удали папку phone-kit с его компьютера.' 'Cyan'
if ($IsWin) {
  try { Start-Process notepad.exe -ArgumentList ('"' + $repTxt + '"') } catch {}
  try { Start-Process explorer.exe -ArgumentList ('/select,"' + $zip + '"') } catch {}
} elseif ($IsMac) {
  try { & open -e $repTxt } catch {}
  try { & open -R $zip } catch {}
}
Finish 0
