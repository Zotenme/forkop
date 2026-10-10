# AGENTS.md

Руководство для агентов и разработчиков, работающих с этим репозиторием.

## Что это

Forkop — сервис маршрутизации трафика для OpenWrt (sing-box + zapret/zapret2/ByeDPI) с LuCI-интерфейсом. Репозиторий `Zotenme/forkop` — самостоятельно поддерживаемый форк `ushan0v/forkop`; апстрим больше не развивается, изменения оттуда не ожидаются.

Целевая платформа — роутер с OpenWrt (24.10 — пакеты IPK, 25.12 — пакеты APK). Код службы исполняется интерпретатором `ucode` на устройстве, поэтому на машине разработчика он запускается только в Docker.

## Структура

| Путь | Что там |
| --- | --- |
| `forkop/` | Пакет службы. `Makefile` — рецепт OpenWrt, `files/` раскладывается в корень роутера. |
| `forkop/files/usr/bin/forkop` | CLI-точка входа на ucode; диспетчер команд, подгружает модули из `/usr/lib/forkop`. |
| `forkop/files/usr/lib/` | Модули службы (`*.uc`), на роутере — `/usr/lib/forkop/`. |
| `forkop/files/etc/init.d/forkop` | procd init-скрипт (shell). |
| `forkop/files/etc/config/forkop` | UCI-конфиг по умолчанию. |
| `fe-app-forkop/` | Исходники LuCI-интерфейса на TypeScript (tsup, vitest, eslint, prettier, yarn v1). |
| `luci-app-forkop/` | Пакет LuCI. `htdocs/.../view/forkop/main.js` — **сгенерированный** бандл, `po/` — переводы. |
| `tests/` | Backend-тесты: по одному bash-скрипту на тему, `helpers/` — вспомогательные скрипты для node. |
| `tests/docker/Dockerfile` | Локальное тестовое окружение, повторяет CI. |
| `build.sh` | Сборка IPK и APK через OpenWrt SDK. |
| `install.sh` | Установщик, который пользователь запускает на роутере. |

Модули в `forkop/files/usr/lib/`:

- `core/` — константы, хелперы, обёртка над UCI, работа с URL и IP.
- `config/` — валидация и миграция конфига.
- `singbox/` — генерация конфига sing-box (маршруты, DNS, rule sets, URLTest, подписки, серверы).
- `subscription/` — загрузка и разбор подписок.
- `service/` — жизненный цикл службы, план перезагрузки, состояние, хуки пакета.
- `dns/`, `nft/`, `routing/` — применение DNS, nftables и маршрутов.
- `providers/` — zapret, zapret2, ByeDPI, nfqueue.
- `components/` — менеджер обновлений и установки компонентов.
- `server/`, `diagnostics/` — собственный сервер и диагностика.

## Тесты

Все проверки запускаются в Docker. Образ собирается один раз:

```sh
docker build --load -t forkop-ci tests/docker
```

### Backend

Репозиторий монтируется только для чтения, тесты идут на копии внутри контейнера:

```sh
docker run --rm -v "$PWD":/repo:ro forkop-ci bash -c '
  cp -a /repo /src/w && cd /src/w
  find forkop/files/usr/lib -name "*.uc" -print0 | xargs -0 -n1 ucode -c -o /dev/null
  find forkop/files/usr/lib -name "*.uc" -print0 | xargs -0 -n1 ucode -S -c -o /dev/null
  printf "%s\0" tests/*.sh | xargs -0 -n1 -P4 bash
'
```

Один тест: `... bash -c 'cp -a /repo /src/w && cd /src/w && bash tests/sing_box_runtime.sh'`.

- Признак ошибки — ненулевой код возврата и строка `FAIL: ...`; при успехе тест может печатать служебный вывод.
- `tests/config_contract_matrix.sh` сравнивает конфиг с базовой версией по git-тегу `0.7.19.9`. Если тега нет локально, тест сам скачивает его из `origin`, а затем из апстрима (`FORKOP_STABLE_REMOTE`). В контейнере репозиторий — копия, поэтому тег остаётся только там.
- ShellCheck: `shellcheck --severity=error build.sh install.sh forkop/files/etc/init.d/forkop luci-app-forkop/root/etc/uci-defaults/50_luci-forkop tests/*.sh`

### Frontend

`node_modules` живёт в именованном томе, чтобы бинарники для Linux не попадали на хост:

```sh
docker run --rm -v "$PWD":/src -v forkop-node-modules:/src/fe-app-forkop/node_modules \
  -w /src/fe-app-forkop forkop-ci sh -c '
  yarn install --frozen-lockfile
  yarn lint --max-warnings=0
  yarn test --run
  yarn build
'
```

`yarn build` перезаписывает `luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js` в рабочем дереве — это ожидаемо.

## Правила работы с кодом

### Backend (ucode)

- Вся логика службы пишется на ucode. Shell допустим только в `forkop/files/etc/init.d/forkop` и `luci-app-forkop/root/etc/uci-defaults/50_luci-forkop`; `tests/shell_inventory.sh` падает, если появляется другой shell-файл.
- Каждый `.uc` должен проходить `ucode -c` и `ucode -S -c` (строгий режим).
- Пути, имена и URL берутся из `core/constants.uc`, где каждое значение переопределяется переменной окружения. Тесты опираются на это: подменяют `FORKOP_LIB`, `FORKOP_CONFIG` и т. п. и подкладывают фальшивые `uci`, `nft`, `sing-box`, `curl` через `PATH`. Новые внешние зависимости добавляй тем же способом, а не хардкодом.
- Строка `__COMPILED_VERSION_VARIABLE__` в `constants.uc` заменяется версией при сборке — не трогать.
- Изменения формата UCI-конфига требуют миграции в `config/migration.uc` и обновления `tests/config_migration.sh` и `tests/config_contract_matrix.sh`.
- На каждое исправление поведения — тест в `tests/`: дополни существующий скрипт по теме или добавь новый `tests/<тема>.sh` в том же стиле (`set -eo pipefail`, функции `fail`/`assert_eq`, временный каталог с `trap`).

### Frontend (TypeScript)

- Править только `fe-app-forkop/src`. `main.js` в `luci-app-forkop` вручную не редактируется; после правок запусти `yarn build` и закоммить обновлённый бандл вместе с исходниками — CI проверяет, что сборка не даёт диффа.
- Остальные файлы в `luci-app-forkop/htdocs/.../view/forkop/*.js` написаны вручную (обычный LuCI JS).
- Новые строки интерфейса оборачиваются в `_()`; после этого `yarn locales:actualize`, затем перевод в `fe-app-forkop/locales/forkop.ru.po` и ещё раз `yarn locales:distribute`.
- Форматирование — prettier (`yarn format`), линтер без предупреждений.

### Общее

- Сообщения коммитов — на английском, в повелительном наклонении, одной строкой: `Fix list download failure alerts`.
- Не добавляй в репозиторий `dist/`, `.build/`, `sandbox/`, `node_modules` — они в `.gitignore`.

## Сборка и релиз

- `./build.sh <x.y.z> [каталог]` собирает IPK и APK. Нужен Linux x86_64 с user namespaces: скрипт скачивает OpenWrt SDK под x86_64. На macOS/arm64 локально не запускается — сборка идёт в GitHub Actions.
- `.github/workflows/build.yml` запускается по тегу формата `x.y.z` (или вручную) и публикует релиз в `Zotenme/forkop`.
- Версия пакета берётся из тега, в исходниках её нет.
- Выпуск релиза: `git tag 1.0.7 && git push origin 1.0.7`. Номер должен быть больше предыдущего — по нему менеджер обновлений на роутере решает, есть ли новая версия.
- `install.sh` (`REPO_OWNER`) и менеджер обновлений (`FORKOP_RELEASE_REPO` в `core/constants.uc`) берут пакеты из последнего релиза `Zotenme/forkop`. Команда установки из README работает, только пока там есть опубликованный релиз с IPK и APK.
- Теги апстрима (`0.7.19.9`, `1.0.x`) в форк не пушить: push тега запускает сборку релиза.

## Наследие апстрима

Установщик, менеджер обновлений, метаданные пакетов и ссылки в интерфейсе указывают на `Zotenme/forkop`. От апстрима намеренно оставлено:

- `SRS_SUPERCELL_URL` (`core/constants.uc`, `singbox/rulesets.uc`) — список правил из отдельного репозитория `ushan0v/sing-box-supercell-ruleset`;
- имя автора в заголовках переводов (`*.po`, `*.pot`) и в `fe-app-forkop/generate-pot.js`;
- упоминание происхождения в README.
