#!/bin/bash
# Тесты phone-kit Mobile на обычной Java (без телефона и Android SDK):
#   логика (Engine) на подставных телефонах tests/mock_adb.py, протокол ADB (AdbConn) через tests/mobile/fake_adbd.py,
#   беспроводная отладка Android 11+: SPAKE2 (точки BoringSSL), сопряжение по коду, TLS-порт.
#   CONSCRYPT_JAR=conscrypt-openjdk-uber.jar — настоящий TLS 1.3 с экспортом ключа.
# bash tests/mobile/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
FAIL=0
cd "$ROOT"
python3 dev/gen_mobile_patterns.py --check || FAIL=1
SRC=mobile/src/net/zherdyev/phonekit
JSRC="$SRC/AdbKey.java $SRC/AdbConn.java $SRC/AdbPair.java $SRC/B64.java $SRC/ConscryptTls.java $SRC/Data.java $SRC/Ed25519.java $SRC/Engine.java $SRC/Lang.java $SRC/Pat.java $SRC/Sh.java $SRC/Spake2.java $SRC/Tls.java tests/mobile/Cli.java tests/mobile/CryptoTest.java tests/mobile/PairServer.java tests/mobile/TestTls.java"
if [ -n "${CONSCRYPT_JAR:-}" ]; then
  CP="$WORK/cls:$CONSCRYPT_JAR"
  javac -encoding UTF-8 -cp "$CONSCRYPT_JAR" -d "$WORK/cls" $JSRC || exit 1
else
  # без Conscrypt — заглушка только для компиляции (тесты с настоящим TLS пропускаются)
  mkdir -p "$WORK/stub/org/conscrypt"
  printf 'package org.conscrypt;\npublic final class Conscrypt {\n  public static java.security.Provider newProvider() { throw new UnsupportedOperationException("stub"); }\n  public static byte[] exportKeyingMaterial(javax.net.ssl.SSLSocket s, String l, byte[] c, int n) throws javax.net.ssl.SSLException { throw new UnsupportedOperationException("stub"); }\n}\n' > "$WORK/stub/org/conscrypt/Conscrypt.java"
  CP="$WORK/cls"
  javac -encoding UTF-8 -sourcepath "$WORK/stub" -d "$WORK/cls" $JSRC || exit 1
fi
cli() { local name=$1; shift; java -cp "$CP" net.zherdyev.phonekit.Cli --root "$ROOT" "$@" > "$WORK/$name.log" 2>&1; }
expect() { if grep -qF -- "$2" "$WORK/$1.log"; then echo "PASS $1: $2"; else echo "FAIL $1: нет «$2»"; FAIL=1; fi; }
reject() { if grep -qF -- "$2" "$WORK/$1.log"; then echo "FAIL $1: есть «$2»"; FAIL=1; else echo "PASS $1: нет «$2»"; fi; }
mock() { export MOCK_BRAND=$1 MOCK_STATE="$WORK/$1.json"; rm -f "$MOCK_STATE"; }
clean() { reject $1 'Exception'; reject $1 'не из списка чтения'; reject $1 'не из белого списка'; }
# строки приложения: все ключи x*, без табов в тексте, у каждого есть ru и en
python3 - <<'PY' || FAIL=1
import sys
rows=[l.split('\t') for l in open('mobile/strings.tsv',encoding='utf-8').read().splitlines()]
bad=[r[0] for r in rows[1:] if len(r)!=11 or not r[0].startswith('x') or not r[1] or not r[3]]
print('FAIL strings.tsv: '+', '.join(bad) if bad else 'PASS strings.tsv: %d строк' % (len(rows)-1)); sys.exit(1 if bad else 0)
PY
# все ключи, которые Engine/MainActivity берут из языковых файлов, существуют
python3 - <<'PY' || FAIL=1
import re,json,sys,glob
src=''.join(open(f,encoding='utf-8').read() for f in glob.glob('mobile/src/net/zherdyev/phonekit/*.java'))
keys=set(re.findall(r'L\.t\("([a-z]\d{3})"',src))
have=set(json.load(open('data/lang/ru.json',encoding='utf-8-sig')))|{l.split('\t')[0] for l in open('mobile/strings.tsv',encoding='utf-8')}
miss=sorted(keys-have)
print('FAIL ключи: '+', '.join(miss) if miss else 'PASS ключи: %d найдено' % len(keys)); sys.exit(1 if miss else 0)
PY

# 1. Samsung: диагностика, план, применение партиями и откат по журналу
mock samsung
cli m_sam --mock --mode both --journal "$WORK/sam.tsv"
expect m_sam 'DEVICE SM-A105FN | sdk=30 | One UI'
expect m_sam 'SELF-PROTECTED true in-keep=true'
expect m_sam 'ITEM [x] anim'
expect m_sam 'ITEM [x] disable com.samsung.android.rubin.app | Реклама и сбор данных в прошивке'
expect m_sam 'ITEM [ ] dns dns.adguard-dns.com | Реклама и сбор данных в прошивке'
expect m_sam 'ITEM [ ] third com.hidden.spy.svc | Безопасность'
expect m_sam 'ITEM [x] bg com.oldgame.idle'
expect m_sam 'OBS Реклама и сбор данных в прошивке: работает служб'
expect m_sam 'партия 1:'
expect m_sam 'Реклама в прошивке: отключено служб'
expect m_sam 'APPLIED 14'
expect m_sam 'ROLLED BACK, LEFT 0'
reject m_sam 'ITEM [x] disable com.google.android.gm'
reject m_sam 'disable com.android.systemui'
reject m_sam 'disable com.whatsapp'
reject m_sam 'a101'
reject m_sam 'third ru.sberbankmobile'
reject m_sam 'third com.sec.android.app.kidshome'
reject m_sam 'Детское устройство'
reject m_sam 'third ru.vk.store'
reject m_sam 'third com.samsung.android.app.homestar'
reject m_sam 'third com.housecleaning.asmr.makeover.home'
expect m_sam 'Установлены не из магазина и имеют особые доступы: com.hidden.spy.svc, com.super.cleaner.booster —'
clean m_sam
python3 -c "import json,sys; s=json.load(open('$WORK/samsung.json')); sys.exit(0 if s['disabled']==['com.samsung.android.app.watchmanagerstub'] and not s['uninst'] else 1)" && echo "PASS m_sam: после отката всё как было" || { echo "FAIL m_sam: после отката не как было"; FAIL=1; }

# 2. Xiaomi: прошивка не даёт отключить — убираем для пользователя (pm uninstall -k --user 0), откат возвращает
mock xiaomi
cli m_mi --mock --mode both --kinds anim,disable,bg,dns --journal "$WORK/mi.tsv"
expect m_mi 'HyperOS'
expect m_mi 'ITEM [x] disable com.miui.msa.global | Реклама и сбор данных в прошивке'
expect m_mi 'убран для пользователя com.miui.msa.global'
expect m_mi 'возвращён com.miui.msa.global'
expect m_mi 'ROLLED BACK, LEFT 0'
clean m_mi
python3 -c "import json,sys; s=json.load(open('$WORK/xiaomi.json')); sys.exit(0 if not s['disabled'] and not s['uninst'] else 1)" && echo "PASS m_mi: после отката всё как было" || { echo "FAIL m_mi: остались изменения"; FAIL=1; }

# 3. После партии сломался рабочий стол -> партия откатывается, дальше не идём
mock samsung
MOCK_BREAK=com.facebook.appmanager cli m_break --mock --mode apply --journal "$WORK/break.tsv"
expect m_break 'проблема после партии'
expect m_break 'откатываю партию'
expect m_break 'APPLIED 3'
reject m_break 'партия 2:'

# 4. Realme, большой телефон (300 + 300 пакетов), языки
mock realme; cli m_realme --mock --mode diag; expect m_realme 'DEVICE '; clean m_realme
mock samsung; MOCK_BIG=300 cli m_big --mock --mode diag; expect m_big 'ITEM '; clean m_big
mock samsung; cli m_uk --mock --mode diag --lang uk; expect m_uk 'Вимкнути com.samsung.android.rubin.app'; expect m_uk 'Реклама та збір даних у прошивці'
mock samsung; cli m_en --mock --mode diag --lang en; expect m_en 'Disable com.samsung.android.rubin.app'; expect m_en 'Firmware ads and data collection'
mock samsung; cli m_de --mock --mode diag --lang de; expect m_de 'ITEM '; clean m_de
mock samsung; MOCK_KIDS=1 cli m_kids --mock --mode diag; expect m_kids 'OBS Детское устройство'

# 5. Протокол ADB: новый ключ -> «Разрешить» -> CNXN; ответы многими кусками WRTE
PORT=$((20000 + RANDOM % 20000))
export FAKE_KEYS="$WORK/adb_keys" FAKE_ALLOW=1
mock samsung
python3 tests/mobile/fake_adbd.py $PORT 2> "$WORK/adbd.log" &
ADBD=$!
sleep 1
cli p_new --adb 127.0.0.1:$PORT --key "$WORK/phonekey" --mode both --journal "$WORK/p.tsv"
expect p_new 'ALLOW?'
expect p_new 'CONNECTED device::ro.product.name=fake'
expect p_new 'APPLIED 14'
expect p_new 'ROLLED BACK, LEFT 0'
unset FAKE_ALLOW
kill $ADBD; python3 tests/mobile/fake_adbd.py $PORT 2>> "$WORK/adbd.log" & ADBD=$!; sleep 1
mock samsung
cli p_known --adb 127.0.0.1:$PORT --key "$WORK/phonekey" --mode diag
expect p_known 'CONNECTED'
reject p_known 'ALLOW?'
cli p_deny --adb 127.0.0.1:$PORT --key "$WORK/otherkey" --mode diag
expect p_deny 'NotAllowed'
kill $ADBD
FAKE_TLS=1 python3 tests/mobile/fake_adbd.py $PORT 2>> "$WORK/adbd.log" & ADBD=$!; sleep 1
cli p_tls --adb 127.0.0.1:$PORT --key "$WORK/phonekey" --mode diag
expect p_tls 'TlsRequired'
kill $ADBD
cli p_refused --adb 127.0.0.1:$PORT --key "$WORK/phonekey" --mode diag
expect p_refused 'ConnectException'
grep -q 'bad checksum\|bad magic\|error' "$WORK/adbd.log" && { echo "FAIL adbd: ошибки протокола"; cat "$WORK/adbd.log"; FAIL=1; } || echo "PASS adbd: протокол без ошибок"

# 6. Беспроводная отладка: SPAKE2 как в BoringSSL, сопряжение по коду, TLS-порт
java -cp "$CP" net.zherdyev.phonekit.CryptoTest > "$WORK/crypto.log" 2>&1 || FAIL=1
grep '^FAIL' "$WORK/crypto.log"; echo "PASS crypto: $(grep -c '^PASS' "$WORK/crypto.log") проверок"
P2=$((PORT + 1))
java -cp "$CP" net.zherdyev.phonekit.PairServer $P2 482913 "$WORK/paired_keys" plain 2 > "$WORK/pairsrv.log" 2>&1 &
sleep 1
cli w_pair --pair 127.0.0.1:$P2 --code 482913 --tls plain --key "$WORK/wkey" --dump-cert "$WORK/wcert.pem"
expect w_pair 'PAIRED guid=adb-FAKEUNIT-test'
cli w_bad --pair 127.0.0.1:$P2 --code 000000 --tls plain --key "$WORK/wkey"
expect w_bad 'WrongCode'
sleep 1
grep -q "phone-kit@phone" "$WORK/paired_keys" && echo "PASS w_pair: ключ приложения передан" || { echo "FAIL w_pair: ключа нет"; FAIL=1; }
P3=$((PORT + 2))
mock samsung
FAKE_TLSCA="$WORK/wcert.pem" python3 tests/mobile/fake_adbd.py $P3 2> "$WORK/tlsadbd.log" &
TLSD=$!
sleep 1
cli w_tls --adb 127.0.0.1:$P3 --tls jdk --key "$WORK/wkey" --mode both --journal "$WORK/w.tsv"
expect w_tls 'tls=true'
expect w_tls 'APPLIED 14'
expect w_tls 'ROLLED BACK, LEFT 0'
cli w_notpaired --adb 127.0.0.1:$P3 --tls jdk --key "$WORK/otherkey2" --mode diag
expect w_notpaired 'NotPaired'
cli w_notls --adb 127.0.0.1:$P3 --key "$WORK/wkey" --mode diag
expect w_notls 'TlsRequired'
kill $TLSD 2>/dev/null
if [ -n "${CONSCRYPT_JAR:-}" ]; then
  P4=$((PORT + 3))
  java -cp "$CP" net.zherdyev.phonekit.PairServer $P4 735190 "$WORK/paired_keys2" conscrypt 2 > "$WORK/pairsrv2.log" 2>&1 &
  sleep 2
  cli w_pair_c --pair 127.0.0.1:$P4 --code 735190 --tls conscrypt --key "$WORK/wkey"
  expect w_pair_c 'PAIRED guid=adb-FAKEUNIT-test'
else echo "SKIP TLS Conscrypt (нет CONSCRYPT_JAR)"; fi

if [ $FAIL -ne 0 ]; then echo "=== logs: $WORK"; for f in "$WORK"/*.log; do echo "--- $f"; tail -25 "$f"; done; fi
exit $FAIL
