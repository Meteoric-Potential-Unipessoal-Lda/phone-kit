# phone-kit — телефон-набор мастера

Инструмент для мастера, который чистит и облегчает телефоны и планшеты Android по ADB: Samsung, Xiaomi / Redmi / Poco, Realme / OPPO, Honor / Huawei, Motorola, Pixel и другие. Запускается на компьютере (Windows или Mac), телефон подключается кабелем или по Wi-Fi кодом (Android 11+).

Главное правило — **не навредить**: сначала диагностика (только чтение), потом план с галочками, изменения только после «да», партиями с проверкой, всё обратимо и записывается в журнал для отката.

## Что умеет

- **Диагностика**: память, хранилище, батарея, нагрев, процессор, чем пользуются, приложения по умолчанию, отчёт и архив.
- **Проверка безопасности**: сторонние приложения со спецвозможностями, администраторы устройства, поставленные не из магазина, без значка, «чистильщики».
- **Оптимизация**: отключение рекламы, аналитики и мусора производителя (база [Universal Android Debloater](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation) + свои правила), анимации 0.5x, частный DNS AdGuard от рекламы, запрет фона неиспользуемым приложениям, очистка кэша.
- **Откат** по журналу.

Никогда не трогает связь и SIM, Google Play и сервисы Google, клавиатуры, рабочий стол, Knox и kgclient у Samsung, «Безопасность» Xiaomi, камеру, платежи, родительский контроль, приложения по умолчанию и всё, чем пользовались за последний месяц. Root, прошивки и удаление насовсем — нет.

## Как пользоваться

1. Скачать репозиторий (Code → Download ZIP) и распаковать в папку `phone-kit`.
2. Один раз запустить `prepare.bat` (Windows): скачает в `tools\` ADB для Windows и Mac, PowerShell для Mac и драйвер Google USB.
3. На телефоне включить режим разработчика и «Отладку по USB» (подсказка по маркам — пункт **H** в наборе).
4. Windows: `start.bat`. Mac: в Терминале `bash ~/Desktop/phone-kit/start.command`.
5. Меню: **1** — диагностика, **2** — оптимизация, **3** — откат.

Подробно — в [README.txt](README.txt).

## Файлы

| Файл | Что это |
| --- | --- |
| `phonekit.ps1` | сам набор (Windows PowerShell 5.1 / PowerShell 7) |
| `start.bat`, `start.command`, `prepare.bat` | запуск на Windows / Mac, подготовка папки |
| `data/uad.tsv` | база пакетов из Universal Android Debloater Next Generation (GPL-3.0) |
| `data/ru.tsv` | русские пояснения и свои правила: `ok` / `ask` / `protect` — сильнее базы |
| `tests/` | подставной adb и сценарные тесты (GitHub Actions: Linux pwsh 7 + Windows PowerShell 5.1) |

Файлы набора хранятся с точными байтами (`.gitattributes`): `.ps1` — UTF-8 с BOM и CRLF, `.bat` — ASCII и CRLF, `start.command` — LF.

## Тесты

```
bash tests/run.sh
```

Нужны `pwsh` и `python3`. Сценарии: диагностика, оптимизация и откат на Samsung и Xiaomi, запасной вариант, когда прошивка не даёт отключить пакет, поломка рабочего стола после партии, неработающий DNS, сопряжение по Wi-Fi, проверка кабеля на Windows.

## Лицензия

GPL-3.0 — см. [LICENSE](LICENSE). База `data/uad.tsv` получена из [Universal Android Debloater Next Generation](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation) (GPL-3.0).
