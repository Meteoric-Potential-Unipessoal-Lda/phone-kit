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
if ($fail) { exit 1 }
