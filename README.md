# Gateway Monitor v3.1

**Русский** · [English](#english)

Portable Windows-утилита для фонового мониторинга TCP-сервисов, MikroTik и VPN-шлюзов.

Программа периодически устанавливает TCP-соединение с каждым включённым узлом и показывает сводное состояние в системном трее. Каждый шлюз представлен отдельным сектором иконки:

- зелёный — сервис доступен (`OK`);
- красный — сервис недоступен (`FAIL`);
- серый — исходное состояние ещё определяется (`CHECKING`);
- отключённые шлюзы не занимают сектор иконки.

## Возможности

- мониторинг произвольных TCP-сервисов;
- раздельные пороги перехода в `FAIL` и восстановления в `OK`;
- защита от кратковременных сбоев и флаппинга;
- асинхронные проверки без блокировки tray-меню;
- индивидуальные уведомления для каждого шлюза;
- журналирование переходов `OK → FAIL` и `FAIL → OK`;
- автоматическая ротация журнала при достижении 5 МБ;
- безопасное перечитывание конфигурации без перезапуска;
- защита от запуска второй копии;
- поддержка Windows x86 и x64;
- отсутствие внешних библиотек.

## Что изменилось в версии 3.1

Конфигурация стала короче и понятнее. Секции `[Gateways]`, `[Gateway1]`, `[Gateway2]` и параметр `count` больше не используются. Теперь название каждой секции одновременно является названием шлюза.

## Быстрый старт

1. Скомпилируйте `gateways_v3.pb` с включённым thread-safe runtime и иконкой `gateways.ico`.
2. Скопируйте `gateways.example.ini` в `gateways.ini` рядом с EXE.
3. Укажите свои адреса и порты в `gateways.ini`.
4. Запустите приложение — оно появится в системном трее.

Если `gateways.ini` отсутствует и каталог доступен для записи, программа создаст пример автоматически.

## Конфигурация

INI читается как UTF-8. Секция `[Settings]` содержит общие настройки, а каждая следующая секция описывает отдельный шлюз. Имя секции одновременно является именем шлюза, поэтому отдельные параметры `count` и `name` не нужны. Названия секций должны быть уникальными.

Новая конфигурация сначала полностью проверяется и только после этого заменяет действующую. При ошибке приложение продолжает работать с предыдущими настройками и показывает уведомление. Старый нумерованный формат версий 3.0 и ниже необходимо преобразовать в именованные секции.

```ini
[Settings]
interval_sec=10
fail_count=3
recover_count=1
log_enabled=1
log_file=gateways.log

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

Относительный путь `log_file` вычисляется от каталога EXE.

### Настройки шлюза

| Параметр | Назначение |
|---|---|
| `host` | IP-адрес или DNS-имя |
| `port` | TCP-порт 1–65535 |
| `enabled` | `1` — проверять, `0` — показать как `DISABLED` |
| `alert_down` | Заголовок уведомления при переходе в `FAIL` |
| `alert_up` | Заголовок уведомления при восстановлении в `OK` |

Уведомления отключены по умолчанию и показываются только при наличии соответствующего `alert_down` или `alert_up`.

## Работа программы

Первый цикл выполняется асинхронно. До получения достаточного количества результатов шлюз имеет состояние `CHECKING`. Установка исходного состояния не записывается как авария или восстановление.

Проверки выполняются последовательно с таймаутом подключения 1500 мс на узел. Новый цикл не запускается, пока не завершён предыдущий.

Tray-меню показывает имя, состояние и время последней проверки каждого шлюза, а также позволяет открыть журнал, перечитать конфигурацию или завершить работу. Перечитывание INI не блокирует интерфейс: если проверка уже выполняется, новая конфигурация применяется после её завершения.

## Журналирование

В журнал записываются реальные изменения состояния:

```text
21.05.2026 18:12:44  FAIL  Router  192.0.2.10:8291
21.05.2026 18:15:02  OK    Router  192.0.2.10:8291
```

После достижения 5 МБ файл переименовывается по шаблону `gateways.log.20260521-181500.old`.

## Сборка

Требуется PureBasic 6.40 для нужной архитектуры. В IDE включите:

- **Create thread-safe executable**;
- иконку `gateways.ico`;
- дополнительный ресурс `gateways.rc`;
- Windows XP theme support по желанию.

Не включайте **Create console executable**: Gateway Monitor является GUI-приложением.

Пример ручной сборки x64:

```powershell
& 'C:\Program Files\PureBasic\Compilers\pbcompiler.exe' gateways_v3.pb /OUTPUT gateways_v3.1_x64.exe /THREAD /ICON gateways.ico /RESOURCE gateways.rc /XP
```

Для x86 используйте компилятор из `C:\Program Files (x86)\PureBasic\Compilers\pbcompiler.exe`.

## Платформенные вызовы

Основная логика использует стандартные библиотеки PureBasic. WinAPI оставлен только для межпроцессного именованного мьютекса и balloon-уведомлений системного трея, для которых в стандартной библиотеке нет полного эквивалента.

## Лицензия

Разрешено свободное использование в личных и внутренних административных целях. Подробности: [LICENSE](LICENSE).

Copyright (c) 2026 CheshirCa

---

<a id="english"></a>

# English

[Русский](#gateway-monitor-v31) · **English**

Gateway Monitor is a portable Windows tray utility for monitoring TCP services, MikroTik devices, and VPN gateways.

The application periodically opens a TCP connection to every enabled endpoint and displays a combined status in the system tray. Each gateway is represented by one icon sector:

- green — the service is available (`OK`);
- red — the service is unavailable (`FAIL`);
- gray — the initial state is still being determined (`CHECKING`);
- disabled gateways do not occupy an icon sector.

## Features

- monitoring of arbitrary TCP services;
- separate failure and recovery thresholds;
- protection against transient failures and flapping;
- asynchronous checks that do not block the tray menu;
- per-gateway notifications;
- logging of `OK → FAIL` and `FAIL → OK` transitions;
- automatic log rotation at 5 MB;
- validated configuration reload without restarting;
- single-instance protection;
- Windows x86 and x64 support;
- no external libraries.

## What's new in version 3.1

Configuration is now shorter and easier to read. `[Gateways]`, `[Gateway1]`, `[Gateway2]`, and the `count` setting are no longer used. Every section name is now also the gateway name.

## Quick start

1. Compile `gateways_v3.pb` with the thread-safe runtime and `gateways.ico`.
2. Copy `gateways.example.ini` to `gateways.ini` next to the executable.
3. Enter your addresses and ports in `gateways.ini`.
4. Run the application — it will appear in the system tray.

If `gateways.ini` is missing and the directory is writable, the application creates a sample configuration automatically.

## Configuration

The INI file is read as UTF-8. `[Settings]` contains global options and every other section describes one gateway. The section name is also used as the gateway name, so separate `count` and `name` values are no longer needed. Section names must be unique.

A new configuration is fully validated before it replaces the active one. If validation fails, the application keeps the previous settings and displays a notification. The numbered configuration format used by version 3.0 and earlier must be converted to named sections.

```ini
[Settings]
interval_sec=10
fail_count=3
recover_count=1
log_enabled=1
log_file=gateways.log

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

A relative `log_file` path is resolved against the executable directory.

### Gateway settings

| Setting | Purpose |
|---|---|
| `host` | IP address or DNS name |
| `port` | TCP port in the 1–65535 range |
| `enabled` | `1` to monitor, `0` to display as `DISABLED` |
| `alert_down` | Notification title used on transition to `FAIL` |
| `alert_up` | Notification title used on recovery to `OK` |

Notifications are disabled by default and are displayed only when the corresponding `alert_down` or `alert_up` value is present.

## Runtime behavior

The first cycle runs asynchronously. Until enough results have been collected, a gateway remains in the `CHECKING` state. Establishing the initial state is not logged as an outage or recovery.

Checks are sequential, with a 1500 ms connection timeout per gateway. A new cycle is not started while the previous cycle is still running.

The tray menu displays each gateway's name, state, and last-check time and provides commands to open the log, reload the configuration, or exit. Reloading the INI does not block the interface: if a check is running, the new configuration is applied after it finishes.

## Logging

Only actual state changes are written to the log:

```text
21.05.2026 18:12:44  FAIL  Router  192.0.2.10:8291
21.05.2026 18:15:02  OK    Router  192.0.2.10:8291
```

At 5 MB the file is renamed using the `gateways.log.20260521-181500.old` pattern.

## Building

PureBasic 6.40 for the target architecture is required. Enable the following IDE options:

- **Create thread-safe executable**;
- the `gateways.ico` application icon;
- the additional `gateways.rc` resource;
- Windows XP theme support if desired.

Do not enable **Create console executable**: Gateway Monitor is a GUI application.

Example manual x64 build:

```powershell
& 'C:\Program Files\PureBasic\Compilers\pbcompiler.exe' gateways_v3.pb /OUTPUT gateways_v3.1_x64.exe /THREAD /ICON gateways.ico /RESOURCE gateways.rc /XP
```

For x86 use the compiler at `C:\Program Files (x86)\PureBasic\Compilers\pbcompiler.exe`.

## Platform-specific calls

The main implementation uses standard PureBasic libraries. WinAPI remains only for the interprocess named mutex and system-tray balloon notifications, which do not have complete standard-library equivalents.

## License

Free use is permitted for personal and internal administrative purposes. See [LICENSE](LICENSE).

Copyright (c) 2026 CheshirCa
