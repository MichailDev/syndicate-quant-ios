# SYNDICATE QUANT iOS 5.1 — запуск БЕЗ Mac

## Что это

Нативное iOS-приложение. Telegram, Windows API, FastAPI и Python для работы приложения не нужны.

На iPhone выполняются:
- Dixon–Coles;
- Poisson / Negative Binomial для счётных рынков;
- Monte Carlo;
- Glicko adjustment;
- Bottom-Up Player Assembly / ExpMin;
- referee adjustment;
- market consensus и dispersion guard;
- sharp-book guard;
- DCS / QCS;
- EV / robust EV;
- quarter-line split;
- Kelly с ограничением 2%;
- portfolio correlation и максимум 10% совокупной экспозиции;
- локальный журнал;
- локальная калибровка и walk-forward инфраструктура;
- фоновые обновления iOS и уведомления.

Принцип: `NO DATA → NO NUMBER → NO EDGE → NO BET`.

## Важно

Mac на стороне пользователя НЕ НУЖЕН.
GitHub Actions автоматически запускает сборку на GitHub-hosted macOS runner. После сборки получается unsigned IPA. Его можно установить на iPhone с Windows через AltServer/AltStore Classic.

GitHub официально поддерживает macOS-hosted runners, включая `macos-26`. Для public repositories стандартные GitHub-hosted runners бесплатны; для private repositories используются включённые минуты вашего плана, после исчерпания лимита действует тарификация. См. документацию GitHub.

## Шаг 1. GitHub

1. На Windows создай репозиторий GitHub, например `syndicate-quant-ios`.
2. Для простоты можно сделать **Public**: сборки стандартного GitHub-hosted runner для public repository бесплатны. Если код должен оставаться закрытым — используй Private и учитывай лимит Actions.
3. Загрузи в репозиторий ВСЁ содержимое этого архива, сохранив структуру:

```text
ios/
.github/workflows/ios-build.yml
README_IOS_WINDOWS_GITHUB_RU.md
PORTING_MATRIX_RU.md
```

API key в GitHub загружать НЕ НУЖНО.

## Шаг 2. Запуск сборки

На странице репозитория:

`Actions` → `Build SYNDICATE QUANT iOS (Windows-only workflow)` → `Run workflow`.

Подожди завершения job `build`.

После `green` открой:

`Actions` → нужный run → `Artifacts`.

Скачай:

`syndicate-quant-ios-unsigned`

Внутри будет:

`SYNDICATE_QUANT_iOS_UNSIGNED.ipa`

## Шаг 3. Установка на iPhone с Windows

Используй **AltStore Classic + AltServer**, а не AltStore PAL: PAL не предназначен для установки произвольных IPA.

1. Установи AltServer на Windows с официального сайта AltStore.
2. Установи необходимые Apple-компоненты согласно инструкции AltServer.
3. Подключи iPhone по USB или используй одну Wi‑Fi сеть.
4. На iPhone включи `Settings → Privacy & Security → Developer Mode`, если iOS этого требует.
5. Через AltServer установи AltStore на iPhone.
6. В AltServer используй прямую установку IPA / sideload и выбери:

`SYNDICATE_QUANT_iOS_UNSIGNED.ipa`

7. Авторизуйся своим Apple ID, если AltServer попросит.

AltServer подпишет IPA для устройства. При бесплатном Apple ID подпись для sideloaded apps обычно требует периодического обновления; актуальный срок и ограничения проверяй в AltStore/Apple.

## Шаг 4. SStats

После запуска приложения:

`Настройки → SStats API → API key`

Введи свой SStats API key.

Ключ сохраняется в iOS Keychain.

Приложение напрямую обращается к:

`https://api.sstats.net`

Никакого промежуточного Windows-сервера нет.

## Шаг 5. Первый прогноз

Открой `Прогноз` → `Обновить`.

Приложение:

1. получает сегодняшние матчи;
2. отбрасывает исключённые соревнования;
3. получает историю команд;
4. получает GameInfo;
5. получает коэффициенты;
6. строит модель;
7. применяет DCS/QCS и robust-EV guards;
8. применяет price anomaly / thin market / sharp guard;
9. формирует только прошедшие фильтр сигналы;
10. сохраняет выбранные ставки в локальный журнал.

## Фоновая работа

iOS сама решает точный момент запуска background refresh. Это не сервер 24/7 и не может быть гарантировано системой iOS.

В приложении включи:

`Настройки → Фоновое обновление`

и выбери интервал.

Также можно включить уведомления о подтверждённых сигналах.

## Безопасность

Не помещай SStats API key:
- в GitHub repository;
- в workflow YAML;
- в исходный код;
- в README;
- в скриншоты.

Ключ вводится только на устройстве и хранится в Keychain.

## Что проверять, если GitHub Build красный

1. Открой `Actions`.
2. Открой failed run.
3. Сначала посмотри шаг `Validate project`.
4. Затем `Build unsigned app`.
5. Скопируй сюда текст ошибки из этих двух шагов.

Не нужно устанавливать Xcode и не нужно покупать Mac для этого процесса.
