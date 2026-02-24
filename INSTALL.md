# Установка Zoom-Meetily Bridge

Автоматическая запись Zoom-встреч через [Meetily](https://meetily.ai).
Когда вы заходите в Zoom-встречу — Meetily начинает запись. Выходите — запись останавливается. Всё автоматически.

Бонус: патч русского языка — Meetily будет транскрибировать на русском вместо перевода на английский.

## Что нужно заранее

- **macOS** (Apple Silicon или Intel)
- **Xcode Command Line Tools** — если не установлены:
  ```bash
  xcode-select --install
  ```
- **Meetily** — установлен в `/Applications/meetily.app` (скачать с [meetily.ai](https://meetily.ai))
- **Zoom** — установлен

## Установка (одна команда)

```bash
bash install.sh
```

Скрипт сделает всё сам:
1. Проверит что `swiftc` и `python3` доступны
2. Скомпилирует фоновый сервис → `~/Applications/ZoomMeetilyBridge.app`
3. Установит автозапуск при логине (LaunchAgent)
4. Пропатчит Meetily на русский язык (если Meetily установлен)
5. Откроет настройки macOS для следующего шага

## После установки: дать доступ (обязательно!)

Скрипт откроет System Settings автоматически. Нужно:

1. **System Settings** → **Privacy & Security** → **Accessibility**
2. Нажать **+** (может потребоваться разблокировка замком)
3. Перейти в `~/Applications/` и выбрать **ZoomMeetilyBridge.app**
4. Убедиться что галочка стоит

Без этого шага сервис не сможет управлять Meetily.

## Как проверить что работает

```bash
# Статус сервиса (должен показать PID и 0)
launchctl list | grep zoom-meetily

# Последние записи лога
tail -20 ~/.claude/logs/zoom-meetily-bridge.log
```

Зайдите в любую Zoom-встречу — через 3 секунды Meetily начнёт запись. При выходе — запись остановится.

## Управление

```bash
# Перезапустить сервис
launchctl unload ~/Library/LaunchAgents/com.altbar.zoom-meetily-bridge.plist
launchctl load ~/Library/LaunchAgents/com.altbar.zoom-meetily-bridge.plist

# Остановить сервис
launchctl unload ~/Library/LaunchAgents/com.altbar.zoom-meetily-bridge.plist

# Запустить сервис
launchctl load ~/Library/LaunchAgents/com.altbar.zoom-meetily-bridge.plist
```

## Повторная установка

Скрипт можно запускать повторно — он остановит старый сервис перед установкой нового.

```bash
bash install.sh
```

## Удаление

```bash
# Остановить и удалить LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.altbar.zoom-meetily-bridge.plist
rm ~/Library/LaunchAgents/com.altbar.zoom-meetily-bridge.plist

# Удалить приложение
rm -rf ~/Applications/ZoomMeetilyBridge.app

# Убрать из Accessibility (вручную)
# System Settings → Privacy & Security → Accessibility → выбрать → минус
```

## Откат языкового патча

Если нужно вернуть Meetily к английскому:

```bash
pkill -f meetily
rm -rf /Applications/meetily.app
mv /Applications/meetily_pre_patch_backup.app /Applications/meetily.app
```

## Решение проблем

**Сервис не запускается**
```bash
tail -50 ~/.claude/logs/zoom-meetily-bridge.log
tail -50 ~/.claude/logs/zoom-meetily-bridge-stderr.log
```

**"not allowed assistive access" в логах**
→ Не дан Accessibility-доступ. См. раздел "После установки" выше.

**Meetily не начинает запись при входе в Zoom**
→ Убедитесь что Meetily запущен (иконка в menu bar). Сервис не запускает Meetily сам — только управляет записью.

**Патч языка не применился**
→ Meetily не найден в `/Applications/meetily.app`. Установите Meetily и запустите `install.sh` повторно.
