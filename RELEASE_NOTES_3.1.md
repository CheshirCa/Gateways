# Gateway Monitor 3.1

## Русский

В версии 3.1 упрощён формат конфигурации. Секции `[Gateways]`, `[Gateway1]`, `[Gateway2]` и параметр `count` удалены. Теперь имя каждой секции одновременно является именем шлюза.

Старый вариант:

```ini
[Gateways]
count=1

[Gateway1]
name=Office
host=192.0.2.10
port=8291
```

Новый вариант:

```ini
[Office]
host=192.0.2.10
port=8291
```

Старый формат автоматически не преобразуется. Перед запуском версии 3.1 необходимо обновить `gateways.ini`.

Готовые сборки:

- `gateways_v3.1_x86.exe`;
- `gateways_v3.1_x64.exe`.

## English

Version 3.1 simplifies the configuration format. `[Gateways]`, `[Gateway1]`, `[Gateway2]`, and the `count` setting have been removed. Every section name is now also the gateway name.

Old format:

```ini
[Gateways]
count=1

[Gateway1]
name=Office
host=192.0.2.10
port=8291
```

New format:

```ini
[Office]
host=192.0.2.10
port=8291
```

The old format is not converted automatically. Update `gateways.ini` before running version 3.1.

Release binaries:

- `gateways_v3.1_x86.exe`;
- `gateways_v3.1_x64.exe`.
