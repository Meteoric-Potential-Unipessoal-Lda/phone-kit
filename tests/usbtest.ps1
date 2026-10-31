# Проверка пункта U («кабель подключён, а телефона нет») на подставных данных Get-PnpDevice.
# Запуск: pwsh -File tests/usbtest.ps1 (или powershell.exe на Windows). Код выхода 1 — если какой-то случай не совпал.
$ErrorActionPreference = 'Stop'
$src = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '../phonekit.ps1')
$Root = Join-Path $PSScriptRoot '..'; $Lang = 'ru'
$a = $src.IndexOf('$KitLangs = '); $b = $src.IndexOf('function Say(')
Invoke-Expression $src.Substring($a, $b - $a)
$a = $src.IndexOf('function Say('); $b = $src.IndexOf('function Finish(')
Invoke-Expression $src.Substring($a, $b - $a)
$a = $src.IndexOf('$PhoneVids = '); $b = $src.IndexOf('function Show-EnableHelp')
Invoke-Expression $src.Substring($a, $b - $a)
$IsWin = $true
$Root = Join-Path $PSScriptRoot 'no-such-dir'
function Show-OtherAdb { return $false }
function Get-UsbDriver { return $null }
function Start-Process { }
# Перехватываем вывод: Say/Ok/Warn/Bad пишут через Write-Host
$script:Out = New-Object System.Collections.ArrayList
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$args2) [void]$script:Out.Add(($args2 | Where-Object { $_ -isnot [ConsoleColor] -and $_ -notmatch '^-ForegroundColor$' -and $_ -notin [enum]::GetNames([ConsoleColor]) }) -join ' ') }
function D($n, $s, $c, $i) { [pscustomobject]@{ FriendlyName = $n; Status = $s; Class = $c; InstanceId = $i } }
$cases = [ordered]@{
  'none'  = @{ devs = @((D 'USB Mouse' 'OK' 'Mouse' 'USB\VID_046D&PID_C077\x')); expect = 'вообще не видит' }
  'mtp'   = @{ devs = @((D 'Xiaomi 14T Pro' 'OK' 'WPD' 'USB\VID_2717&PID_FF40&MI_00\x')); expect = 'ADB-интерфейса нет' }
  'nodrv' = @{ devs = @((D 'Xiaomi 14T Pro' 'OK' 'WPD' 'USB\VID_2717&PID_FF48&MI_00\x'), (D 'ADB Interface' 'Error' '' 'USB\VID_2717&PID_FF48&MI_01\x')); expect = 'Установить с диска' }
  'ok'    = @{ devs = @((D 'Android Composite ADB Interface' 'OK' 'AndroidUsbDeviceClass' 'USB\VID_2717&PID_FF48&MI_01\x')); expect = 'Драйвер adb стоит' }
  # Реальный случай: Xiaomi 14T Pro на Windows 11 — общий WinUSB, adb телефон не видит; Bluetooth MediaTek не должен попасть в список
  'winusb' = @{ devs = @((D 'MTP USB Device' 'Error' 'WPD' 'USB\VID_2717&PID_FF48&MI_00\x'), (D 'ADB Interface' 'OK' 'USBDevice' 'USB\VID_2717&PID_FF48&MI_01\x'), (D 'RZ616 Bluetooth(R) Adapter' 'OK' 'Bluetooth' 'USB\VID_0E8D&PID_0616\x')); expect = 'общим драйвером Windows'; reject = 'RZ616' }
}
$fail = 0
foreach ($k in $cases.Keys) {
  $script:Out.Clear()
  $global:CurDevs = $cases[$k].devs
  function Get-PnpDevice { param([switch]$PresentOnly) $global:CurDevs }
  Show-UsbCheck
  $txt = $script:Out -join "`n"
  $ok = $txt -match [regex]::Escape($cases[$k].expect)
  if ($cases[$k].reject -and $txt -match [regex]::Escape($cases[$k].reject)) { $ok = $false }
  if ($ok) { [Console]::WriteLine("PASS usb:$k") } else { [Console]::WriteLine("FAIL usb:$k`n$txt"); $fail++ }
}
# Windows 7/8: Get-PnpDevice нет — те же случаи через Win32_PnPEntity
Remove-Item Function:\Get-PnpDevice -ErrorAction SilentlyContinue
function W($n, $err, $cls, $guid, $id) { [pscustomobject]@{ Name = $n; ConfigManagerErrorCode = $err; PNPClass = $cls; ClassGuid = $guid; DeviceID = $id; Service = '' } }
$wcases = [ordered]@{
  'wmi_nodrv' = @{ devs = @((W 'ADB Interface' 28 '' '' 'USB\VID_2717&PID_FF48&MI_01\x'), (W 'USB Mouse' 0 'Mouse' '' 'USB\VID_046D&PID_C077\x')); expect = 'Установить с диска' }
  'wmi_ok'    = @{ devs = @((W 'Android Composite ADB Interface' 0 $null '{3F966BD9-FA04-4ec5-991C-D326973B5128}' 'USB\VID_04E8&PID_6860&MI_01\x')); expect = 'Драйвер adb стоит' }
}
foreach ($k in $wcases.Keys) {
  $script:Out.Clear()
  $global:CurWmi = $wcases[$k].devs
  function Get-WmiObject { param($Class) $global:CurWmi }
  Show-UsbCheck
  $txt = $script:Out -join "`n"
  if ($txt -match [regex]::Escape($wcases[$k].expect)) { [Console]::WriteLine("PASS usb:$k") } else { [Console]::WriteLine("FAIL usb:$k`n$txt"); $fail++ }
}

# Распаковка без Expand-Archive (Windows PowerShell 3.0/4.0): поверх существующих файлов, с подпапками
$a = $src.IndexOf('function Set-Tls'); $b = $src.IndexOf('function Get-PlatformTools(')
Invoke-Expression $src.Substring($a, $b - $a)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pk_zip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'src/platform-tools') | Out-Null
[IO.File]::WriteAllText((Join-Path $tmp 'src/platform-tools/adb.exe'), 'new-adb')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $tmp 'pt.zip'
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $tmp 'src'), $zip)
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'tools/platform-tools') | Out-Null
[IO.File]::WriteAllText((Join-Path $tmp 'tools/platform-tools/adb.exe'), 'old')
Expand-Zip $zip (Join-Path $tmp 'tools')
$got = [IO.File]::ReadAllText((Join-Path $tmp 'tools/platform-tools/adb.exe'))
if ($got -eq 'new-adb') { [Console]::WriteLine('PASS unzip') } else { [Console]::WriteLine("FAIL unzip: $got"); $fail++ }
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

if ($fail) { exit 1 }
