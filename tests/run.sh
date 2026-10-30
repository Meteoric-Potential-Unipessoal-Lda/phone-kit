#!/bin/bash
# Сценарные тесты phone-kit на подставном adb (tests/mock_adb.py) в PowerShell 7 (pwsh).
# Запуск из корня репозитория: bash tests/run.sh   Код выхода 1 — если какой-то сценарий не прошёл.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
ADB="$ROOT/tests/mock_adb.py"
chmod +x "$ADB"
FAIL=0

# run NAME BRAND INPUT [keep] -> вывод в $WORK/NAME.log
run() {
  local name=$1 brand=$2 input=$3 keep=${4:-}
  local kit="$WORK/kit-$brand"   # один набор на марку: откат находит журнал предыдущего прогона
  mkdir -p "$kit/data"
  cp "$ROOT/phonekit.ps1" "$kit/"; cp "$ROOT"/data/*.tsv "$kit/data/"; mkdir -p "$kit/data/lang"; cp "$ROOT"/data/lang/*.json "$kit/data/lang/"
  export MOCK_BRAND=$brand MOCK_STATE="$WORK/$brand.json"
  [ -z "$keep" ] && rm -f "$MOCK_STATE"
  printf "$input" | timeout 600 pwsh -NoProfile -File "$kit/phonekit.ps1" -AdbPath "$ADB" -Lang ru -NoUpdateCheck -NoPause > "$WORK/$name.log" 2>&1
}
# expect NAME "текст" — текст должен быть в выводе; reject NAME "текст" — не должен
expect() { if grep -qF -- "$2" "$WORK/$1.log"; then echo "PASS $1: $2"; else echo "FAIL $1: нет «$2»"; FAIL=1; fi; }
reject() { if grep -qF -- "$2" "$WORK/$1.log"; then echo "FAIL $1: есть «$2»"; FAIL=1; else echo "PASS $1: нет «$2»"; fi; }
state() { if grep -qF -- "$2" "$WORK/$1.json"; then echo "PASS state $1: $2"; else echo "FAIL state $1: нет $2"; cat "$WORK/$1.json"; FAIL=1; fi; }
nostate() { if grep -qF -- "$2" "$WORK/$1.json"; then echo "FAIL state $1: есть $2"; cat "$WORK/$1.json"; FAIL=1; else echo "PASS state $1: нет $2"; fi; }

# 1. Samsung: диагностика — только чтение
run s_diag samsung '1\nТест\n'
expect s_diag 'Архив:'
expect s_diag 'подозрительное: com.hidden.spy.svc'
expect s_diag 'Отчёт для клиента:'
reject s_diag 'Exception'
nostate samsung 'rubin'

# 2. Samsung: оптимизация по умолчанию + перезагрузка с проверкой, затем откат
run s_opt samsung '2\nТест\n\nда\n\nда\n'
expect s_opt 'отключён com.samsung.android.rubin.app'
expect s_opt 'после перезагрузки всё отключённое осталось отключённым'
reject s_opt 'kgclient'
state samsung 'com.samsung.android.rubin.app'
run s_rest samsung '3\n\n\nда\n' keep
expect s_rest 'откат завершён'
nostate samsung 'rubin'

# 3. Xiaomi: прошивка не даёт отключить -> убрать для пользователя 0, DNS, затем откат
run x_opt xiaomi '2\nРедми\n2\n\nда\n\n\n'
expect x_opt 'убран для пользователя com.miui.msa.global'
expect x_opt 'частный DNS -> dns.adguard-dns.com'
state xiaomi 'com.miui.msa.global'
grep -q '12. БЫЛО / СТАЛО' "$WORK"/kit-xiaomi/reports/*/report.txt && echo "PASS x_opt: было / стало" || { echo "FAIL x_opt: нет «было / стало»"; FAIL=1; }
grep -q 'Что занимает память' "$WORK"/kit-xiaomi/reports/*/report.txt && echo "PASS x_opt: раздел памяти" || { echo "FAIL x_opt: нет раздела памяти"; FAIL=1; }
grep -q 'Расход батареи по приложениям' "$WORK"/kit-xiaomi/reports/*/report.txt && echo "PASS x_opt: расход батареи" || { echo "FAIL x_opt: нет расхода батареи"; FAIL=1; }
ls "$WORK"/kit-xiaomi/reports/*/client_report.html >/dev/null 2>&1 && echo "PASS x_opt: отчёт для клиента" || { echo "FAIL x_opt: нет client_report.html"; FAIL=1; }
# 3б. Выборочный откат: только запись 1 (настройка анимации), остальное остаётся в журнале
run x_part xiaomi '3\n\n1\nда\n' keep
expect x_part 'Откатываю выбранные: 1 из'
expect x_part 'В журнале осталось записей'
state xiaomi 'com.miui.msa.global'
run x_rest xiaomi '3\n\n\nда\n' keep
expect x_rest 'возвращён com.miui.msa.global'
nostate xiaomi 'msa.global'
nostate xiaomi 'adguard'

# 4. Поломка рабочего стола после партии -> откат партии и стоп
MOCK_BREAK=com.facebook.services run x_brk xiaomi '2\nТ\n\nда\n\n\n'
expect x_brk 'откатываю партию и останавливаюсь'
nostate xiaomi 'com.facebook.services'

# 5. DNS не работает в сети -> автооткат DNS
MOCK_DNSBROKEN=1 run x_dns xiaomi '2\nТ\n2\n\nда\n\n\n'
expect x_dns 'не работает в этой сети'
nostate xiaomi 'adguard'

# 5б. План: номер у отмеченного снимает галочку -> подсказка и предупреждение перед «да»; «нет» -> ничего не менялось
run x_tog xiaomi '2\nТ\n7-16\n\nнет\n'
expect x_tog 'Галочка СНЯТА (не будет сделано): 7 8 9 10 11 12 13 14 15 16'
expect x_tog 'С 10 пунктов «реклама, сбор данных, мусор» галочка снята'
expect x_tog 'Отменено — ничего не менялось'
nostate xiaomi 'msa.global'

# 5в. Только диагностика -> напоминание, что ничего не отключено
expect s_diag 'Это была только ДИАГНОСТИКА'

# 6. Wi-Fi: окно сопряжения не найдено, порт с главного экрана -> подсказка; затем верный ввод
MOCK_WIFI=1 MOCK_NOMDNS=1 run w_fault xiaomi '1\nТ\nw\n192.168.1.113:41235\n111111\nw\n123456\n192.168.1.113 : 37123\n123456\n'
expect w_fault 'введён порт с главного экрана'
expect w_fault 'Нужно IP и порт через двоеточие'
expect w_fault 'Сопряжение прошло'
expect w_fault 'Архив:'

# 6б. Wi-Fi + оптимизация + перезагрузка: отладка выключилась -> набор сам видит окно сопряжения и просит код
MOCK_WIFI=1 run w_reboot xiaomi '2\nТ\nw\n123456\n\nда\n\nда\n123456\n'
expect w_reboot 'вижу окно сопряжения на телефоне'
expect w_reboot 'Сопряжение прошло, подключаюсь'
expect w_reboot 'после перезагрузки всё отключённое осталось отключённым'

# 7. Пункт U на подставных данных Windows
if pwsh -NoProfile -File "$ROOT/tests/usbtest.ps1"; then echo "PASS usbtest"; else echo "FAIL usbtest"; FAIL=1; fi

# 8. Веб-интерфейс: сервер, ответы по HTTP, смена языка на ходу, отчёт
if python3 "$ROOT/tests/webtest.py" pwsh; then :; else FAIL=1; fi

if [ $FAIL -ne 0 ]; then echo "=== ЕСТЬ ОШИБКИ, логи: $WORK"; for f in "$WORK"/*.log; do echo "----- $f"; tail -40 "$f"; done; exit 1; fi
echo "=== ВСЕ ТЕСТЫ ПРОШЛИ"
