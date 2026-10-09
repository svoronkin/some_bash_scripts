<#
    Восстановление ПК после переустановки Windows из бэкапа Backup-PC.ps1.

    Запуск (PowerShell ОТ АДМИНИСТРАТОРА, под своей учёткой):
        powershell -ExecutionPolicy Bypass -File D:\PCBackup\Restore-PC.ps1
    Скрипт идемпотентный: если попросит перезагрузку (WSL) — перезагрузитесь и запустите ещё раз.

    По умолчанию берётся самый свежий бэкап рядом со скриптом (D:\PCBackup или папка на NAS).
#>
#Requires -RunAsAdministrator
param(
    [string]$From,                               # конкретная папка бэкапа, напр. D:\PCBackup\2026-10-09_1800
    [string]$Distro = 'AlmaLinux-10',
    [string]$WslDir = 'D:\WSL\AlmaLinux-10',     # диск WSL теперь живёт на D: — переживёт следующую переустановку
    [switch]$SkipApps,
    [switch]$SkipWsl,
    [switch]$SkipFiles
)

$ErrorActionPreference = 'Continue'
function Step($msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }

if (-not $From) {
    $From = Get-ChildItem $PSScriptRoot -Directory | Where-Object Name -match '^\d{4}-\d{2}-\d{2}_\d{4}$' |
            Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $From -or -not (Test-Path $From)) { throw "Не найден бэкап рядом со скриптом ($PSScriptRoot). Укажите -From." }
Write-Host "Восстанавливаю из: $From" -ForegroundColor Green
Start-Transcript -Path "$env:TEMP\restore-pc-$(Get-Date -Format yyyyMMdd_HHmm).log" | Out-Null
$needReboot = $false

# ---------------------------------------------------------------- программы
# Список собран из текущей системы. Драйверы, Office и прочее без winget — в чек-листе в конце.
$apps = @(
    # система / утилиты
    '7zip.7zip', 'Microsoft.PowerToys', 'Microsoft.WindowsTerminal', 'Flameshot.Flameshot',
    'bluemars.ClipX', 'namazso.PawnIO', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86',
    # сеть / безопасность
    'Cloudflare.Warp', 'AmneziaVPN.AmneziaVPN', 'Bitwarden.Bitwarden',
    # разработка
    'Git.Git', 'GitHub.cli', 'Hashicorp.Terraform', 'Python.Python.3.14', 'Python.Launcher',
    'Microsoft.VisualStudioCode', 'Anysphere.Cursor', 'Anthropic.Claude',
    # общение / браузер / игры / периферия
    'Telegram.TelegramDesktop', 'Discord.Discord', 'Mozilla.Firefox', 'Valve.Steam', 'Logitech.OptionsPlus'
)

if (-not $SkipApps) {
    Step 'Установка программ через winget'
    if (-not (Get-Command winget -EA 0)) {
        Write-Warning 'winget не найден. Обновите "App Installer" в Microsoft Store и запустите скрипт снова.'
    } else {
        winget source update | Out-Null
        foreach ($id in $apps) {
            Write-Host "-> $id"
            winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity |
                Select-Object -Last 1
        }
        # обновить PATH текущей сессии, чтобы увидеть git/code/cursor
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
}

# ---------------------------------------------------------------- WSL
function Test-DistroRegistered($name) {
    Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -EA 0 |
        Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name }
}

if (-not $SkipWsl) {
    Step "WSL: $Distro"
    wsl.exe --status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  WSL не установлен — ставлю платформу...'
        wsl.exe --install --no-distribution
        $needReboot = $true
    }

    if ($needReboot) {
        Write-Warning 'Нужна перезагрузка для WSL. После неё запустите скрипт ещё раз (повторно уже установленное пропустится).'
    } elseif (Test-DistroRegistered $Distro) {
        Write-Host "  $Distro уже зарегистрирован — пропускаю импорт."
    } else {
        $target = Join-Path $WslDir 'ext4.vhdx'
        if (Test-Path $target) {
            Write-Host "  найден существующий диск $target — подключаю его как есть"
        } else {
            $src = Join-Path $From "wsl\$Distro.vhdx"
            if (-not (Test-Path $src)) { Write-Warning "Нет $src"; $src = $null }
            if ($src) {
                New-Item -ItemType Directory -Force -Path $WslDir | Out-Null
                Write-Host "  копирую VHDX в $target ..."
                Copy-Item $src $target
            }
        }
        if (Test-Path $target) {
            wsl.exe --import-in-place $Distro $target
            if (Test-DistroRegistered $Distro) {
                # пользователь по умолчанию (после импорта WSL заходит под root)
                $meta = Get-Content (Join-Path $From 'wsl\meta.json') -Raw -EA 0 | ConvertFrom-Json
                $user = if ($meta.DefaultUser) { $meta.DefaultUser } else { 'svoronkin' }
                $uid  = (wsl.exe -d $Distro -u root --cd ~ -- id -u $user).Trim()
                if ($uid -match '^\d+$') {
                    $key = (Test-DistroRegistered $Distro).PSPath
                    Set-ItemProperty $key -Name DefaultUid -Value ([int]$uid) -Type DWord
                    Write-Host "  пользователь по умолчанию: $user (uid $uid)"
                }
                wsl.exe --set-default $Distro
                wsl.exe --terminate $Distro | Out-Null
                Write-Host "  ok  $Distro импортирован" -ForegroundColor Green
            } else {
                Write-Warning 'Импорт WSL не удался — см. лог.'
            }
        }
    }
}

# ---------------------------------------------------------------- файлы
if (-not $SkipFiles) {
    Step 'Восстановление файлов настроек'
    # закрыть то, что держит свои настройки открытыми
    'PowerToys*', 'Telegram', 'firefox', 'Cursor', 'Code', 'flameshot', 'AmneziaVPN', 'WindowsTerminal', 'Claude' |
        ForEach-Object { Get-Process $_ -EA 0 } | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -EA 0

    $map = @{ HOME = $env:USERPROFILE; APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }
    foreach ($token in $map.Keys) {
        $src = Join-Path $From "files\$token"
        if (Test-Path $src) {
            & robocopy $src $map[$token] /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy $token код $LASTEXITCODE" } else { Write-Host "  ok  $token -> $($map[$token])" }
        }
    }

    Step 'Регистрация шрифтов (Nerd Fonts)'
    $fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $fontReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $fontReg)) { New-Item $fontReg -Force | Out-Null }
    Get-ChildItem $fontDir -Include *.ttf, *.otf -Recurse -EA 0 | ForEach-Object {
        $type = if ($_.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
        Set-ItemProperty $fontReg -Name "$($_.BaseName) ($type)" -Value $_.FullName
        Write-Host "  $($_.Name)"
    }

    Step 'Импорт реестра'
    Get-ChildItem (Join-Path $From 'reg') -Filter *.reg -EA 0 | ForEach-Object {
        reg import $_.FullName 2>$null
        Write-Host "  $($_.Name)"
    }

    Step 'Расширения редакторов'
    foreach ($ed in 'cursor', 'code') {
        $list = Join-Path $From "lists\$ed-extensions.txt"
        if ((Test-Path $list) -and (Get-Command $ed -EA 0)) {
            Get-Content $list | Where-Object { $_.Trim() } | ForEach-Object { & $ed --install-extension $_ --force | Out-Null; Write-Host "  $ed : $_" }
        }
    }
}

Stop-Transcript | Out-Null

# ---------------------------------------------------------------- чек-лист
Step 'Осталось сделать руками'
@'
 [ ] Драйверы: AMD Chipset Software (amd.com/support) и NVIDIA App + драйвер (nvidia.com/apps)
 [ ] Microsoft Office 2016 Pro Plus — со своего дистрибутива/ключа
 [ ] Принтер RICOH SP 150SU — драйвер с ricoh.com
 [ ] Steam: Настройки -> Хранилище -> добавить D:\SteamLibrary (Soundpad, Teardown и др. — оттуда же)
 [ ] Игры вне Steam в D:\Games (Tarkov — BSG Launcher, S.T.A.L.K.E.R. 2 и т.п.) — поставить лаунчеры и указать папку
 [ ] Войти: Bitwarden, Firefox Sync (если профиль не бэкапился), Telegram, Discord, Cloudflare WARP, Logi Options+ (настройки мыши — из облака Logi), GitHub CLI (gh auth login), Claude, Cursor
 [ ] AmneziaVPN: проверить, что серверы подтянулись из реестра; если нет — импортировать конфиг заново
 [ ] Windows Terminal: профиль "Alma" (по умолчанию) вернётся сам — его GUID зависит от имени дистрибутива
 [ ] Автозагрузка: ClipX, Flameshot и пр. — включить в самих программах, если не включились
 [ ] Магазинную версию AlmaLinux из Microsoft Store НЕ ставить — будет конфликт имени с импортированной
'@ | Write-Host

if ($needReboot) { Write-Host "`nПЕРЕЗАГРУЗИТЕСЬ и запустите скрипт ещё раз для импорта WSL." -ForegroundColor Yellow }
