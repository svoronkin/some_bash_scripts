<#
    Бэкап настроек ПК перед переустановкой Windows.

    Запуск (обычная консоль, админ не нужен):
        powershell -ExecutionPolicy Bypass -File .\Backup-PC.ps1
        powershell -ExecutionPolicy Bypass -File .\Backup-PC.ps1 -IncludeFirefox -IncludeTelegram -IncludeUserFolders

    Результат: D:\PCBackup\<дата>\ + копия в <Mirror>\<дата>\ (скрипты кладутся рядом в обе папки)

    Вторая копия (NAS): -Mirror '\\nas\share\Backups\PC' или одна строка с путём в mirror.txt рядом со скриптом.
    Без того и другого копия делается только локально.

    Перед запуском закройте Cursor/VS Code (особенно Remote-WSL), Firefox и Telegram.
#>
param(
    [string]$Dest   = 'D:\PCBackup',   # локально: D: не трогается при переустановке
    [string]$Mirror,                   # вторая копия; по умолчанию — из mirror.txt рядом со скриптом
    [string]$Distro = 'AlmaLinux-10',
    [switch]$SkipWsl,
    [switch]$IncludeFirefox,      # профиль Firefox целиком (~430 MB) — не нужен, если пользуетесь Firefox Sync
    [switch]$IncludeTelegram,     # tdata без кэша медиа — сохраняет сессию (не придётся логиниться)
    [switch]$IncludeUserFolders   # Desktop, Documents, Downloads
)

$ErrorActionPreference = 'Continue'
$mirrorFile = Join-Path $PSScriptRoot 'mirror.txt'
if (-not $PSBoundParameters.ContainsKey('Mirror') -and (Test-Path $mirrorFile)) {
    $Mirror = (Get-Content $mirrorFile -TotalCount 1).Trim()
}
$Root = Join-Path $Dest (Get-Date -Format 'yyyy-MM-dd_HHmm')
New-Item -ItemType Directory -Force -Path $Root, "$Root\lists", "$Root\reg", "$Root\wsl" | Out-Null
Start-Transcript -Path "$Root\backup.log" | Out-Null

function Step($msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }

# Структура files\<ТОКЕН>\... зеркалит пути: HOME=%USERPROFILE%, APPDATA, LOCALAPPDATA.
# Restore-PC.ps1 просто копирует эти папки обратно.
function Backup-Dir {
    param([string]$Token, [string]$Rel, [string[]]$ExcludeDirs = @())
    $base = @{ HOME = $env:USERPROFILE; APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }[$Token]
    $src = Join-Path $base $Rel
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "нет, пропускаю: $src"; return }
    $dst = Join-Path "$Root\files\$Token" $Rel
    $rc = @($src, $dst, '/E', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeDirs) { $rc += '/XD'; $rc += $ExcludeDirs }
    & robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy код $LASTEXITCODE : $src" } else { Write-Host "  ok  $src" }
}

function Backup-File {
    param([string]$Token, [string]$Rel)
    $base = @{ HOME = $env:USERPROFILE; APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }[$Token]
    $src = Join-Path $base $Rel
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "нет, пропускаю: $src"; return }
    $dst = Join-Path "$Root\files\$Token" $Rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "  ok  $src"
}

# ---------------------------------------------------------------- списки
Step 'Списки программ и расширений'
winget export -o "$Root\lists\winget.json" --include-versions --accept-source-agreements | Out-Null
$uninst = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $uninst -EA 0 | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
    Sort-Object DisplayName -Unique | ForEach-Object { "$($_.DisplayName) | $($_.DisplayVersion) | $($_.Publisher)" } |
    Set-Content "$Root\lists\programs.txt" -Encoding UTF8
Get-AppxPackage | Where-Object { -not $_.IsFramework } | Select-Object -ExpandProperty Name |
    Set-Content "$Root\lists\appx.txt" -Encoding UTF8
Get-CimInstance Win32_StartupCommand | Select-Object Name, Command | Format-Table -AutoSize -Wrap | Out-String -Width 300 |
    Set-Content "$Root\lists\startup.txt" -Encoding UTF8
[Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Set-Content "$Root\lists\user-path.txt" -Encoding UTF8
if (Get-Command cursor -EA 0) { cursor --list-extensions | Set-Content "$Root\lists\cursor-extensions.txt" -Encoding UTF8 }
if (Get-Command code   -EA 0) { code   --list-extensions | Set-Content "$Root\lists\code-extensions.txt"   -Encoding UTF8 }

# ---------------------------------------------------------------- файлы профиля
Step 'Домашняя папка: ssh, git, wsl, claude, cursor, vscode'
Backup-Dir  HOME '.ssh'
Backup-File HOME '.gitconfig'
Backup-File HOME '.wslconfig'
Backup-File HOME '.claude.json'
Backup-Dir  HOME '.claude'
Backup-Dir  HOME '.cursor'        -ExcludeDirs 'extensions'
Backup-Dir  HOME '.vscode'        -ExcludeDirs 'extensions'
Backup-Dir  HOME '.vscode-shared'
Backup-Dir  HOME '.copilot'

Step 'Настройки приложений'
Backup-Dir APPDATA      'Cursor\User' -ExcludeDirs 'workspaceStorage', 'History'
Backup-Dir APPDATA      'Code\User'   -ExcludeDirs 'workspaceStorage', 'History'
Backup-Dir APPDATA      'flameshot'
Backup-Dir LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
Backup-Dir LOCALAPPDATA 'Microsoft\PowerToys' -ExcludeDirs 'Logs', 'Updates', 'Temp'
Backup-Dir LOCALAPPDATA 'AmneziaVPN.ORG'
Backup-Dir LOCALAPPDATA 'Microsoft\Windows\Fonts'   # Nerd Fonts для терминала / p10k

if ($IncludeFirefox) {
    Step 'Firefox'
    if (Get-Process firefox -EA 0) { Write-Warning 'Firefox запущен — закройте его, иначе профиль может скопироваться битым' }
    Backup-Dir APPDATA 'Mozilla\Firefox'
}
if ($IncludeTelegram) {
    Step 'Telegram (tdata без кэша)'
    if (Get-Process Telegram -EA 0) { Write-Warning 'Telegram запущен — закройте его' }
    Backup-Dir APPDATA 'Telegram Desktop\tdata' -ExcludeDirs 'user_data*', 'emoji', 'dumps', 'temp'
}
if ($IncludeUserFolders) {
    Step 'Desktop / Documents / Downloads'
    Backup-Dir HOME 'Desktop'
    Backup-Dir HOME 'Documents'
    Backup-Dir HOME 'Downloads'
}

# ---------------------------------------------------------------- установщики не из winget
# Restore-PC.ps1 ставит их тихо (таблица $offline там же). Добавляя сюда файл, добавьте и строку туда.
Step 'Установщики программ, которых нет в winget'
New-Item -ItemType Directory -Force -Path "$Root\installers" | Out-Null
$installers = @(
    "$env:USERPROFILE\Downloads\driveridentifier_setup.exe"   # DriverIdentifier (driveridentifier.com)
)
foreach ($f in $installers) {
    if (Test-Path $f) { Copy-Item $f "$Root\installers\" -Force; Write-Host "  ok  $f" }
    else { Write-Warning "нет установщика: $f — скачайте его заново, иначе после переустановки придётся ставить руками" }
}

# ---------------------------------------------------------------- реестр
Step 'Реестр'
$regKeys = @{
    'amnezia'          = 'HKCU\Software\AmneziaVPN.ORG'      # серверы/конфиги VPN
    'flameshot'        = 'HKCU\Software\flameshot-org'
    'soundpad'         = 'HKCU\Software\Leppsoft'
    '7zip'             = 'HKCU\Software\7-Zip'
    'explorer-adv'     = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    'kbd-toggle'       = 'HKCU\Keyboard Layout\Toggle'
}
foreach ($k in $regKeys.GetEnumerator()) {
    reg export $k.Value "$Root\reg\$($k.Key).reg" /y 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ok  $($k.Value)" } else { Write-Warning "нет ключа: $($k.Value)" }
}

# ---------------------------------------------------------------- WSL
if (-not $SkipWsl) {
    Step "WSL: $Distro"
    # --cd ~ : иначе WSL пытается зайти в текущую папку Windows и ругается, если её нет внутри
    $user = (wsl.exe -d $Distro --cd ~ -- whoami).Trim()
    # Справочные списки (на случай, если когда-то захочется собрать дистрибутив с нуля)
    wsl.exe -d $Distro --cd ~ -- bash -lc '/home/linuxbrew/.linuxbrew/bin/brew leaves 2>/dev/null' | Set-Content "$Root\lists\wsl-brew.txt" -Encoding UTF8
    wsl.exe -d $Distro --cd ~ -- bash -lc 'dnf repoquery --userinstalled --qf "%{name}\n" 2>/dev/null' | Set-Content "$Root\lists\wsl-dnf.txt" -Encoding UTF8

    @{ Distro = $Distro; DefaultUser = $user; Exported = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content "$Root\wsl\meta.json" -Encoding UTF8

    Write-Host "  останавливаю WSL и экспортирую $Distro в VHDX (несколько минут)..."
    $vhd = "$Root\wsl\$Distro.vhdx"
    # --terminate не всегда успевает отпустить ext4.vhdx (ERROR_SHARING_VIOLATION),
    # поэтому гасим всю виртуалку WSL и повторяем экспорт несколько раз.
    for ($try = 1; $try -le 3; $try++) {
        wsl.exe --shutdown | Out-Null
        Start-Sleep -Seconds (5 * $try)
        Remove-Item $vhd -Force -EA 0
        wsl.exe --export $Distro $vhd --format vhd
        if ($LASTEXITCODE -eq 0 -and (Test-Path $vhd)) { break }
        Write-Warning "  попытка $try не удалась, повторяю..."
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vhd)) {
        Write-Warning 'Экспорт WSL не удался! Проверьте лог.'
    } else {
        Write-Host ("  ok  {0} ({1:N1} GB)" -f $vhd, ((Get-Item $vhd).Length / 1GB)) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------- restore-скрипт рядом
if ((Resolve-Path $PSScriptRoot).Path.TrimEnd('\') -ne (Resolve-Path $Dest).Path.TrimEnd('\')) {
    Copy-Item (Join-Path $PSScriptRoot '*-PC.ps1') $Dest -Force
    if ((Test-Path $mirrorFile) -and -not (Test-Path (Join-Path $Dest 'mirror.txt'))) { Copy-Item $mirrorFile $Dest }
}

# -EA 0: в .claude\projects встречаются пути длиннее 260 символов
$size = (Get-ChildItem $Root -Recurse -File -Force -EA 0 | Measure-Object Length -Sum).Sum / 1GB
Stop-Transcript | Out-Null

# ---------------------------------------------------------------- копия на NAS
if ($Mirror) {
    Step "Копия на $Mirror"
    if (Test-Path $Mirror) {
        $stampName = Split-Path $Root -Leaf
        # /A-:R — снять ReadOnly: на Samba после него robocopy не может проставить время файла (ошибка 5)
        & robocopy $Root (Join-Path $Mirror $stampName) /E /R:2 /W:5 /NFL /NDL /NJH /NP /J /A-:R | Select-Object -Last 12
        if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy на NAS: код $LASTEXITCODE" }
        Copy-Item (Join-Path $Dest '*.ps1') $Mirror -Force
    } else {
        Write-Warning "$Mirror недоступен — копия осталась только в $Root"
    }
}

Step 'Готово'
Write-Host ("Бэкап: {0}  ({1:N1} GB)" -f $Root, $size) -ForegroundColor Green
if ($Mirror) { Write-Host "Копия: $Mirror\$(Split-Path $Root -Leaf)" -ForegroundColor Green }
Write-Host 'ВНИМАНИЕ: внутри приватные SSH-ключи, конфиги VPN и токены — не выкладывайте папку в облако без шифрования.' -ForegroundColor Yellow
