# Gateway Monitor v4.2

**Русский** · [English](#english)

Portable Windows-утилита для фонового мониторинга TCP-сервисов, MikroTik и VPN-шлюзов.

Программа периодически устанавливает TCP-соединение с каждым включённым узлом и показывает сводное состояние в системном трее. Каждый шлюз представлен отдельным сектором иконки:

- зелёный — сервис доступен (`OK`);
- красный — сервис недоступен (`FAIL`);
- серый — исходное состояние ещё определяется (`CHECKING`);
- отключённые шлюзы остаются в INI и не попадают в рабочий список и меню.

## Возможности

- мониторинг произвольных TCP-сервисов;
- раздельные пороги перехода в `FAIL` и восстановления в `OK`;
- защита от кратковременных сбоев и флаппинга;
- асинхронные проверки без блокировки tray-меню;
- индивидуальные уведомления для каждого шлюза;
- журналирование начального состояния и переходов `OK → FAIL` и `FAIL → OK`;
- автоматическая ротация журнала при достижении 5 МБ;
- хранение времени TCP-отклика за последние 24 часа в `gateways.dat` рядом с EXE;
- график отклика при наведении на строку шлюза в tray-меню;
- экспорт истории откликов за сутки в CSV;
- безопасное перечитывание конфигурации без перезапуска;
- защита от запуска второй копии;
- поддержка Windows x86 и x64;
- отсутствие внешних библиотек.

## Что изменилось в версии 4.2

Добавлена локализация интерфейса из INI. Английский встроен в программу и используется как запасной язык. Версия 4.1 добавила экспорт истории в CSV.

## Быстрый старт

1. Скомпилируйте `gateways_v4.pb` с включённым thread-safe runtime и иконкой `gateways.ico`.
2. Запустите приложение: оно создаст `%APPDATA%\Gateway Monitor\gateways.ini`.
3. Укажите свои адреса и порты в этом файле и включите нужные шлюзы.
4. В системном трее выберите «Перечитать конфиг».

Если рядом с EXE есть старый `gateways.ini`, при первом запуске он копируется в `%APPDATA%`. Иначе создаётся пример с отключённым шлюзом.

## Конфигурация

INI читается как UTF-8. Секция `[Settings]` содержит общие настройки, секции `[LANG-XXX]` — переводы, а каждая прочая секция описывает отдельный шлюз. Имя секции одновременно является именем шлюза, поэтому отдельные параметры `count` и `name` не нужны. Названия секций должны быть уникальными. Допускается не более 15 включённых шлюзов; количество отключённых не ограничено, они не загружаются в рабочий список.

Новая конфигурация сначала полностью проверяется и только после этого заменяет действующую. При ошибке приложение продолжает работать с предыдущими настройками и показывает уведомление. Старый нумерованный формат версий 3.0 и ниже необходимо преобразовать в именованные секции.

```ini
[Settings]
interval_sec=10
fail_count=3
recover_count=1
log_enabled=1
log_file=gateways.log
language=auto

[Router]
host=192.0.2.10
port=8291
enabled=1
alert_down=Router недоступен
alert_up=Связь с Router восстановлена

[VPN]
host=198.51.100.20
port=443
enabled=1
```

### Глобальные настройки

| Параметр | Назначение | Допустимые значения |
|---|---|---|
| `interval_sec` | Интервал между циклами проверки | 1–86400 секунд |
| `fail_count` | Неудачных проверок подряд до `FAIL` | 1–1000 |
| `recover_count` | Успешных проверок подряд до `OK` | 1–1000 |
| `log_enabled` | Включение журнала | `0` или `1` |
| `log_file` | Файл журнала | имя, относительный или абсолютный путь |
| `language` | Язык интерфейса | `auto` или код из секции `LANG-XXX` |

Относительный путь `log_file` вычисляется от каталога конфигурации.

### Языки интерфейса

`language=auto` выбирает секцию `[LANG-XXX]` с трёхбуквенным кодом системного языка Windows, например `[LANG-RUS]`; при отсутствии секции или отдельной строки перевода используется встроенный английский текст. Подменю «Язык» в tray-меню читает доступные секции и сохраняет выбранный код в `Settings.language`. Новые и прежние конфигурации автоматически получают полные секции `[LANG-ENG]` и `[LANG-RUS]`; они содержат все текстовые идентификаторы интерфейса.

### Настройки шлюза

| Параметр | Назначение |
|---|---|
| `host` | IP-адрес или DNS-имя |
| `port` | TCP-порт 1–65535 |
| `enabled` | `1` — проверять, `0` — исключить из рабочего списка и меню |
| `alert_down` | Заголовок уведомления при переходе в `FAIL` |
| `alert_up` | Заголовок уведомления при восстановлении в `OK` |

Уведомления отключены по умолчанию и показываются только при наличии соответствующего `alert_down` или `alert_up`.

## Работа программы

Первый цикл выполняется асинхронно. До получения достаточного количества результатов шлюз имеет состояние `CHECKING`. Первое подтверждённое состояние записывается как `INITIAL OK` или `INITIAL FAIL`; начальный `FAIL` также может показать настроенное уведомление. Перечитывание сохраняет состояние совпадающих шлюзов.

Одновременно проверяется до восьми шлюзов с таймаутом подключения 1500 мс на узел. Новый цикл не запускается, пока не завершён предыдущий; выход и перечитывание отменяют оставшиеся пробы между подключениями. Изменения одного цикла объединяются в одно уведомление.

Tray-меню открывается правым щелчком и показывает имя, состояние и время последней проверки каждого шлюза. При наведении на строку шлюза открывается график времени отклика за сутки; красная вертикаль обозначает неудачную проверку. Команда «Экспорт базы в CSV» сохраняет записи за последние 24 часа в UTF-8 CSV-файл с именем шлюза, адресом, портом, временем проверки, откликом в миллисекундах и результатом. По умолчанию предлагается файл `gateway_response_history.csv` в каталоге программы. Подменю «Язык» выбирает перевод из секций `[LANG-XXX]`. Перечитывание INI не блокирует интерфейс.

## Журналирование

В журнал записываются начальное состояние, запуск и остановка приложения, а также изменения состояния:

```text
21.05.2026 18:12:44  FAIL  Router  192.0.2.10:8291
21.05.2026 18:15:02  OK    Router  192.0.2.10:8291
```

После достижения 5 МБ файл переименовывается по шаблону `gateways.log.20260521-181500.old`. Хранятся не более 10 архивов.

## Сборка

Требуется PureBasic 6.40 для нужной архитектуры. В IDE включите:

- **Create thread-safe executable**;
- иконку `gateways.ico`;
- дополнительный ресурс `gateways.rc`;
- Windows XP theme support по желанию.

Не включайте **Create console executable**: Gateway Monitor является GUI-приложением.

Пример ручной сборки x64:

```powershell
& 'C:\Program Files\PureBasic\Compilers\pbcompiler.exe' gateways_v4.pb /OUTPUT gateways_v4.2_x64.exe /THREAD /ICON gateways.ico /RESOURCE gateways.rc /XP /DPIAWARE
```

Для x86 используйте компилятор из `C:\Program Files (x86)\PureBasic\Compilers\pbcompiler.exe`.

## Платформенные вызовы

Основная логика использует стандартные библиотеки PureBasic, включая Preferences и встроенную SQLite-библиотеку. WinAPI применяется для межпроцессного именованного мьютекса, balloon-уведомлений, языка Windows через `GetLocaleInfo_`, сообщения `TaskbarCreated`, фокуса tray-меню и события наведения на строку шлюза (`WM_MENUSELECT`). PureBasic не предоставляет стандартной команды для языка Windows и события наведения на строку меню.

## Лицензия

Разрешено свободное использование в личных и внутренних административных целях. Подробности: [LICENSE](LICENSE).

Copyright (c) 2026 CheshirCa

---

<a id="english"></a>

# English

[Русский](#gateway-monitor-v42) · **English**

Gateway Monitor is a portable Windows tray utility for monitoring TCP services, MikroTik devices, and VPN gateways.

The application periodically opens a TCP connection to every enabled endpoint and displays a combined status in the system tray. Each gateway is represented by one icon sector:

- green — the service is available (`OK`);
- red — the service is unavailable (`FAIL`);
- gray — the initial state is still being determined (`CHECKING`);
- disabled gateways remain in the INI but are omitted from the working list and menu.

## Features

- monitoring of arbitrary TCP services;
- separate failure and recovery thresholds;
- protection against transient failures and flapping;
- asynchronous checks that do not block the tray menu;
- per-gateway notifications;
- logging of initial states and `OK → FAIL` / `FAIL → OK` transitions;
- automatic log rotation at 5 MB;
- TCP response-time storage for the last 24 hours in `gateways.dat` beside the EXE;
- a response-time chart when hovering a gateway row in the tray menu;
- CSV export of the last 24 hours of response history;
- validated configuration reload without restarting;
- single-instance protection;
- Windows x86 and x64 support;
- no external libraries.

## What's new in version 4.2

The interface is now localized from the INI file. English is built in and used as the fallback language. Version 4.1 added response-history CSV export.

## Quick start

1. Compile `gateways_v4.pb` with the thread-safe runtime and `gateways.ico`.
2. Run the application to create `%APPDATA%\Gateway Monitor\gateways.ini`.
3. Edit addresses and ports in that file and enable the gateways you need.
4. Select “Reload configuration” from the tray menu.

On first launch, an old `gateways.ini` beside the executable is copied to `%APPDATA%` if present. Otherwise, a sample with a disabled gateway is created.

## Configuration

The INI file is read as UTF-8. `[Settings]` contains global options, `[LANG-XXX]` sections contain translations, and every other section describes one gateway. The section name is also used as the gateway name, so separate `count` and `name` values are no longer needed. Section names must be unique. At most 15 enabled gateways are allowed; disabled gateways are unlimited and are not loaded into the working list.

A new configuration is fully validated before it replaces the active one. If validation fails, the application keeps the previous settings and displays a notification. The numbered configuration format used by version 3.0 and earlier must be converted to named sections.

```ini
[Settings]
interval_sec=10
fail_count=3
recover_count=1
log_enabled=1
log_file=gateways.log
language=auto

[Router]
host=192.0.2.10
port=8291
enabled=1
alert_down=Router is unavailable
alert_up=Router connection restored

[VPN]
host=198.51.100.20
port=443
enabled=1
```

### Global settings

| Setting | Purpose | Valid values |
|---|---|---|
| `interval_sec` | Delay between check cycles | 1–86400 seconds |
| `fail_count` | Consecutive failures required for `FAIL` | 1–1000 |
| `recover_count` | Consecutive successes required for `OK` | 1–1000 |
| `log_enabled` | Enable event logging | `0` or `1` |
| `log_file` | Log file | file name, relative path, or absolute path |
| `language` | Interface language | `auto` or a code from a `LANG-XXX` section |

A relative `log_file` path is resolved against the configuration directory.

### Interface languages

`language=auto` selects the `[LANG-XXX]` section matching the three-letter Windows system-language code, such as `[LANG-RUS]`; built-in English text is used if a section or an individual translation is missing. The tray-menu Language submenu reads available sections and stores its selection in `Settings.language`. New and older configurations automatically receive complete `[LANG-ENG]` and `[LANG-RUS]` sections containing every interface text identifier.

### Gateway settings

| Setting | Purpose |
|---|---|
| `host` | IP address or DNS name |
| `port` | TCP port in the 1–65535 range |
| `enabled` | `1` to monitor, `0` to omit from the working list and menu |
| `alert_down` | Notification title used on transition to `FAIL` |
| `alert_up` | Notification title used on recovery to `OK` |

Notifications are disabled by default and are displayed only when the corresponding `alert_down` or `alert_up` value is present.

## Runtime behavior

The first cycle runs asynchronously. Until enough results have been collected, a gateway remains in the `CHECKING` state. The first confirmed state is logged as `INITIAL OK` or `INITIAL FAIL`; an initial `FAIL` can also show its configured notification. Reloading preserves the state of matching gateways.

Up to eight gateways are checked concurrently, with a 1500 ms connection timeout per gateway. A new cycle is not started while the previous one is still running; exit and reload cancel remaining probes between connections. Changes from one cycle are combined into one notification.

The tray menu opens on right-click and displays each gateway's name, state, and last-check time. Hovering a gateway row opens a 24-hour response-time chart; a red vertical mark denotes a failed probe. The “Export database to CSV” command saves the last 24 hours of records to a UTF-8 CSV file with the gateway name, address, port, check time, response time in milliseconds, and result. The suggested name is `gateway_response_history.csv` in the program directory. The Language submenu selects a translation from `[LANG-XXX]` sections. Reloading the INI does not block the interface.

## Logging

The log records the initial state, application start and stop, and later state changes:

```text
21.05.2026 18:12:44  FAIL  Router  192.0.2.10:8291
21.05.2026 18:15:02  OK    Router  192.0.2.10:8291
```

At 5 MB the file is renamed using the `gateways.log.20260521-181500.old` pattern. At most 10 archives are kept.

## Building

PureBasic 6.40 for the target architecture is required. Enable the following IDE options:

- **Create thread-safe executable**;
- the `gateways.ico` application icon;
- the additional `gateways.rc` resource;
- Windows XP theme support if desired.

Do not enable **Create console executable**: Gateway Monitor is a GUI application.

Example manual x64 build:

```powershell
& 'C:\Program Files\PureBasic\Compilers\pbcompiler.exe' gateways_v4.pb /OUTPUT gateways_v4.2_x64.exe /THREAD /ICON gateways.ico /RESOURCE gateways.rc /XP /DPIAWARE
```

For x86 use the compiler at `C:\Program Files (x86)\PureBasic\Compilers\pbcompiler.exe`.

## Platform-specific calls

The main implementation uses standard PureBasic libraries, including Preferences and the built-in SQLite library. WinAPI is used for the interprocess named mutex, tray balloons, Windows language detection through `GetLocaleInfo_`, Explorer's `TaskbarCreated` message, tray-menu focus, and the gateway-row hover event (`WM_MENUSELECT`). PureBasic does not expose a standard Windows-language query or a menu-row hover event.

## License

Free use is permitted for personal and internal administrative purposes. See [LICENSE](LICENSE).

Copyright (c) 2026 CheshirCa
