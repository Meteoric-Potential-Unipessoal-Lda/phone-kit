#!/bin/bash
# Сборка phone-kit Mobile без Gradle: aapt2 (ресурсы + манифест + assets) + javac + d8 + zipalign + apksigner из Android SDK.
# bash mobile/build.sh [выход.apk]
# В APK кладутся база и тексты набора: data/uad.tsv, ru.tsv, ads.tsv, data/notes, data/lang (10 языков) и mobile/strings.tsv.
# TLS 1.3 для беспроводной отладки — Conscrypt (Apache 2.0, BoringSSL внутри): org.conscrypt:conscrypt-android
# с Maven Central (классы + библиотеки для armeabi-v7a, arm64-v8a, x86, x86_64), сверяется по SHA-1 с Maven.
# Подпись: PHONEKIT_KEYSTORE (путь к .p12) + PHONEKIT_KS_PASS (alias phonekit); без них — временный тестовый ключ
# (тогда следующую бету придётся ставить заново, удалив прошлую).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="${1:-$HERE/build/phone-kit-mobile.apk}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] || { echo "ANDROID_HOME is not set"; exit 1; }
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
PLAT="$(ls -d "$SDK"/platforms/android-* | grep -E '/android-[0-9]+$' | sort -V | tail -1)"
JAR="$PLAT/android.jar"
VCODE="${MOBILE_VERSION_CODE:-1}"
VNAME="${MOBILE_VERSION_NAME:-0.1-beta}"
echo "build-tools: $BT"; echo "platform: $PLAT"
python3 "$ROOT/dev/gen_mobile_patterns.py" --check
grep -q "VERSION = \"$VNAME\"" "$HERE/src/net/zherdyev/phonekit/Engine.java" || { echo "Engine.VERSION != $VNAME"; exit 1; }
W="$HERE/build"; rm -rf "$W/obj" "$W/dex" "$W/assets" "$W/res.zip" "$W/libroot" "$W/gen"; mkdir -p "$W/obj" "$W/dex" "$W/assets/lang" "$W/assets/notes" "$W/libroot" "$W/gen"
CV="${CONSCRYPT_VERSION:-2.5.2}"
AAR="$W/conscrypt-android-$CV.aar"
MVN="https://repo1.maven.org/maven2/org/conscrypt/conscrypt-android/$CV/conscrypt-android-$CV.aar"
if [ ! -s "$AAR" ]; then curl -fsSL -o "$AAR.tmp" "$MVN"; mv "$AAR.tmp" "$AAR"; fi
WANT="$(curl -fsSL "$MVN.sha1" | cut -c1-40)"
GOT="$(sha1sum "$AAR" | cut -c1-40)"
[ "$WANT" = "$GOT" ] || { echo "conscrypt-android: SHA-1 mismatch ($GOT != $WANT)"; rm -f "$AAR"; exit 1; }
echo "conscrypt-android $CV sha256 $(sha256sum "$AAR" | cut -c1-64)"
rm -rf "$W/conscrypt"; mkdir -p "$W/conscrypt"
(cd "$W/conscrypt" && unzip -q -o "$AAR" classes.jar 'jni/*')
mkdir -p "$W/libroot/lib"; cp -r "$W/conscrypt/jni/." "$W/libroot/lib/"
find "$W/libroot/lib" -type f
cp "$ROOT"/data/uad.tsv "$ROOT"/data/ru.tsv "$ROOT"/data/ads.tsv "$W/assets/"
cp "$ROOT"/data/notes/*.tsv "$W/assets/notes/"
cp "$ROOT"/data/lang/*.json "$W/assets/lang/"
cp "$HERE/strings.tsv" "$W/assets/"
cp "$HERE/THIRD_PARTY_NOTICES.txt" "$W/assets/"
"$BT/aapt2" compile --dir "$HERE/res" -o "$W/res.zip"
"$BT/aapt2" link -o "$W/base.apk" -I "$JAR" --manifest "$HERE/AndroidManifest.xml" "$W/res.zip" -A "$W/assets" --java "$W/gen" \
  --min-sdk-version 21 --target-sdk-version 33 --version-code "$VCODE" --version-name "$VNAME"
javac -encoding UTF-8 -source 8 -target 8 -bootclasspath "$JAR" -classpath "$JAR:$W/conscrypt/classes.jar" -d "$W/obj" -Xlint:-options $(find "$HERE/src" "$W/gen" -name '*.java')
"$BT/d8" --min-api 21 --release --lib "$JAR" --output "$W/dex" $(find "$W/obj" -name '*.class') "$W/conscrypt/classes.jar"
cp "$W/base.apk" "$W/unsigned.apk"
(cd "$W/dex" && zip -q -X "$W/unsigned.apk" classes*.dex)
(cd "$W/libroot" && zip -q -X -r "$W/unsigned.apk" lib)
"$BT/zipalign" -f -p 4 "$W/unsigned.apk" "$W/aligned.apk"
KS="${PHONEKIT_KEYSTORE:-}"; PASS="${PHONEKIT_KS_PASS:-}"
if [ -z "$KS" ] || [ ! -s "$KS" ]; then
  echo "WARNING: no PHONEKIT_KEYSTORE — signing with a throwaway test key"
  KS="$W/test.p12"; PASS="testtest"
  [ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storetype PKCS12 -storepass "$PASS" -keypass "$PASS" -alias phonekit \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=phone-kit test" >/dev/null 2>&1
fi
mkdir -p "$(dirname "$OUT")"
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$PASS" --ks-key-alias phonekit --out "$OUT" "$W/aligned.apk"
"$BT/apksigner" verify --print-certs "$OUT" | grep -E 'SHA-256 digest|Signer #1 certificate DN' || true
"$BT/aapt2" dump badging "$OUT" | head -3
ls -la "$OUT"
