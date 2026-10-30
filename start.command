#!/bin/bash
# Телефон-набор — запуск на Mac.
# Двойной клик по start.command, или в Терминале:  bash ~/Desktop/phone-kit/start.command
cd "$(dirname "$0")" || exit 1
KIT="$(pwd)"

# Файлы, пришедшие через AnyDesk/интернет, macOS помечает карантином — снимаем только с этой папки
xattr -dr com.apple.quarantine "$KIT" 2>/dev/null

ARCH="$(uname -m)"   # arm64 = M1/M2/M3/M4, x86_64 = Intel
if [ "$ARCH" = "arm64" ]; then PW_NAME="pwsh-osx-arm64"; else PW_NAME="pwsh-osx-x64"; fi
PW_DIR="tools/$PW_NAME"; PW_TGZ="tools/$PW_NAME.tar.gz"
PWSH=""
if [ -x "$PW_DIR/pwsh" ]; then
  PWSH="$PW_DIR/pwsh"
elif [ -f "$PW_TGZ" ]; then
  echo "Распаковываю PowerShell (только в первый раз)..."
  mkdir -p "$PW_DIR" && tar -xzf "$PW_TGZ" -C "$PW_DIR" && chmod +x "$PW_DIR/pwsh" && PWSH="$PW_DIR/pwsh"
elif command -v pwsh >/dev/null 2>&1; then
  PWSH="$(command -v pwsh)"
fi
if [ -z "$PWSH" ]; then
  echo "В папке tools нет PowerShell для этого Mac ($ARCH): нужен $PW_TGZ"
  read -r -p "Enter — закрыть" _; exit 1
fi

# ADB для Mac: распаковать из zip (системный unzip сохраняет права на запуск)
if [ ! -f tools/platform-tools-mac/platform-tools/adb ] && [ -f tools/platform-tools-darwin.zip ]; then
  mkdir -p tools/platform-tools-mac && unzip -q -o tools/platform-tools-darwin.zip -d tools/platform-tools-mac
fi
[ -f tools/platform-tools-mac/platform-tools/adb ] && chmod +x tools/platform-tools-mac/platform-tools/adb

export POWERSHELL_TELEMETRY_OPTOUT=1
export POWERSHELL_UPDATECHECK=Off
"$PWSH" -NoProfile -File "$KIT/phonekit.ps1" "$@"
code=$?
if [ $code -ne 0 ]; then read -r -p "Ошибка (код $code). Enter — закрыть" _; fi
exit $code
