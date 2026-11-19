param([switch]$RemoveAutostart)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$system = [Environment]::SystemDirectory
$controlScript = Join-Path $root 'vpn.ps1'
$powerShell = Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'
$conhost = Join-Path $system 'conhost.exe'
$daemonArguments = '--headless "{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" daemon' -f $powerShell, $controlScript
$taskNames = @(Get-ScheduledTask -TaskPath '\' | Where-Object {
    $_.TaskName -like 'VlessClient-S-1-*' -and @($_.Actions).Count -eq 1 -and
    $_.Actions[0].Execute -eq $conhost -and $_.Actions[0].Arguments -eq $daemonArguments
})
foreach ($task in $taskNames) {
    Stop-ScheduledTask -InputObject $task
}

$desktop = Join-Path $root 'VlessClient.exe'
$cores = @((Join-Path $root 'bin\sing-box.exe'), (Join-Path $root 'bin\xray.exe'))
$processes = Get-CimInstance Win32_Process -Filter "Name='VlessClient.exe' OR Name='powershell.exe' OR Name='xray.exe' OR Name='sing-box.exe'"
$scriptArgument = '-File\s+"' + [regex]::Escape($controlScript) + '"\s+(?:daemon|desktop-worker|desktop-start)(?:\s|$)'
$clients = $processes | Where-Object {
    $_.ExecutablePath -eq $desktop -or
    ($_.ExecutablePath -eq $powerShell -and $_.CommandLine -match $scriptArgument)
}
foreach ($process in @($clients) + @($processes | Where-Object { $_.ExecutablePath -in $cores })) {
    $live = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    if ($live -and $live.Path -eq $process.ExecutablePath) {
        try { $live.Kill(); [void]$live.WaitForExit(5000) }
        catch [InvalidOperationException] { if (-not $live.HasExited) { throw } }
        finally { $live.Dispose() }
    }
}

if ($RemoveAutostart) {
    foreach ($task in $taskNames) {
        Unregister-ScheduledTask -InputObject $task -Confirm:$false
    }
}
