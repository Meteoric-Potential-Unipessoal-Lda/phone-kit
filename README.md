# phone-kit

**EN** · A repair technician's tool that safely cleans up and speeds up Android phones and tablets over ADB: Samsung, Xiaomi / Redmi / Poco, Realme / OPPO, Honor / Huawei, Motorola, Pixel and others. Runs on Windows or Mac, opens a local page in the browser (works offline); the phone connects by USB cable or by Wi-Fi pairing code (Android 11+). Rule number one is **do no harm**: read-only diagnostics first, then a plan with checkboxes, changes only after you confirm, in batches with checks, everything reversible and logged for one-click rollback.

Interface languages: Русский, Українська, English, Português, Español, Français, Italiano, Deutsch, Latviešu, Polski.

**RU** · Инструмент мастера, который безопасно чистит и ускоряет телефоны и планшеты Android по ADB. Запускается на компьютере (Windows или Mac) и открывает страницу в браузере (без интернета); телефон подключается кабелем или по Wi-Fi кодом (Android 11+). Главное правило — **не навредить**: сначала диагностика (только чтение), потом план с галочками, изменения только после подтверждения, партиями с проверкой, всё обратимо и записывается в журнал для отката.

## Что умеет / Features

- **Диагностика / Diagnostics** — память, хранилище, батарея, нагрев, процессор, чем пользуются, приложения по умолчанию; отчёт и архив.
- **Безопасность / Security check** — сторонние приложения со спецвозможностями, администраторы устройства, поставленные не из магазина, без значка, «чистильщики».
- **Оптимизация / Optimization** — отключение рекламы, аналитики и мусора производителя (база [Universal Android Debloater](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation) + свои правила), анимации 0.5x, частный DNS AdGuard против рекламы, запрет фона неиспользуемым приложениям, очистка кэша.
- **Откат / Rollback** — по журналу.

Никогда не трогает связь и SIM, Google Play и сервисы Google, клавиатуры, рабочий стол, Knox и kgclient у Samsung, «Безопасность» Xiaomi, камеру, платежи, родительский контроль, приложения по умолчанию и всё, чем пользовались за последний месяц. Root, прошивки и удаление насовсем — нет.

## Как пользоваться / How to use

1. Скачать репозиторий (Code → Download ZIP) и распаковать в папку `phone-kit`.
2. Один раз запустить `prepare.bat` (Windows): скачает в `tools\` ADB для Windows и Mac, PowerShell для Mac и драйвер Google USB.
3. На телефоне включить режим разработчика и «Отладку по USB» (или «Беспроводную отладку»).
4. Windows: `start.bat`. Mac: в Терминале `bash ~/Desktop/phone-kit/start.command`. Откроется страница в браузере; окно консоли остаётся — отвечать можно и там.
5. Выбрать: **Диагностика**, **Оптимизация** или **Откат**.

Параметры: `-Lang en` — язык, `-Console` — только консоль, `-Web -NoBrowser` — страница без автозапуска браузера. Подробно — в [README.txt](README.txt).

## Файлы / Files

| Файл | Что это |
| --- | --- |
| `phonekit.ps1` | сам набор (Windows PowerShell 5.1 / PowerShell 7) |
| `ui/index.html` | страница интерфейса (без внешних библиотек и шрифтов) |
| `data/lang/<код>.json` | все тексты набора и страницы на 10 языках |
| `data/notes/<код>.tsv` | пояснения к пакетам на языках (русские — в `data/ru.tsv`) |
| `data/uad.tsv` | база пакетов из Universal Android Debloater Next Generation (GPL-3.0) |
| `data/ru.tsv` | свои правила: `ok` / `ask` / `protect` — сильнее базы |
| `start.bat`, `start.command`, `prepare.bat` | запуск на Windows / Mac, подготовка папки |
| `tests/` | подставной adb, сценарные тесты, тест веб-интерфейса |

Страница работает только на этом компьютере: сервер слушает `127.0.0.1`, адрес содержит случайный ключ.
Файлы набора хранятся с точными байтами (`.gitattributes`): `.ps1` — UTF-8 с BOM и CRLF, `.bat` — ASCII и CRLF, `start.command` — LF.

## Переводы / Translations

Ключ → шаблон с `{0}`, `{1}`… в `data/lang/<код>.json`. Нет строки — берётся английская, потом русская. Поправки носителей языка приветствуются: исправьте строку в файле своего языка и пришлите pull request.

## Тесты / Tests

```
bash tests/run.sh
```

Нужны `pwsh` и `python3`. Сценарии: диагностика, оптимизация и откат на Samsung и Xiaomi, запасной вариант, когда прошивка не даёт отключить пакет, поломка рабочего стола после партии, неработающий DNS, сопряжение по Wi-Fi и после перезагрузки, проверка кабеля на Windows, веб-интерфейс (ответы по HTTP, смена языка). GitHub Actions: Linux (PowerShell 7) и Windows PowerShell 5.1.

## Лицензия / License

GPL-3.0 — см. [LICENSE](LICENSE). База `data/uad.tsv` получена из [Universal Android Debloater Next Generation](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation) (GPL-3.0).
