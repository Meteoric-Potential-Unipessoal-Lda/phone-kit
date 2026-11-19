#!/bin/bash
# phone-kit Mobile на настоящем Android (эмулятор в CI): установка APK, запуск, нет ли падения, снимок экрана.
# bash tests/mobile/emu.sh папка_для_результатов [путь.apk] (по умолчанию out/phone-kit-mobile-*.apk)
set -u
OUT="${1:-out/emu}"; APK="${2:-$(ls out/phone-kit-mobile-*.apk | head -1)}"; mkdir -p "$OUT"
P=net.zherdyev.phonekit
adb wait-for-device
echo "Android $(adb shell getprop ro.build.version.release | tr -d '\r') (SDK $(adb shell getprop ro.build.version.sdk | tr -d '\r'))"
adb install -r "$APK" 2>&1 | tee "$OUT/install.txt"
grep -q Success "$OUT/install.txt" || { echo "FAIL install"; exit 1; }
adb shell dumpsys package $P | grep -E 'versionName|targetSdk|signatures|pkgFlags' | head -8
adb logcat -c
adb shell am start -W -n $P/.MainActivity
sleep 8
adb exec-out screencap -p > "$OUT/screen.png"
adb logcat -d -b crash > "$OUT/crash.txt"
adb logcat -d -s PHONEKIT AndroidRuntime > "$OUT/logcat.txt"
if [ -z "$(adb shell pidof $P | tr -d '\r')" ] || grep -q "$P" "$OUT/crash.txt"; then echo "FAIL: приложение упало"; cat "$OUT/crash.txt"; exit 1; fi
echo "OK: установлено и работает"
