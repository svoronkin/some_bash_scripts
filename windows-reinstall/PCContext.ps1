<#
    Shared helpers for Backup-PC.ps1 and Restore-PC.ps1 (dot-sourced by both).

    Get-PCContext collects everything that depends on the user and the machine (user name, profile folders,
    Downloads, Startup, default WSL distro and its user), so the scripts hardcode no user names or paths.
    The backup saves it to context.json; the restore compares it with the current one and moves user paths
    in restored config files from the old profile folder to the new one.

    Keep this file ASCII-only: Windows PowerShell 5.1 prints anything else as '?' in many consoles.
#>

function Get-DefaultWslDistro {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $guid = (Get-ItemProperty $lxss -EA 0).DefaultDistribution
    if ($guid) { (Get-ItemProperty (Join-Path $lxss $guid) -EA 0).DistributionName }
}

function Get-PCContext {
    param([string]$Distro)   # empty: the default WSL distro
    if (-not $Distro) { $Distro = Get-DefaultWslDistro }
    $wslUser = $null
    if ($Distro -and (Get-Command wsl.exe -EA 0)) {
        # --cd ~ : otherwise WSL tries to enter the current Windows folder and complains if it is missing inside
        $wslUser = (wsl.exe -d $Distro --cd ~ -- whoami 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $wslUser = $null }
    }
    [ordered]@{
        Computer     = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        UserProfile  = $env:USERPROFILE
        AppData      = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
        Downloads    = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        Startup      = [Environment]::GetFolderPath('Startup')
        Distro       = $Distro
        WslUser      = $wslUser
        Created      = (Get-Date).ToString('s')
    }
}

function Save-PCContext($Context, [string]$Path) {
    $Context | ConvertTo-Json | Set-Content $Path -Encoding UTF8
}

function Read-PCContext([string]$Path) {
    if (Test-Path $Path) { Get-Content $Path -Raw | ConvertFrom-Json }
}

# Path of the current user -> %LOCALAPPDATA%\... / %APPDATA%\... / %USERPROFILE%\... (most specific first)
function ConvertTo-TokenPath([string]$Text) {
    if (-not $Text) { return $Text }
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $dir = [Environment]::GetEnvironmentVariable($v)
        $Text = [regex]::Replace($Text, [regex]::Escape($dir), "%$v%", 'IgnoreCase')
    }
    $Text
}

# Shortcut -> JSON with tokenized paths, so it can be recreated for another user name
function Export-Shortcut([string]$LnkPath, [string]$JsonPath) {
    if (-not (Test-Path -LiteralPath $LnkPath)) { Write-Warning "missing, skipped: $LnkPath"; return }
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($LnkPath)
    New-Item -ItemType Directory -Force -Path (Split-Path $JsonPath) | Out-Null
    [ordered]@{
        Location         = ConvertTo-TokenPath $LnkPath
        TargetPath       = ConvertTo-TokenPath $s.TargetPath
        Arguments        = ConvertTo-TokenPath $s.Arguments
        WorkingDirectory = ConvertTo-TokenPath $s.WorkingDirectory
        WindowStyle      = $s.WindowStyle
        Description      = $s.Description
    } | ConvertTo-Json | Set-Content $JsonPath -Encoding UTF8
    Write-Host "  ok  $LnkPath"
}

function Import-Shortcut([string]$JsonPath) {
    $d = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $x = { param($t) [Environment]::ExpandEnvironmentVariables([string]$t) }
    $lnk = & $x $d.Location
    New-Item -ItemType Directory -Force -Path (Split-Path $lnk) | Out-Null
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = & $x $d.TargetPath
    $s.Arguments = & $x $d.Arguments
    if ($d.WorkingDirectory) { $s.WorkingDirectory = & $x $d.WorkingDirectory }
    if ($d.WindowStyle) { $s.WindowStyle = $d.WindowStyle }
    if ($d.Description) { $s.Description = $d.Description }
    $s.Save()
    Write-Host "  ok  $lnk"
}

# Replace the old profile folder with the new one in text config files under $Paths (files or folders).
# Covers C:\Users\old, C:\\Users\\old (JSON, .reg), C:/Users/old and /mnt/c/Users/old (WSL). Keeps each file's encoding.
function Update-UserPaths {
    param([string[]]$Paths, [string]$OldProfile, [string]$NewProfile)
    if (-not $OldProfile -or $OldProfile -eq $NewProfile) { return }
    $pairs = @(
        @($OldProfile, $NewProfile),
        @($OldProfile.Replace('\', '\\'), $NewProfile.Replace('\', '\\')),
        @($OldProfile.Replace('\', '/'), $NewProfile.Replace('\', '/'))
    )
    $wsl = { param($p) '/mnt/' + $p.Substring(0, 1).ToLower() + $p.Substring(2).Replace('\', '/') }
    $pairs += , @((& $wsl $OldProfile), (& $wsl $NewProfile))
    $ext = '.json', '.jsonc', '.ini', '.conf', '.cfg', '.config', '.xml', '.yml', '.yaml', '.toml', '.txt', '.ps1', '.reg', '.code-workspace',
             '.gitconfig', '.wslconfig', ''   # dotfiles: PowerShell sees the whole name as the extension
    $files = foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { Get-Item -LiteralPath $p -Force }
        elseif (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Recurse -File -Force -EA 0 }
    }
    $n = 0
    foreach ($f in $files | Where-Object { $_.Length -lt 5MB -and $ext -contains $_.Extension.ToLower() }) {
        # write back exactly as read: UTF-16 LE with BOM (.reg export), UTF-8 with or without BOM
        $b = [IO.File]::ReadAllBytes($f.FullName)
        if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = New-Object Text.UnicodeEncoding($false, $true); $skip = 2 }
        elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $enc = New-Object Text.UTF8Encoding($true); $skip = 3 }
        else { $enc = New-Object Text.UTF8Encoding($false); $skip = 0 }
        $text = $enc.GetString($b, $skip, $b.Length - $skip)
        if ($text.IndexOf([char]0) -ge 0) { continue }   # binary file without extension
        $new = $text
        foreach ($pr in $pairs) { $new = [regex]::Replace($new, [regex]::Escape($pr[0]), $pr[1].Replace('$', '$$'), 'IgnoreCase') }
        if ($new -ne $text) { [IO.File]::WriteAllText($f.FullName, $new, $enc); $n++ }
    }
    Write-Host "  user paths $OldProfile -> $NewProfile updated in $n file(s)"
}
