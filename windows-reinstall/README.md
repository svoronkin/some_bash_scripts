# Windows reinstall: backup & restore

Two PowerShell scripts that bring a working PC back to its previous state after a clean Windows 11 reinstall: programs, settings, fonts and the whole WSL distro.

- `Backup-PC.ps1` runs **before** the reinstall.
- `Restore-PC.ps1` runs **after** the reinstall, as administrator.
- `PCContext.ps1` is a helper both scripts load; keep it next to them.

Nothing is tied to a user name. At the start `Get-PCContext` collects the user, profile folders (`%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`, Downloads, Startup), the default WSL distro and its user. The backup saves this to `context.json`. The restore compares it with the current PC: files go to the profile of whoever runs it, and if the profile folder changed (another user name), old paths in the restored text configs and `.reg` files are replaced with the new ones (`C:\Users\old`, `C:\\Users\\old`, `C:/Users/old`, `/mnt/c/Users/old`; each file keeps its encoding). Shortcuts are saved as JSON with `%USERPROFILE%`-style paths and recreated for the current user.

Drive `D:` is assumed to survive the reinstall: it holds the local copy of the backup, games and repositories.

> The backup contains private SSH keys (Windows and inside WSL), AmneziaVPN configs and app tokens in plain form. Keep it only where nobody else has access.

## What is saved

| Group | What |
|--|--|
| WSL | the whole distro: `wsl --export <distro> <file>.vhdx --format vhd` (keys, zsh/oh-my-zsh/p10k, brew, `~/.kube`, repositories - everything inside) |
| Lists | `winget export`, programs from the registry, appx, startup items, user `PATH`, Cursor/VS Code extensions, `brew leaves` and `dnf --userinstalled` from WSL |
| `%USERPROFILE%` | `.ssh`, `.gitconfig`, `.wslconfig`, `.claude`, `.claude.json`, `.cursor` and `.vscode` (without `extensions`), `.vscode-shared`, `.copilot`, `NetMiniDisplay` (launcher of the Grafana window on the mini display, without `edge-profile`) |
| `%APPDATA%` | `Cursor\User`, `Code\User` (without `workspaceStorage`, `History`), `flameshot` |
| Shortcuts | Startup shortcut `NetMiniDisplay.lnk` (as `shortcuts\*.json`) |
| Context | `context.json`: user, computer, profile folders, WSL distro and user |
| `%LOCALAPPDATA%` | Windows Terminal `settings.json`, PowerToys, AmneziaVPN, user fonts (Nerd Fonts) |
| Registry | AmneziaVPN, Flameshot, Soundpad, 7-Zip, `Explorer\Advanced`, `Keyboard Layout\Toggle` |
| Installers | programs not in winget (currently DriverIdentifier) - the `$installers` list in `Backup-PC.ps1` |
| Optional | `-IncludeFirefox` (profile), `-IncludeTelegram` (`tdata` without cache), `-IncludeUserFolders` (Desktop, Documents, Downloads) |

Backup layout:

```
D:\PCBackup\
├── Backup-PC.ps1
├── Restore-PC.ps1
├── PCContext.ps1
└── 2026-10-09_1840\
    ├── context.json
    ├── files\HOME\...          -> %USERPROFILE%
    ├── files\APPDATA\...       -> %APPDATA%
    ├── files\LOCALAPPDATA\...  -> %LOCALAPPDATA%
    ├── shortcuts\*.json
    ├── reg\*.reg
    ├── installers\
    ├── lists\
    ├── wsl\AlmaLinux-10.vhdx, meta.json
    └── backup.log
```

## Backup

```powershell
powershell -ExecutionPolicy Bypass -File .\Backup-PC.ps1 -IncludeFirefox -IncludeTelegram -IncludeUserFolders
```

The script closes the apps whose settings it copies: Cursor, VS Code, PowerToys, Flameshot, plus Firefox and Telegram with `-IncludeFirefox` / `-IncludeTelegram`. It closes their windows first (VS Code/Cursor keep unsaved files via hot exit, Firefox saves the session), kills what is still running after 15 s and starts them all again at the end. Claude and AmneziaVPN are left running: closing them would end the Claude session / drop the VPN, and their files copy fine. The script also runs `wsl --shutdown`, so all WSL sessions close.

| Parameter | Default | Purpose |
|--|--|--|
| `-Dest` | `D:\PCBackup` | local backup folder |
| `-Mirror` | from `mirror.txt` | second copy (NAS); `''` - no copy |
| `-Distro` | the default WSL distro | WSL distro name |
| `-SkipWsl` | - | no WSL export |
| `-NoCloseApps` | - | do not close the apps (close them yourself) |

The backup is built locally, then copied to `-Mirror` with `robocopy /J /A-:R`. The scripts are placed next to the backup folders.

To avoid passing `-Mirror` every time, put `mirror.txt` with one line - the network folder path - next to the script (not committed, see `.gitignore`):

```powershell
Set-Content D:\PCBackup\mirror.txt '\\nas\share\Backups\PC'
```

With neither `-Mirror` nor `mirror.txt` the backup stays local only.

## Restore

PowerShell **as administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File D:\PCBackup\Restore-PC.ps1
```

If the script asks for a reboot (enabling WSL), reboot and run it again. Running it again is safe: installed parts are skipped.

| Parameter | Default | Purpose |
|--|--|--|
| `-From` | newest `yyyy-MM-dd_HHmm` next to the script | specific backup |
| `-Distro` | from `context.json` of the backup | WSL distro name |
| `-WslDir` | `D:\WSL\<distro>` | where to put `ext4.vhdx` |
| `-SkipApps`, `-SkipWsl`, `-SkipFiles` | - | skip a stage |

Step by step:

1. Installs programs with `winget` (the list is at the top of `Restore-PC.ps1`, adjust it), then silently installs programs not in winget from `installers\` (the `$offline` table: file, silent install switches, path for the "already installed" check). A new installer is added in two places: `$installers` in `Backup-PC.ps1` and `$offline` in `Restore-PC.ps1`.
2. Enables WSL (`wsl --install --no-distribution`), copies the `.vhdx` to `-WslDir` and attaches it with `wsl --import-in-place`. If `-WslDir` already has `ext4.vhdx` (the disk survived the reinstall on `D:`), attaches it without copying. Sets `DefaultUid` of the WSL user from the backup, otherwise WSL logs in as root.
3. Copies `files\*` back into the current profile; if the profile folder changed, moves user paths in the restored configs. Recreates shortcuts from `shortcuts\*.json`.
4. Registers fonts in `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`.
5. Imports `reg\*.reg` (with user paths moved in a temp copy if the profile folder changed).
6. Installs Cursor/VS Code extensions from the lists.
7. Prints a checklist of manual steps: drivers, Office, printer, Steam library, sign-ins.

> Do not install the same distro from the Microsoft Store after the restore: it registers under the same name and conflicts with the imported one.

## Checking the WSL export

Without touching the main distro:

```powershell
wsl --import Alma-RestoreTest D:\WSL-test D:\PCBackup\<date>\wsl\AlmaLinux-10.vhdx --vhd
wsl -d Alma-RestoreTest -u <user> --cd ~ -- ls -A ~/.ssh
wsl --unregister Alma-RestoreTest
```

## Known pitfalls (handled in the scripts)

| Symptom | Cause | Fix |
|--|--|--|
| `wsl --export` -> `ERROR_SHARING_VIOLATION` | after `--terminate` the VM still holds `ext4.vhdx` | `wsl --shutdown`, pause, up to 3 attempts |
| robocopy to Samba: `FAILED` on ReadOnly files | the file time cannot be set once ReadOnly is set | `/A-:R` |
| `WSL ERROR: CreateProcessCommon: chdir(...) failed` | `wsl.exe` tries to enter the current Windows folder | `wsl.exe --cd ~` |
| robocopy exit code 9 on PowerToys | `settings.json.cli-lock` is held open by PowerToys | PowerToys is closed first; `*.cli-lock` is excluded |
| `?????` instead of text in the console | Windows PowerShell 5.1 cannot print non-ASCII text in many consoles, BOM or not | the scripts are ASCII-only, keep them so |
| a folder created by an app in `%LOCALAPPDATA%` is "missing" for the backup | packaged (MSIX) apps such as Claude get new AppData folders redirected to `%LOCALAPPDATA%\Packages\<app>\LocalCache` | keep such files outside AppData (e.g. `%USERPROFILE%\NetMiniDisplay`) |
