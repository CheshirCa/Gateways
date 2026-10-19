# Gateway Monitor 4.2

## Русский

### 4.2

- Интерфейс локализуется из секций `[LANG-XXX]` в `gateways.ini`.
- При `language=auto` выбирается секция, совпадающая с трёхбуквенным кодом системного языка Windows, например `RUS`.
- Английский встроен в программу и используется при отсутствии подходящего перевода.
- В tray-меню добавлено подменю «Язык»; выбор сохраняется в `Settings.language`.
- Старые конфигурации автоматически дополняются полными секциями `[LANG-ENG]` и `[LANG-RUS]`.

### 4.1

- Команда «Экспорт базы в CSV» сохраняет историю откликов за сутки в UTF-8 CSV-файл.

### 4.0

- История каждого шлюза за последние 24 часа хранится в `gateways.dat` рядом с EXE.
- При наведении на строку шлюза в tray-меню показывается график отклика.
- В работе учитывается до 15 включённых шлюзов; отключённые секции могут оставаться в INI в любом количестве.

Сборка x64 создаёт `gateways_v4.2_x64.exe`, сборка x86 — `gateways_v4.2_x86.exe`.

## English

### 4.2

- The interface is localized from `[LANG-XXX]` sections in `gateways.ini`.
- With `language=auto`, the section matching the three-letter Windows system-language code is selected, for example `RUS`.
- English is built in and is used when no matching translation exists.
- The tray menu has a Language submenu; the selection is stored in `Settings.language`.
- Existing configurations automatically receive complete `[LANG-ENG]` and `[LANG-RUS]` sections.

### 4.1

- The “Export database to CSV” command saves the last 24 hours of response history to a UTF-8 CSV file.

### 4.0

- Each gateway's last 24 hours of history is stored in `gateways.dat` beside the EXE.
- Hovering a gateway row in the tray menu shows a response-time chart.
- Up to 15 enabled gateways are monitored; any number of disabled sections may remain in the INI.

The x64 build is `gateways_v4.2_x64.exe`; the x86 build is `gateways_v4.2_x86.exe`.
