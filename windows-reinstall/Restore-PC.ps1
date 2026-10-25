<#
    Restore the PC after reinstalling Windows from a Backup-PC.ps1 backup.

    Run (PowerShell AS ADMINISTRATOR, under your own account):
        powershell -ExecutionPolicy Bypass -File D:\PCBackup\Restore-PC.ps1
    The script is idempotent: if it asks for a reboot (WSL), reboot and run it again.

    By default the newest backup next to the script is used (D:\PCBackup or the NAS folder).

    Keep this file ASCII-only: Windows PowerShell 5.1 prints anything else as '?' in many consoles.
#>
#Requires -RunAsAdministrator
param(
    [string]$From,                               # specific backup folder, e.g. D:\PCBackup\2026-10-09_1800
    [string]$Distro,                             # WSL distro; empty: the one from the backup (context.json)
    [string]$WslDir,                             # empty: D:\WSL\<distro> - lives on D: and survives the next reinstall
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
if (-not $From -or -not (Test-Path $From)) { throw "No backup found next to the script ($PSScriptRoot). Pass -From." }
Write-Host "Restoring from: $From" -ForegroundColor Green
Start-Transcript -Path "$env:TEMP\restore-pc-$(Get-Date -Format yyyyMMdd_HHmm).log" | Out-Null
$needReboot = $false

# context of the backed-up PC (user, profile, distro) vs the current one; older backups have only wsl\meta.json
. (Join-Path $PSScriptRoot 'PCContext.ps1')
$Old  = Read-PCContext (Join-Path $From 'context.json')
$Meta = Read-PCContext (Join-Path $From 'wsl\meta.json')
$Ctx  = Get-PCContext
if (-not $Distro) { $Distro = if ($Old.Distro) { $Old.Distro } else { $Meta.Distro } }
if (-not $WslDir -and $Distro) { $WslDir = "D:\WSL\$Distro" }
$WslUser = if ($Old.WslUser) { $Old.WslUser } else { $Meta.DefaultUser }
Write-Host "Backup of: $($Old.UserName) on $($Old.Computer), profile $($Old.UserProfile)"
Write-Host "Restoring to: $($Ctx.UserName) on $($Ctx.Computer), profile $($Ctx.UserProfile)"
$profileMoved = $Old.UserProfile -and ($Old.UserProfile -ne $Ctx.UserProfile)

# ---------------------------------------------------------------- programs
# The list was collected from the current system. Drivers, Office and others without winget are in the checklist at the end.
$apps = @(
    # system / utilities
    '7zip.7zip', 'Microsoft.PowerToys', 'Microsoft.WindowsTerminal', 'Flameshot.Flameshot',
    'bluemars.ClipX', 'namazso.PawnIO', 'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86',
    # network / security
    'Cloudflare.Warp', 'AmneziaVPN.AmneziaVPN', 'Bitwarden.Bitwarden',
    # development
    'Git.Git', 'GitHub.cli', 'Hashicorp.Terraform', 'Python.Python.3.14', 'Python.Launcher',
    'Microsoft.VisualStudioCode', 'Anysphere.Cursor', 'Anthropic.Claude',
    # chat / browser / games / peripherals
    'Telegram.TelegramDesktop', 'Discord.Discord', 'Mozilla.Firefox', 'Valve.Steam', 'Logitech.OptionsPlus'
)

if (-not $SkipApps) {
    Step 'Installing programs with winget'
    if (-not (Get-Command winget -EA 0)) {
        Write-Warning 'winget not found. Update "App Installer" in the Microsoft Store and run the script again.'
    } else {
        winget source update | Out-Null
        foreach ($id in $apps) {
            Write-Host "-> $id"
            winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity |
                Select-Object -Last 1
        }
        # refresh PATH of the current session to see git/code/cursor
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    # Programs not in winget: the installers are in <backup>\installers\
    Step 'Installing programs not in winget'
    $offline = @(
        @{ Name  = 'DriverIdentifier'
           File  = 'driveridentifier_setup.exe'
           Args  = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'          # Inno Setup
           Check = "${env:ProgramFiles(x86)}\Driver Identifier\DriverIdentifier.exe" }
    )
    foreach ($app in $offline) {
        if (Test-Path $app.Check) { Write-Host "  $($app.Name) is already installed"; continue }
        $exe = Join-Path $From "installers\$($app.File)"
        if (-not (Test-Path $exe)) { Write-Warning "$($app.Name): $exe is missing - install it by hand"; continue }
        Write-Host "-> $($app.Name)"
        $p = Start-Process $exe -ArgumentList $app.Args -Wait -PassThru
        if ($p.ExitCode -eq 0 -and (Test-Path $app.Check)) { Write-Host "  ok  $($app.Name)" }
        else { Write-Warning "$($app.Name): installer returned exit code $($p.ExitCode)" }
    }
}

# ---------------------------------------------------------------- WSL
function Test-DistroRegistered($name) {
    Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss -EA 0 |
        Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $name }
}

if (-not $Distro -and -not $SkipWsl) { Write-Warning 'The backup names no WSL distro - pass -Distro; skipping WSL'; $SkipWsl = $true }
if (-not $SkipWsl) {
    Step "WSL: $Distro"
    wsl.exe --status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  WSL is not installed - installing the platform...'
        wsl.exe --install --no-distribution
        $needReboot = $true
    }

    if ($needReboot) {
        Write-Warning 'WSL needs a reboot. After it, run the script again (already installed parts are skipped).'
    } elseif (Test-DistroRegistered $Distro) {
        Write-Host "  $Distro is already registered - skipping the import."
    } else {
        $target = Join-Path $WslDir 'ext4.vhdx'
        if (Test-Path $target) {
            Write-Host "  found existing disk $target - attaching it as is"
        } else {
            $src = Join-Path $From "wsl\$Distro.vhdx"
            if (-not (Test-Path $src)) { Write-Warning "$src is missing"; $src = $null }
            if ($src) {
                New-Item -ItemType Directory -Force -Path $WslDir | Out-Null
                Write-Host "  copying VHDX to $target ..."
                Copy-Item $src $target
            }
        }
        if (Test-Path $target) {
            wsl.exe --import-in-place $Distro $target
            if (Test-DistroRegistered $Distro) {
                # default user (after the import WSL logs in as root)
                $uid = if ($WslUser) { (wsl.exe -d $Distro -u root --cd ~ -- id -u $WslUser | Out-String).Trim() }
                if ($uid -match '^\d+$') {
                    $key = (Test-DistroRegistered $Distro).PSPath
                    Set-ItemProperty $key -Name DefaultUid -Value ([int]$uid) -Type DWord
                    Write-Host "  default user: $WslUser (uid $uid)"
                } else {
                    Write-Warning "WSL user from the backup ('$WslUser') not found - WSL will log in as root"
                }
                wsl.exe --set-default $Distro
                wsl.exe --terminate $Distro | Out-Null
                Write-Host "  ok  $Distro imported" -ForegroundColor Green
            } else {
                Write-Warning 'WSL import failed - see the log.'
            }
        }
    }
}

# ---------------------------------------------------------------- files
if (-not $SkipFiles) {
    Step 'Restoring settings files'
    # close what keeps its settings open
    'PowerToys*', 'Telegram', 'firefox', 'Cursor', 'Code', 'flameshot', 'AmneziaVPN', 'WindowsTerminal', 'Claude' |
        ForEach-Object { Get-Process $_ -EA 0 } | Where-Object { $_.Id -ne $PID } | Stop-Process -Force -EA 0

    $map = @{ HOME = $Ctx.UserProfile; APPDATA = $Ctx.AppData; LOCALAPPDATA = $Ctx.LocalAppData }
    $restored = @()
    foreach ($token in $map.Keys) {
        $src = Join-Path $From "files\$token"
        if (Test-Path $src) {
            & robocopy $src $map[$token] /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy $token exit code $LASTEXITCODE" } else { Write-Host "  ok  $token -> $($map[$token])" }
            # only what came from the backup, not the whole profile
            $restored += Get-ChildItem $src -Force | ForEach-Object { Join-Path $map[$token] $_.Name }
        }
    }
    if ($profileMoved) {
        Step 'Moving user paths in restored configs to the new profile'
        # top level only for HOME: Desktop/Documents/Downloads are user data, not configs
        $restored = $restored | Where-Object { (Split-Path $_ -Leaf) -notin 'Desktop', 'Documents', 'Downloads' }
        Update-UserPaths -Paths $restored -OldProfile $Old.UserProfile -NewProfile $Ctx.UserProfile
    }

    Step 'Shortcuts'
    Get-ChildItem (Join-Path $From 'shortcuts') -Filter *.json -EA 0 | ForEach-Object { Import-Shortcut $_.FullName }

    Step 'Registering fonts (Nerd Fonts)'
    $fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $fontReg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $fontReg)) { New-Item $fontReg -Force | Out-Null }
    Get-ChildItem $fontDir -Include *.ttf, *.otf -Recurse -EA 0 | ForEach-Object {
        $type = if ($_.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
        Set-ItemProperty $fontReg -Name "$($_.BaseName) ($type)" -Value $_.FullName
        Write-Host "  $($_.Name)"
    }

    Step 'Importing the registry'
    $regDir = Join-Path $From 'reg'
    if ($profileMoved -and (Test-Path $regDir)) {
        # fix user paths in a temp copy, the backup itself stays untouched
        $tmpReg = Join-Path $env:TEMP 'restore-pc-reg'
        Remove-Item $tmpReg -Recurse -Force -EA 0
        Copy-Item $regDir $tmpReg -Recurse
        Update-UserPaths -Paths $tmpReg -OldProfile $Old.UserProfile -NewProfile $Ctx.UserProfile
        $regDir = $tmpReg
    }
    Get-ChildItem $regDir -Filter *.reg -EA 0 | ForEach-Object {
        reg import $_.FullName 2>$null
        Write-Host "  $($_.Name)"
    }

    Step 'Editor extensions'
    foreach ($ed in 'cursor', 'code') {
        $list = Join-Path $From "lists\$ed-extensions.txt"
        if ((Test-Path $list) -and (Get-Command $ed -EA 0)) {
            Get-Content $list | Where-Object { $_.Trim() } | ForEach-Object { & $ed --install-extension $_ --force | Out-Null; Write-Host "  $ed : $_" }
        }
    }
}

Stop-Transcript | Out-Null

# ---------------------------------------------------------------- checklist
Step 'Left to do by hand'
@'
 [ ] Drivers: AMD Chipset Software (amd.com/support) and NVIDIA App + driver (nvidia.com/apps)
 [ ] Microsoft Office 2016 Pro Plus - from your own installer/key
 [ ] Printer RICOH SP 150SU - driver from ricoh.com
 [ ] Steam: Settings -> Storage -> add D:\SteamLibrary (Soundpad, Teardown etc. are there too)
 [ ] Games outside Steam in D:\Games (Tarkov - BSG Launcher, S.T.A.L.K.E.R. 2 etc.) - install the launchers and point them to the folder
 [ ] Sign in: Bitwarden, Firefox Sync (if the profile was not backed up), Telegram, Discord, Cloudflare WARP, Logi Options+ (mouse settings come from the Logi cloud), GitHub CLI (gh auth login), Claude, Cursor
 [ ] AmneziaVPN: check that the servers came back from the registry; if not, import the config again
 [ ] Windows Terminal: the "Alma" profile (default) comes back by itself - its GUID depends on the distro name
 [ ] Startup: ClipX, Flameshot etc. - enable it in the programs themselves if it did not come back
 [ ] Mini display: sign out and in, the Grafana window opens by itself (NetMiniDisplay.lnk) - sign in to Grafana in that window once
 [ ] Do NOT install AlmaLinux from the Microsoft Store - its name conflicts with the imported one
'@ | Write-Host

if ($needReboot) { Write-Host "`nREBOOT and run the script again to import WSL." -ForegroundColor Yellow }
