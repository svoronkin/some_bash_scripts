# Windows reinstall: backup & restore

Два PowerShell-скрипта, чтобы после чистой переустановки Windows 11 вернуть рабочий ПК к прежнему состоянию: программы, настройки, шрифты и WSL-дистрибутив целиком.

- `Backup-PC.ps1` — запускается **до** переустановки.
- `Restore-PC.ps1` — запускается **после** переустановки, от администратора.

Предполагается, что диск `D:` при переустановке не трогается: на нём лежат локальная копия бэкапа, игры и репозитории.

> В бэкапе в открытом виде лежат приватные SSH-ключи (Windows и внутри WSL), конфиги AmneziaVPN, токены приложений. Храните его только там, куда нет доступа у посторонних.

## Что сохраняется

| Группа | Что |
|--|--|
| WSL | дистрибутив целиком: `wsl --export <distro> <file>.vhdx --format vhd` (ключи, zsh/oh-my-zsh/p10k, brew, `~/.kube`, репозитории — всё внутри) |
| Списки | `winget export`, программы из реестра, appx, автозагрузка, пользовательский `PATH`, расширения Cursor/VS Code, `brew leaves` и `dnf --userinstalled` из WSL |
| `%USERPROFILE%` | `.ssh`, `.gitconfig`, `.wslconfig`, `.claude`, `.claude.json`, `.cursor` и `.vscode` (без `extensions`), `.vscode-shared`, `.copilot` |
| `%APPDATA%` | `Cursor\User`, `Code\User` (без `workspaceStorage`, `History`), `flameshot` |
| `%LOCALAPPDATA%` | Windows Terminal `settings.json`, PowerToys, AmneziaVPN, пользовательские шрифты (Nerd Fonts) |
| Реестр | AmneziaVPN, Flameshot, Soundpad, 7-Zip, `Explorer\Advanced`, `Keyboard Layout\Toggle` |
| Опционально | `-IncludeFirefox` (профиль), `-IncludeTelegram` (`tdata` без кэша), `-IncludeUserFolders` (Desktop, Documents, Downloads) |

Структура бэкапа:

```
D:\PCBackup\
├── Backup-PC.ps1
├── Restore-PC.ps1
└── 2026-10-09_1840\
    ├── files\HOME\...          -> %USERPROFILE%
    ├── files\APPDATA\...       -> %APPDATA%
    ├── files\LOCALAPPDATA\...  -> %LOCALAPPDATA%
    ├── reg\*.reg
    ├── lists\
    ├── wsl\AlmaLinux-10.vhdx, meta.json
    └── backup.log
```

## Бэкап

Закройте Cursor/VS Code (Remote-WSL), Firefox и Telegram. Скрипт сделает `wsl --shutdown` — все WSL-сессии закроются.

```powershell
powershell -ExecutionPolicy Bypass -File .\Backup-PC.ps1 -IncludeFirefox -IncludeTelegram -IncludeUserFolders
```

| Параметр | По умолчанию | Назначение |
|--|--|--|
| `-Dest` | `D:\PCBackup` | локальная папка бэкапов |
| `-Mirror` | из `mirror.txt` | вторая копия (NAS); `''` — не копировать |
| `-Distro` | `AlmaLinux-10` | имя WSL-дистрибутива |
| `-SkipWsl` | — | без экспорта WSL |

Бэкап собирается локально, затем копируется на `-Mirror` через `robocopy /J /A-:R`. Скрипты кладутся рядом с папками бэкапов.

Чтобы не передавать `-Mirror` каждый раз, положите рядом со скриптом `mirror.txt` с одной строкой — путём к сетевой папке (в git не коммитится, см. `.gitignore`):

```powershell
Set-Content D:\PCBackup\mirror.txt '\\nas\share\Backups\PC'
```

Если нет ни `-Mirror`, ни `mirror.txt`, бэкап остаётся только локальным.

## Восстановление

PowerShell **от администратора**:

```powershell
powershell -ExecutionPolicy Bypass -File D:\PCBackup\Restore-PC.ps1
```

Если скрипт попросит перезагрузку (включение WSL) — перезагрузитесь и запустите ещё раз. Повторный запуск безопасен: установленное пропускается.

| Параметр | По умолчанию | Назначение |
|--|--|--|
| `-From` | самый свежий `yyyy-MM-dd_HHmm` рядом со скриптом | конкретный бэкап |
| `-Distro` | `AlmaLinux-10` | имя WSL-дистрибутива |
| `-WslDir` | `D:\WSL\AlmaLinux-10` | куда положить `ext4.vhdx` |
| `-SkipApps`, `-SkipWsl`, `-SkipFiles` | — | пропустить этап |

По шагам:

1. Ставит программы через `winget` (список — в начале `Restore-PC.ps1`, правьте под себя).
2. Включает WSL (`wsl --install --no-distribution`), копирует `.vhdx` в `-WslDir` и подключает его `wsl --import-in-place`. Если в `-WslDir` уже есть `ext4.vhdx` (диск пережил переустановку на `D:`), подключает его без копирования. Выставляет `DefaultUid`, иначе WSL входит под root.
3. Копирует `files\*` обратно в профиль.
4. Регистрирует шрифты в `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`.
5. Импортирует `reg\*.reg`.
6. Ставит расширения Cursor/VS Code по спискам.
7. Печатает чек-лист ручных шагов: драйверы, Office, принтер, библиотека Steam, логины.

> Не ставьте тот же дистрибутив из Microsoft Store после восстановления: он зарегистрируется под тем же именем и будет конфликтовать с импортированным.

## Проверка экспорта WSL

Не трогая основной дистрибутив:

```powershell
wsl --import Alma-RestoreTest D:\WSL-test D:\PCBackup\<дата>\wsl\AlmaLinux-10.vhdx --vhd
wsl -d Alma-RestoreTest -u <user> --cd ~ -- ls -A ~/.ssh
wsl --unregister Alma-RestoreTest
```

## Известные грабли (учтены в скриптах)

| Симптом | Причина | Решение |
|--|--|--|
| `wsl --export` → `ERROR_SHARING_VIOLATION` | после `--terminate` VM ещё держит `ext4.vhdx` | `wsl --shutdown`, пауза, до 3 попыток |
| robocopy на Samba: `FAILED` на файлах с ReadOnly | после установки ReadOnly нельзя проставить время файла | `/A-:R` |
| `WSL ERROR: CreateProcessCommon: chdir(...) failed` | `wsl.exe` пытается зайти в текущую папку Windows | `wsl.exe --cd ~` |
| кириллица в выводе — кракозябры | Windows PowerShell 5.1 читает `.ps1` без BOM как ANSI | файлы сохранены в UTF-8 **с BOM**, сохраняйте так же |
