# Stream Studio

Приложение для стриминга на YouTube с iPad (Swift Playgrounds). План — [docs/PLAN.md](docs/PLAN.md).

## Как открыть на iPad

**Вариант 1 — ZIP (проще):**
1. В Safari открой `https://github.com/djPtrvch/Stream-studio/archive/refs/heads/claude/fervent-brown-jwhr23.zip` (нужно быть залогиненым в GitHub).
2. В «Файлах» нажми на архив — он распакуется.
3. Открой папку `StreamStudio.swiftpm` — она откроется в Swift Playgrounds.

**Вариант 2 — Working Copy (удобно для обновлений):**
1. Установи Working Copy, клонируй `djPtrvch/Stream-studio`, переключись на ветку `claude/fervent-brown-jwhr23`.
2. В Swift Playgrounds: «Мои проекты» → «…» → открыть `StreamStudio.swiftpm` из папки Working Copy.
3. Обновления: в Working Copy — Pull.

## Запуск

- Кнопка ▶︎ в Playgrounds запускает приложение. Разрешить доступ к камере и микрофону.
- Поведение в фоне/Stage Manager точно проверяется только в сборке из TestFlight: App Settings → Team → «Загрузить в App Store Connect».

## Этап 0 (сейчас)

- Две камеры (A/B): встроенные + USB (Sony, Pixel 7 в режиме «Веб-камера»).
- Раскладки: `⌘1` A · `⌘2` B · `⌘3` A + b · `⌘4` B + a · `⌘5` A | B · `⌘S` поменять местами.
- Выбор микрофона из списка (без автопереключения на последнее подключённое), индикаторы по каналам.
- Диагностика (`⌘D`) → «Копировать отчёт» → вставить в чат.
