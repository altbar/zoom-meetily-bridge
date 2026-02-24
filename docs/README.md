# Zoom-Meetily Bridge

Автоматизация записи встреч: [Meetily](https://meetily.ai) начинает запись при входе в Zoom-встречу и останавливает при выходе.

## Компоненты

### ZoomMeetilyBridge (Swift)

Фоновый polling-демон (каждые 5 сек):
- Определяет активную Zoom-встречу по наличию окна (не "Zoom Workplace")
- При начале встречи — кликает "Start Recording" в меню Meetily (задержка 3 сек)
- При выходе из встречи — кликает "Stop Recording"
- State tracking: не дублирует клики
- Логи: `~/.claude/logs/zoom-meetily-bridge.log`

### patch-meetily.py

Бинарный патч Meetily для дефолтной транскрибации на русском языке.

**Проблема:** Meetily хранит языковую настройку только в памяти (`LazyLock<Mutex<String>>`), инициализируя её как `"auto-translate"`. При каждом перезапуске сбрасывается на auto-detect + перевод на английский.

**Решение:** Патч меняет 2 байта в ARM64-бинарнике:

| Что | До | После | Эффект |
|-----|-----|-------|--------|
| Строка | `auto-translate` | `ruto-translate` | Первый байт `'a'`→`'r'` |
| ARM64 MOV | `MOV W8, #14` | `MOV W8, #2` | Длина строки 14→2 |

Rust `String` теперь читает `"ru"` (2 байта) → Whisper транскрибирует на русском без перевода.

## Структура проекта

```
ZoomMeetilyBridge.swift    # Основной демон (Swift + NSAppleScript)
Info.plist                 # Bundle metadata для .app
com.altbar.zoom-meetily-bridge.plist  # LaunchAgent
patch-meetily.py           # Патч для русского языка
Makefile                   # build / install / restart
```

## Установка

### 1. Собрать и установить бридж

```bash
make install
```

Это:
- Компилирует Swift → `../scripts/ZoomMeetilyBridge.app`
- Копирует LaunchAgent в `~/Library/LaunchAgents/`
- Запускает сервис

### 2. Дать Accessibility-доступ

System Settings → Privacy & Security → Accessibility → `+` → выбрать `~/cldf/scripts/ZoomMeetilyBridge.app`

### 3. Патч языка (опционально)

```bash
python3 patch-meetily.py
```

Бэкап: `/Applications/meetily_pre_patch_backup.app`

## Управление

```bash
make restart    # Перезапуск сервиса
make uninstall  # Удалить LaunchAgent
```

Логи:
```bash
tail -f ~/.claude/logs/zoom-meetily-bridge.log
```

## Откат патча

```bash
pkill -f meetily
rm -rf /Applications/meetily.app
mv /Applications/meetily_pre_patch_backup.app /Applications/meetily.app
```

## Последние обновления

- **2026-02-24**: Первый релиз — бридж (Swift) + языковой патч
