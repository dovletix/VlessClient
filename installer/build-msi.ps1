# Builds installer\dist\VlessClient-<version>-x64.msi: the app, the cores (pinned in cores.ps1) and the Windows service.
#   .\installer\build-msi.ps1 -Version 2.0.0
param(
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,5}$')][string]$Version = '2.0.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$payload = Join-Path $PSScriptRoot 'obj\payload'
$bin = Join-Path $payload 'bin'
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $env:DOTNET_ROLL_FORWARD) { $env:DOTNET_ROLL_FORWARD = 'Major' }

function Invoke-Dotnet([string[]]$Arguments) {
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
}

if (Test-Path $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
New-Item -ItemType Directory -Force $payload, $bin, $output | Out-Null

. (Join-Path $root 'cores.ps1')
Install-Cores $bin -IncludeLicenses

$gpl = Join-Path $bin 'GPL-3.0.txt'
& curl.exe --fail --silent --show-error --location --max-time 60 --output $gpl 'https://www.gnu.org/licenses/gpl-3.0.txt'
if ($LASTEXITCODE -ne 0) { throw 'Could not download the GNU GPL v3 text.' }

$mit = [IO.File]::ReadAllText((Join-Path $root 'LICENSE'))
$rtf = $mit.Replace('\', '\\').Replace('{', '\{').Replace('}', '\}') -replace '\r?\n', '\par '
[IO.File]::WriteAllText((Join-Path $payload 'License.rtf'), ('{\rtf1\ansi ' + $rtf + '}'), [Text.Encoding]::ASCII)
Copy-Item (Join-Path $root 'LICENSE') $payload
Copy-Item (Join-Path $PSScriptRoot 'THIRD-PARTY.txt') $payload
Copy-Item (Join-Path $root 'src\VlessClient\Assets\app.ico') $payload

Invoke-Dotnet @('build', (Join-Path $root 'src\VlessClient\VlessClient.csproj'), '-c', 'Release', '-o', $payload, "-p:Version=$Version", '-nologo', '-v', 'q')

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
