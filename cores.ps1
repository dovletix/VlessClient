# Shared release pins for the portable setup and MSI build.
function Install-Cores([string]$Destination, [switch]$Force, [switch]$IncludeLicenses) {
    $cores = @(
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

    New-Item -ItemType Directory -Force $Destination | Out-Null
    foreach ($core in $cores) {
        $missing = @($core.files | Where-Object { -not (Test-Path (Join-Path $Destination $_)) })
        if (-not $missing.Count -and -not $Force -and -not $IncludeLicenses) {
            "  $($core.name): already installed"
            continue
        }
        $tmp = Join-Path $env:TEMP ('vlessclient-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'core.zip'
            "  Downloading $($core.name) $($core.version)"
            & curl.exe --fail --silent --show-error --location --max-time 600 --output $zip $core.url
            if ($LASTEXITCODE -ne 0) { throw "Download failed for $($core.name) (curl exit code $LASTEXITCODE)." }
            if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $core.sha256) { throw "Checksum mismatch for $($core.name)." }
            $unpacked = Join-Path $tmp 'extracted'
            Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
            foreach ($name in $core.files) {
                $file = Get-ChildItem $unpacked -Recurse -File -Filter $name | Select-Object -First 1
                if (-not $file) { throw "File $name missing from the $($core.name) release archive." }
                Copy-Item -LiteralPath $file.FullName -Destination $Destination -Force
            }
            if ($IncludeLicenses) {
                $license = Get-ChildItem $unpacked -Recurse -File -Filter 'LICENSE*' | Select-Object -First 1
                if (-not $license) { throw "License missing from the $($core.name) release archive." }
                Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $Destination "$($core.name)-LICENSE.txt") -Force
            }
        } finally {
            $parent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            $target = [IO.Path]::GetFullPath($tmp)
            if ($target.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
