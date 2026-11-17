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

# Official release archives. The SHA-256 of every archive is checked before anything is unpacked.
$Cores = @(
    @{ name = 'sing-box'; version = '1.14.4'
        url = 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip'
        sha256 = '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df'
        files = @('sing-box.exe', 'libcronet.dll')
    },
    @{ name = 'Xray-core'; version = '26.11.9'
        url = 'https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-windows-64.zip'
        sha256 = '1262522266337b824f07beb8e1375786b437683b3890105469088f8e17e0a69d'
        files = @('xray.exe', 'geoip.dat', 'geosite.dat')
    }
)

function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw "Only 64-bit Windows (x64) is supported; this machine reports $($env:PROCESSOR_ARCHITECTURE)." }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe not found. Windows 10 (1803) or newer is required.' }

# ---------------------------------------------------------------- cores
Step 'Cores (sing-box, Xray)'
if (-not (Test-Path $Bin)) { New-Item -ItemType Directory -Force $Bin | Out-Null }
foreach ($c in $Cores) {
    $missing = @($c.files | Where-Object { -not (Test-Path (Join-Path $Bin $_)) })
    if ($missing.Count -eq 0 -and -not $Force) { "  $($c.name): already installed"; continue }
    $tmp = Join-Path $env:TEMP ('vlessclient-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'core.zip'
        "  $($c.name) $($c.version): downloading $($c.url)"
        & curl.exe -sS -L -m 600 -o $zip $c.url
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip)) { throw "Download failed (curl exit code $LASTEXITCODE). Check the connection and run setup again." }
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $c.sha256) { throw "Checksum mismatch for $($c.name): expected $($c.sha256), got $hash. Nothing was installed." }
        "  $($c.name): checksum OK"
        $out = Join-Path $tmp 'x'
        Expand-Archive -Path $zip -DestinationPath $out -Force
        foreach ($f in $c.files) {
            $src = Get-ChildItem $out -Recurse -File -Filter $f | Select-Object -First 1
            if (-not $src) { throw "File $f not found inside the $($c.name) archive." }
            Copy-Item $src.FullName (Join-Path $Bin $f) -Force
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
  vpn ui         control page: per-app switches, live traffic, problems
  vpn help       all commands

  Without "vpn install" the client still works as a local proxy on 127.0.0.1:2080 (vpn start).
'@
