# VlessClient setup: downloads the cores, creates settings.json for your subscription, adds the "vpn" command.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).
#
#   setup.cmd -Subscription "https://host/sub/xxxx"     normal first run
#   setup.cmd -Subscription "..." -InsecureTls           the subscription server has a self-signed certificate
#   setup.cmd -NoShim                                    do not add the "vpn" command to PATH
#   setup.cmd -Force                                     download the cores again
param(
    [string]$Subscription = '',
    [switch]$InsecureTls,
    [switch]$NoShim,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Bin = Join-Path $Root 'bin'
$Utf8 = New-Object Text.UTF8Encoding($false)

function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw "Only 64-bit Windows (x64) is supported; this machine reports $($env:PROCESSOR_ARCHITECTURE)." }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe not found. Windows 10 (1803) or newer is required.' }

# ---------------------------------------------------------------- cores
Step 'Cores (sing-box, Xray)'
. (Join-Path (Split-Path $Root -Parent) 'cores.ps1')
Install-Cores $Bin -Force:$Force

# ---------------------------------------------------------------- settings.json
Step 'Settings'
$settingsPath = Join-Path $Root 'settings.json'
if (Test-Path $settingsPath) {
    '  settings.json already exists, keeping it.'
    if ($Subscription) { '  (-Subscription ignored: edit "subscription.url" in settings.json to change the link)' }
} else {
    if (-not $Subscription) {
        Write-Host '  Paste your VLESS subscription link (https://...) and press Enter:'
        $Subscription = "$(Read-Host '  link')".Trim()
    }
    if ($Subscription -notmatch '^https?://\S+$') { throw 'A subscription link starting with http:// or https:// is required.' }
    $json = Get-Content (Join-Path $Root 'settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $json.subscription.url = $Subscription
    $json.subscription.insecure_tls = [bool]$InsecureTls
    # write through vpn.ps1 formatting later; plain ConvertTo-Json is fine for the first file
    [IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 20), $Utf8)
    '  settings.json created.'
}

# ---------------------------------------------------------------- subscription check
Step 'Subscription'
$s = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$probe = @('-sS', '-L', '-m', '25', '--noproxy', '*', '-o', 'NUL')
if ($s.subscription.insecure_tls) { $probe += '-k' }
$probe += "$($s.subscription.url)"
$ErrorActionPreference = 'Continue'
& curl.exe @probe 2>$null
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -eq 60 -or $code -eq 35 -or $code -eq 77) {
    Write-Host '  The subscription server did not pass the TLS certificate check.' -ForegroundColor Yellow
    Write-Host '  Many self-hosted panels use a self-signed certificate. If you trust this server, set' -ForegroundColor Yellow
    Write-Host '  "insecure_tls": true in settings.json (section "subscription") and run:  vpn update' -ForegroundColor Yellow
} elseif ($code -ne 0) {
    Write-Host "  Could not reach the subscription server (curl exit code $code). Check the link, then run:  vpn update" -ForegroundColor Yellow
} else {
    & (Join-Path $Root 'vpn.cmd') update
}

# ---------------------------------------------------------------- "vpn" command
if (-not $NoShim) {
    Step 'Command "vpn"'
    $apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    $existing = Get-Command vpn -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike "$apps\vpn.cmd" -and $_.Source -notlike "$Root\*" } | Select-Object -First 1
    $inPath = @($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $apps }).Count -gt 0
    if ($existing) {
        "  A different 'vpn' command already exists ($($existing.Source)); not touching it. Use .\vpn.cmd from this folder."
    } elseif (-not (Test-Path $apps) -or -not $inPath) {
        "  $apps is not in PATH; use .\vpn.cmd from this folder or add the folder to PATH yourself."
    } else {
        $shim = "@echo off`r`nrem Shortcut to VlessClient so that `"vpn <command>`" works from any folder.`r`ncall `"$Root\vpn.cmd`" %*`r`n"
        [IO.File]::WriteAllText((Join-Path $apps 'vpn.cmd'), $shim, [Text.Encoding]::Default)
        "  'vpn' now works from any folder (shim: $apps\vpn.cmd)."
    }
}

Step 'Done. Next steps'
@'
  vpn test       check that the nodes of your subscription answer
  vpn install    autostart at logon + system-wide tunnel (asks for administrator rights once)
  vpn start      start now
  vpn ui         open the desktop app (requires an MSI install or a Release build)
  vpn help       all commands

  Without "vpn install" the client still works as a local proxy on 127.0.0.1:2080 (vpn start).
'@
