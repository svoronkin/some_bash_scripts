<#
    Back up PC settings before reinstalling Windows.

    Run (regular console, no admin needed):
        powershell -ExecutionPolicy Bypass -File .\Backup-PC.ps1
        powershell -ExecutionPolicy Bypass -File .\Backup-PC.ps1 -IncludeFirefox -IncludeTelegram -IncludeUserFolders

    Result: D:\PCBackup\<date>\ + a copy in <Mirror>\<date>\ (the scripts are placed next to both)

    Second copy (NAS): -Mirror '\\nas\share\Backups\PC' or a single line with the path in mirror.txt next to the script.
    Without either, the backup stays local only.

    Apps whose settings are copied (Cursor, VS Code, PowerToys, Flameshot, Firefox / Telegram with their switches)
    are closed first and started again at the end; -NoCloseApps turns this off. Claude and AmneziaVPN are left running.

    Keep this file ASCII-only: Windows PowerShell 5.1 prints anything else as '?' in many consoles.
#>
param(
    [string]$Dest   = 'D:\PCBackup',   # local: D: is not touched by the reinstall
    [string]$Mirror,                   # second copy; defaults to mirror.txt next to the script
    [string]$Distro,                   # WSL distro; empty: the default one
    [switch]$SkipWsl,
    [switch]$IncludeFirefox,      # whole Firefox profile (~430 MB); not needed with Firefox Sync
    [switch]$IncludeTelegram,     # tdata without media cache; keeps the session (no new login)
    [switch]$IncludeUserFolders,  # Desktop, Documents, Downloads
    [switch]$NoCloseApps          # do not close the apps whose settings are copied
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

# user, profile folders, WSL distro: collected once, saved for Restore-PC.ps1
. (Join-Path $PSScriptRoot 'PCContext.ps1')
$Ctx = Get-PCContext -Distro $Distro
$Distro = $Ctx.Distro
Save-PCContext $Ctx "$Root\context.json"
Step "Context: $($Ctx.UserName) on $($Ctx.Computer), profile $($Ctx.UserProfile), WSL $Distro ($($Ctx.WslUser))"
$Bases = @{ HOME = $Ctx.UserProfile; APPDATA = $Ctx.AppData; LOCALAPPDATA = $Ctx.LocalAppData }

# files\<TOKEN>\... mirrors the paths: HOME=%USERPROFILE%, APPDATA, LOCALAPPDATA.
# Restore-PC.ps1 copies these folders back into the profile of whoever runs it.
function Backup-Dir {
    param([string]$Token, [string]$Rel, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @())
    $base = $Bases[$Token]
    $src = Join-Path $base $Rel
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "missing, skipped: $src"; return }
    $dst = Join-Path "$Root\files\$Token" $Rel
    $rc = @($src, $dst, '/E', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeDirs)  { $rc += '/XD'; $rc += $ExcludeDirs }
    if ($ExcludeFiles) { $rc += '/XF'; $rc += $ExcludeFiles }
    & robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy exit code $LASTEXITCODE : $src" } else { Write-Host "  ok  $src" }
}

function Backup-File {
    param([string]$Token, [string]$Rel)
    $base = $Bases[$Token]
    $src = Join-Path $base $Rel
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "missing, skipped: $src"; return }
    $dst = Join-Path "$Root\files\$Token" $Rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "  ok  $src"
}

# ---------------------------------------------------------------- close apps
# Running apps keep files locked or half-written (PowerToys lock file, Firefox/Telegram databases).
# Close the window first (VS Code/Cursor keep unsaved files via hot exit, Firefox saves the session),
# kill what is still running after 15 s (Telegram only hides to the tray). Claude and AmneziaVPN stay:
# closing them would end this session / drop the VPN, and their files copy fine.
$closeNames = @('Cursor', 'Code', 'PowerToys*', 'flameshot')
if ($IncludeFirefox)  { $closeNames += 'firefox' }
if ($IncludeTelegram) { $closeNames += 'Telegram' }
$restart = @()
if (-not $NoCloseApps) {
    $procs = @($closeNames | ForEach-Object { Get-Process $_ -EA 0 } | Where-Object { $_.Id -ne $PID })
    if ($procs) {
        Step 'Closing apps whose settings are copied'
        # one entry per program (Cursor/Code/Firefox run many processes); PowerToys modules start with PowerToys itself
        $restart = @($procs | Where-Object { $_.Path -and $_.Name -notlike 'PowerToys.*' } |
                     Select-Object -ExpandProperty Path -Unique)
        $procs | ForEach-Object { [void]$_.CloseMainWindow() }
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and ($procs | Where-Object { -not $_.HasExited })) { Start-Sleep -Milliseconds 500 }
        $left = @($procs | Where-Object { -not $_.HasExited })
        $left | Stop-Process -Force -EA 0
        $procs | Select-Object -ExpandProperty Name -Unique | ForEach-Object { Write-Host "  closed  $_" }
        if ($left) { Write-Host "  killed after 15 s: $(($left | Select-Object -ExpandProperty Name -Unique) -join ', ')" }
    }
}

# ---------------------------------------------------------------- lists
Step 'Lists of programs and extensions'
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

# ---------------------------------------------------------------- profile files
Step 'Home folder: ssh, git, wsl, claude, cursor, vscode'
Backup-Dir  HOME '.ssh'
Backup-File HOME '.gitconfig'
Backup-File HOME '.wslconfig'
Backup-File HOME '.claude.json'
Backup-Dir  HOME '.claude'
Backup-Dir  HOME '.cursor'        -ExcludeDirs 'extensions'
Backup-Dir  HOME '.vscode'        -ExcludeDirs 'extensions'
Backup-Dir  HOME '.vscode-shared'
Backup-Dir  HOME '.copilot'

Step 'App settings'
Backup-Dir APPDATA      'Cursor\User' -ExcludeDirs 'workspaceStorage', 'History'
Backup-Dir APPDATA      'Code\User'   -ExcludeDirs 'workspaceStorage', 'History'
Backup-Dir APPDATA      'flameshot'
Backup-Dir LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
# settings.json.cli-lock is held open by a running PowerToys (robocopy exit code 9)
Backup-Dir LOCALAPPDATA 'Microsoft\PowerToys' -ExcludeDirs 'Logs', 'Updates', 'Temp' -ExcludeFiles '*.cli-lock'
Backup-Dir LOCALAPPDATA 'AmneziaVPN.ORG'
Backup-Dir LOCALAPPDATA 'Microsoft\Windows\Fonts'   # Nerd Fonts for the terminal / p10k
# Grafana dashboard on the 960x640 mini display (USB hub): launcher script + Startup shortcut.
# The Edge profile is not needed: sign in to Grafana once in that window after the restore.
# The shortcut is saved as JSON with %USERPROFILE%-style paths and recreated for the current user on restore.
Backup-Dir HOME 'NetMiniDisplay' -ExcludeDirs 'edge-profile'
Export-Shortcut (Join-Path $Ctx.Startup 'NetMiniDisplay.lnk') "$Root\shortcuts\NetMiniDisplay.json"

if ($IncludeFirefox) {
    Step 'Firefox'
    if (Get-Process firefox -EA 0) { Write-Warning 'Firefox is running: close it, otherwise the profile may be copied broken' }
    Backup-Dir APPDATA 'Mozilla\Firefox'
}
if ($IncludeTelegram) {
    Step 'Telegram (tdata without cache)'
    if (Get-Process Telegram -EA 0) { Write-Warning 'Telegram is running: close it' }
    Backup-Dir APPDATA 'Telegram Desktop\tdata' -ExcludeDirs 'user_data*', 'emoji', 'dumps', 'temp'
}
if ($IncludeUserFolders) {
    Step 'Desktop / Documents / Downloads'
    Backup-Dir HOME 'Desktop'
    Backup-Dir HOME 'Documents'
    Backup-Dir HOME 'Downloads'
}

# ---------------------------------------------------------------- installers not in winget
# Restore-PC.ps1 installs them silently (its $offline table). When adding a file here, add a line there too.
Step 'Installers of programs not in winget'
New-Item -ItemType Directory -Force -Path "$Root\installers" | Out-Null
$installers = @(
    (Join-Path $Ctx.Downloads 'driveridentifier_setup.exe')   # DriverIdentifier (driveridentifier.com)
)
foreach ($f in $installers) {
    if (Test-Path $f) { Copy-Item $f "$Root\installers\" -Force; Write-Host "  ok  $f" }
    else { Write-Warning "installer missing: $f - download it again, otherwise it has to be installed by hand after the reinstall" }
}

# ---------------------------------------------------------------- registry
Step 'Registry'
$regKeys = @{
    'amnezia'          = 'HKCU\Software\AmneziaVPN.ORG'      # VPN servers/configs
    'flameshot'        = 'HKCU\Software\flameshot-org'
    'soundpad'         = 'HKCU\Software\Leppsoft'
    '7zip'             = 'HKCU\Software\7-Zip'
    'explorer-adv'     = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    'kbd-toggle'       = 'HKCU\Keyboard Layout\Toggle'
}
foreach ($k in $regKeys.GetEnumerator()) {
    reg export $k.Value "$Root\reg\$($k.Key).reg" /y 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ok  $($k.Value)" } else { Write-Warning "key missing: $($k.Value)" }
}

# ---------------------------------------------------------------- WSL
if (-not $Distro -and -not $SkipWsl) { Write-Warning 'No WSL distro found - skipping the WSL export'; $SkipWsl = $true }
if (-not $SkipWsl) {
    Step "WSL: $Distro"
    $user = $Ctx.WslUser
    # --cd ~ : otherwise WSL tries to enter the current Windows folder and complains if it is missing inside
    # Reference lists (in case the distro ever has to be built from scratch)
    wsl.exe -d $Distro --cd ~ -- bash -lc '/home/linuxbrew/.linuxbrew/bin/brew leaves 2>/dev/null' | Set-Content "$Root\lists\wsl-brew.txt" -Encoding UTF8
    wsl.exe -d $Distro --cd ~ -- bash -lc 'dnf repoquery --userinstalled --qf "%{name}\n" 2>/dev/null' | Set-Content "$Root\lists\wsl-dnf.txt" -Encoding UTF8

    @{ Distro = $Distro; DefaultUser = $user; Exported = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content "$Root\wsl\meta.json" -Encoding UTF8

    Write-Host "  stopping WSL and exporting $Distro to VHDX (a few minutes)..."
    $vhd = "$Root\wsl\$Distro.vhdx"
    # --terminate does not always release ext4.vhdx in time (ERROR_SHARING_VIOLATION),
    # so shut down the whole WSL VM and retry the export a few times.
    for ($try = 1; $try -le 3; $try++) {
        wsl.exe --shutdown | Out-Null
        Start-Sleep -Seconds (5 * $try)
        Remove-Item $vhd -Force -EA 0
        wsl.exe --export $Distro $vhd --format vhd
        if ($LASTEXITCODE -eq 0 -and (Test-Path $vhd)) { break }
        Write-Warning "  attempt $try failed, retrying..."
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vhd)) {
        Write-Warning 'WSL export failed! See the log.'
    } else {
        Write-Host ("  ok  {0} ({1:N1} GB)" -f $vhd, ((Get-Item $vhd).Length / 1GB)) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------- restore script next to the backup
if ((Resolve-Path $PSScriptRoot).Path.TrimEnd('\') -ne (Resolve-Path $Dest).Path.TrimEnd('\')) {
    Copy-Item (Join-Path $PSScriptRoot '*-PC.ps1'), (Join-Path $PSScriptRoot 'PCContext.ps1') $Dest -Force
    if ((Test-Path $mirrorFile) -and -not (Test-Path (Join-Path $Dest 'mirror.txt'))) { Copy-Item $mirrorFile $Dest }
}

# -EA 0: .claude\projects has paths longer than 260 characters
$size = (Get-ChildItem $Root -Recurse -File -Force -EA 0 | Measure-Object Length -Sum).Sum / 1GB
Stop-Transcript | Out-Null

# ---------------------------------------------------------------- copy to the NAS
if ($Mirror) {
    Step "Copy to $Mirror"
    if (Test-Path $Mirror) {
        $stampName = Split-Path $Root -Leaf
        # Unbuffered copy (/J) of a ReadOnly file to Samba fails with error 5 even with /A-:R (the fonts are
        # ReadOnly), so clear ReadOnly in the local backup first; nothing in it needs the flag.
        Get-ChildItem $Root -Recurse -File -Force -EA 0 | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
        & robocopy $Root (Join-Path $Mirror $stampName) /E /R:2 /W:5 /NFL /NDL /NJH /NP /J /A-:R | Select-Object -Last 12
        if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy to the NAS: exit code $LASTEXITCODE" }
        Copy-Item (Join-Path $Dest '*.ps1') $Mirror -Force
    } else {
        Write-Warning "$Mirror is not reachable - the backup is only in $Root"
    }
}

if ($restart) {
    Step 'Starting the closed apps again'
    foreach ($exe in $restart) {
        if (Test-Path $exe) { Start-Process $exe; Write-Host "  started  $exe" }
    }
}

Step 'Done'
Write-Host ("Backup: {0}  ({1:N1} GB)" -f $Root, $size) -ForegroundColor Green
if ($Mirror) { Write-Host "Copy: $Mirror\$(Split-Path $Root -Leaf)" -ForegroundColor Green }
Write-Host 'WARNING: it contains private SSH keys, VPN configs and tokens - do not upload the folder to a cloud without encryption.' -ForegroundColor Yellow
