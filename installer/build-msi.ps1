param(
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,5}$')][string]$Version = '1.0.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$payload = Join-Path $PSScriptRoot 'obj\payload'
$bin = Join-Path $payload 'bin'
$output = [IO.Path]::GetFullPath($OutputDirectory)
$versionNumber = [version]$Version
if ($versionNumber.Major -gt 255 -or $versionNumber.Minor -gt 255 -or $versionNumber.Build -gt 65535) {
    throw 'MSI version fields must be in the ranges 0-255, 0-255, 0-65535.'
}
if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = 'Major' }

function Invoke-Dotnet([string[]]$Arguments) {
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
}

New-Item -ItemType Directory -Force $payload, $output | Out-Null
. (Join-Path $root 'cores.ps1')
Install-Cores $bin -IncludeLicenses

$licenseFile = Join-Path $bin 'GPL-3.0.txt'
& curl.exe --fail --silent --show-error --location --max-time 60 --output $licenseFile 'https://www.gnu.org/licenses/gpl-3.0.txt'
if ($LASTEXITCODE -ne 0) { throw 'Could not download the full GNU GPL v3 license.' }
$mit = [IO.File]::ReadAllText((Join-Path $root 'LICENSE'))
$rtfText = $mit.Replace('\', '\\').Replace('{', '\{').Replace('}', '\}') -replace '\r?\n', '\par '
[IO.File]::WriteAllText((Join-Path $payload 'License.rtf'), ('{\rtf1\ansi ' + $rtfText + '}'), [Text.Encoding]::ASCII)

foreach ($file in 'vpn.ps1', 'vpn.cmd', 'settings.example.json', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $payload -Force
}
foreach ($file in 'StopInstalledClient.ps1', 'THIRD-PARTY.txt') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $payload -Force
}
[IO.File]::WriteAllText((Join-Path $payload 'installed.marker'), 'VlessClient MSI')
Invoke-Dotnet @('build', (Join-Path $root 'desktop\VlessClient.csproj'), '-c', 'Release', '-o', $payload)

$msi = Join-Path $output "VlessClient-$Version-x64.msi"
Push-Location $PSScriptRoot
try {
    Invoke-Dotnet @('tool', 'restore')
    Invoke-Dotnet @('tool', 'run', 'wix', 'extension', 'add', 'WixToolset.UI.wixext/4.0.6', 'WixToolset.Util.wixext/4.0.6')
    Invoke-Dotnet @('tool', 'run', 'wix', 'build', 'Package.wxs', '-arch', 'x64', '-culture', 'ru-RU',
        '-ext', 'WixToolset.UI.wixext', '-ext', 'WixToolset.Util.wixext',
        '-d', "Payload=$payload", '-d', "Version=$Version", '-out', $msi)
} finally { Pop-Location }
Get-Item -LiteralPath $msi
