# VlessClient control script. Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
$Bin = Join-Path $Root 'bin'
$Installed = Test-Path -LiteralPath (Join-Path $Root 'installed.marker')
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Data = $Root
if ($Installed) { $Data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VlessClient' }
$Run = Join-Path $Data 'runtime'
$SettingsPath = Join-Path $Data 'settings.json'
$SubCache = Join-Path $Run 'subscription.txt'
$SubHeaders = Join-Path $Run 'subscription.headers'
$StatePath = Join-Path $Run 'state.json'
$StopFlag = Join-Path $Run 'stop.flag'
$ReloadFlag = Join-Path $Run 'reload.flag'
$DaemonLog = Join-Path $Run 'daemon.log'
$XrayLog = Join-Path $Run 'xray.log'
$SingLog = Join-Path $Run 'sing-box.log'
$XrayCfg = Join-Path $Run 'xray.json'
$SingCfg = Join-Path $Run 'sing-box.json'
$XrayExe = Join-Path $Bin 'xray.exe'
$SingExe = Join-Path $Bin 'sing-box.exe'
$RulesDir = Join-Path $Run 'rules'
$TaskName = 'VlessClient'
if ($Installed) { $TaskName += '-' + $Identity.User.Value }
$SystemDir = [Environment]::SystemDirectory
$PowerShellExe = Join-Path $SystemDir 'WindowsPowerShell\v1.0\powershell.exe'
$ConsoleHost = Join-Path $SystemDir 'conhost.exe'
$DaemonArguments = '--headless "{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" daemon' -f $PowerShellExe, $PSCommandPath
$Utf8 = New-Object Text.UTF8Encoding($false)
$Inv = [Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path $Run)) { New-Item -ItemType Directory -Force $Run | Out-Null }

# ---------------------------------------------------------------- helpers

function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $Utf8) }

function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { [IO.File]::AppendAllText($DaemonLog, $line + "`r`n", $Utf8) } catch {}
}

function Format-Json([string]$json) {
    $indent = 0
    $lines = foreach ($raw in ($json -split "`r?`n")) {
        $t = $raw.Trim()
        if ($t -match '^[\}\]]') { $indent = [Math]::Max(0, $indent - 1) }
        $t = $t -replace '^("[^"]*"):\s+', '$1: '
        $line = ('  ' * $indent) + $t
        if ($t -match '[\{\[]$') { $indent++ }
        $line
    }
    $out = ($lines -join "`n")
    $out = [regex]::Replace($out, '\[\s+\]', '[]')
    $out = [regex]::Replace($out, '\{\s+\}', '{}')
    return $out + "`n"
}

function Write-Json([string]$path, $obj) { Write-Text $path (Format-Json ($obj | ConvertTo-Json -Depth 40)) }

function L($x) {
    $r = @()
    foreach ($i in @($x)) { if ($null -ne $i -and "$i".Trim() -ne '') { $r += "$i".Trim() } }
    return , ([string[]]$r)
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Capture([string]$exe, [string]$arguments, [int]$timeoutMs = 10000) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $p = [Diagnostics.Process]::Start($psi) } catch { return [pscustomobject]@{ code = -2; out = ''; err = "$_" } }
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ code = -1; out = ''; err = 'timeout' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ code = $p.ExitCode; out = "$($o.Result)"; err = "$($e.Result)" }
}

function Get-Settings {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        if (-not $Installed -and $Command -ne 'desktop-worker') { throw "settings.json not found: $SettingsPath" }
        try { [IO.File]::Copy((Join-Path $Root 'settings.example.json'), $SettingsPath, $false) }
        catch [IO.IOException] { if (-not (Test-Path -LiteralPath $SettingsPath)) { throw } }
    }
    return (Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-Settings($s) {
    $temp = $SettingsPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Write-Json $temp $s
        if ([IO.File]::Exists($SettingsPath)) { [IO.File]::Replace($temp, $SettingsPath, [NullString]::Value) }
        else { [IO.File]::Move($temp, $SettingsPath) }
    } finally { [IO.File]::Delete($temp) }
}

function Get-State {
    if (Test-Path $StatePath) { try { return (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
    return $null
}

function Test-Pid($id, [string]$name) {
    if (-not $id) { return $false }
    $p = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
    return [bool]($p -and $p.ProcessName -like $name)
}

function Test-DaemonRunning {
    $st = Get-State
    return [bool]($st -and (Test-Pid $st.daemon_pid 'powershell*'))
}

function Test-Port([int]$port) {
    return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- subscription

function Update-Subscription($s = $null) {
    if (-not $s) { $s = Get-Settings }
    if ("$($s.subscription.url)" -notmatch '^https?://[^\x00-\x20"\x7f]+$' -or "$($s.subscription.url)".EndsWith('\')) { return $false }
    $tmp = Join-Path $Run ('subscription-' + [guid]::NewGuid().ToString('N') + '.new')
    $a = '-fsSL -m 25 --proto =http,https --proto-redir =http,https --noproxy * -o "{0}" -D "{1}"' -f $tmp, $SubHeaders
    if ($s.subscription.insecure_tls) { $a += ' -k' }
    $a += ' -- "{0}"' -f $s.subscription.url
    try {
        $r = Invoke-Capture (Join-Path $SystemDir 'curl.exe') $a 30000
        if ($r.code -ne 0 -or -not (Test-Path $tmp)) { Write-Log "subscription: fetch failed (curl code $($r.code))"; return $false }
        $raw = [IO.File]::ReadAllText($tmp, $Utf8).Trim()
    } finally { [IO.File]::Delete($tmp) }
    if ($raw -notmatch '://') {
        try {
            $b = ($raw -replace '\s', '').Replace('-', '+').Replace('_', '/')
            while ($b.Length % 4) { $b += '=' }
            $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
        } catch { Write-Log 'subscription: body is neither a link list nor base64'; return $false }
    }
    $lines = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^vless://' })
    if ($lines.Count -eq 0) { Write-Log 'subscription: no vless:// links found'; return $false }
    $new = ($lines -join "`n")
    $old = ''
    if (Test-Path $SubCache) { $old = [IO.File]::ReadAllText($SubCache, $Utf8) }
    Write-Text $SubCache $new
    if ($old -ne $new) { Write-Log "subscription: updated, $($lines.Count) nodes" }
    return $true
}

function Get-SubscriptionAgeHours {
    if (-not (Test-Path $SubCache)) { return 1e9 }
    return ((Get-Date) - (Get-Item $SubCache).LastWriteTime).TotalHours
}

function ConvertFrom-VlessUri([string]$line) {
    $m = [regex]::Match($line.Trim(), '^vless://([^@]+)@(\[[^\]]+\]|[^:/?#]+):(\d+)/?\??([^#]*)#?(.*)$')
    if (-not $m.Success) { return $null }
    $q = @{}
    foreach ($kv in ($m.Groups[4].Value -split '&')) {
        if (-not $kv) { continue }
        $i = $kv.IndexOf('=')
        if ($i -lt 0) { $q[$kv] = '' } else { $q[$kv.Substring(0, $i)] = [Uri]::UnescapeDataString($kv.Substring($i + 1)) }
    }
    return [pscustomobject]@{
        id      = [Uri]::UnescapeDataString($m.Groups[1].Value)
        address = $m.Groups[2].Value.Trim('[', ']')
        port    = [int]$m.Groups[3].Value
        q       = $q
        name    = [Uri]::UnescapeDataString($m.Groups[5].Value)
        index   = 0
        tag     = ''
    }
}

function Get-Nodes {
    $out = @()
    if (Test-Path $SubCache) {
        $i = 0
        foreach ($line in [IO.File]::ReadAllLines($SubCache, $Utf8)) {
            $n = ConvertFrom-VlessUri $line
            if ($n) { $i++; $n.index = $i; $n.tag = ('node-{0:d2}' -f $i); $out += $n }
        }
    }
    return , $out
}

function Select-Nodes($s, $nodes) {
    $sel = "$($s.node)".Trim()
    if ($sel -eq '' -or $sel -eq 'auto') {
        $list = @($nodes)
        $f = "$($s.auto_filter)"; $x = "$($s.auto_exclude)"
        if ($f) { $list = @($list | Where-Object { $_.name -match $f }) }
        if ($x) { $list = @($list | Where-Object { $_.name -notmatch $x }) }
        if ($list.Count -eq 0) { $list = @($nodes) }
        return , $list
    }
    if ($sel -match '^\d+$') { $list = @($nodes | Where-Object { $_.index -eq [int]$sel }) }
    else { $list = @($nodes | Where-Object { $_.name -like "*$sel*" } | Select-Object -First 1) }
    if ($list.Count -eq 0) { Write-Log "node '$sel' not found, using the first node"; $list = @($nodes[0]) }
    return , $list
}

function Get-NodeKind($n) {
    $t = "$($n.q['type'])"; if (-not $t) { $t = 'tcp' }
    $k = $t
    if ($n.q['security']) { $k += '+' + $n.q['security'] }
    if ($n.q['encryption'] -and $n.q['encryption'] -ne 'none') { $k += '+mlkem' }
    return $k
}

# ---------------------------------------------------------------- xray config

function New-XrayOutbound($n) {
    $q = $n.q
    $user = [ordered]@{ id = $n.id; encryption = 'none' }
    if ($q['encryption']) { $user.encryption = $q['encryption'] }
    if ($q['flow']) { $user.flow = $q['flow'] }

    $net = "$($q['type'])"; if (-not $net -or $net -eq 'tcp') { $net = 'raw' }
    $sec = "$($q['security'])"; if (-not $sec) { $sec = 'none' }
    $stream = [ordered]@{ network = $net; security = $sec }

    if ($sec -eq 'reality') {
        $re = [ordered]@{ serverName = "$($q['sni'])"; fingerprint = 'chrome'; publicKey = "$($q['pbk'])"; shortId = "$($q['sid'])" }
        if ($q['fp']) { $re.fingerprint = $q['fp'] }
        if ($q['spx']) { $re.spiderX = $q['spx'] }
        if ($q['pqv']) { $re.mldsa65Verify = $q['pqv'] }
        $stream.realitySettings = $re
    } elseif ($sec -eq 'tls') {
        $tls = [ordered]@{ serverName = "$($q['sni'])" }
        if ($q['fp']) { $tls.fingerprint = $q['fp'] }
        if ($q['alpn']) { $tls.alpn = [string[]]@($q['alpn'] -split ',') }
        $stream.tlsSettings = $tls
    }

    switch ($net) {
        'xhttp' {
            $x = [ordered]@{}
            if ($q['path']) { $x.path = $q['path'] }
            if ($q['host']) { $x.host = $q['host'] }
            if ($q['mode']) { $x.mode = $q['mode'] }
            if ($q['extra']) { try { $x.extra = ($q['extra'] | ConvertFrom-Json) } catch {} }
            $stream.xhttpSettings = $x
        }
        'ws' {
            $w = [ordered]@{}
            if ($q['path']) { $w.path = $q['path'] }
            if ($q['host']) { $w.host = $q['host'] }
            $stream.wsSettings = $w
        }
        'grpc' {
            $g = [ordered]@{ serviceName = "$($q['serviceName'])" }
            if ($q['authority']) { $g.authority = $q['authority'] }
            $stream.grpcSettings = $g
        }
        'httpupgrade' {
            $h = [ordered]@{}
            if ($q['path']) { $h.path = $q['path'] }
            if ($q['host']) { $h.host = $q['host'] }
            $stream.httpupgradeSettings = $h
        }
    }

    return [ordered]@{
        tag            = $n.tag
        protocol       = 'vless'
        settings       = [ordered]@{ vnext = @([ordered]@{ address = $n.address; port = $n.port; users = @($user) }) }
        streamSettings = $stream
    }
}

# $fallback (optional, only with a single pinned node): a spare node that takes over while the pinned one fails its probe.
function New-XrayConfig($selected, [int]$port, [string]$logFile, $fallback = $null) {
    $outs = New-Object System.Collections.ArrayList
    foreach ($n in $selected) { [void]$outs.Add((New-XrayOutbound $n)) }
    if ($fallback) { [void]$outs.Add((New-XrayOutbound $fallback)) }
    $cfg = [ordered]@{
        log       = [ordered]@{ loglevel = 'warning'; error = $logFile; access = 'none' }
        inbounds  = @([ordered]@{ tag = 'socks-in'; listen = '127.0.0.1'; port = $port; protocol = 'socks'; settings = [ordered]@{ auth = 'noauth'; udp = $true } })
        outbounds = $outs
    }
    if (@($selected).Count -gt 1) {
        $cfg.routing = [ordered]@{
            domainStrategy = 'AsIs'
            rules          = @([ordered]@{ inboundTag = [string[]]@('socks-in'); balancerTag = 'auto' })
            balancers      = @([ordered]@{ tag = 'auto'; selector = [string[]]@('node-'); strategy = [ordered]@{ type = 'leastPing' }; fallbackTag = $selected[0].tag })
        }
        $cfg.observatory = [ordered]@{ subjectSelector = [string[]]@('node-'); probeUrl = 'https://www.gstatic.com/generate_204'; probeInterval = '2m'; enableConcurrency = $true }
    } elseif ($fallback) {
        # Pinned node with a spare: the balancer has exactly one candidate, so traffic never hops between nodes;
        # only when the probe of the pinned node fails does xray use fallbackTag.
        $tag = $selected[0].tag
        $cfg.routing = [ordered]@{
            domainStrategy = 'AsIs'
            rules          = @([ordered]@{ inboundTag = [string[]]@('socks-in'); balancerTag = 'pinned' })
            balancers      = @([ordered]@{ tag = 'pinned'; selector = [string[]]@($tag); strategy = [ordered]@{ type = 'leastPing' }; fallbackTag = $fallback.tag })
        }
        $cfg.observatory = [ordered]@{ subjectSelector = [string[]]@($tag); probeUrl = 'https://www.gstatic.com/generate_204'; probeInterval = '1m'; enableConcurrency = $false }
    }
    return $cfg
}

function New-XrayTestConfig($nodes, [int]$basePort) {
    $ins = New-Object System.Collections.ArrayList
    $outs = New-Object System.Collections.ArrayList
    $rules = New-Object System.Collections.ArrayList
    foreach ($n in $nodes) {
        $itag = 'in-' + $n.tag
        [void]$ins.Add([ordered]@{ tag = $itag; listen = '127.0.0.1'; port = ($basePort + $n.index); protocol = 'socks'; settings = [ordered]@{ auth = 'noauth'; udp = $true } })
        [void]$outs.Add((New-XrayOutbound $n))
        [void]$rules.Add([ordered]@{ inboundTag = [string[]]@($itag); outboundTag = $n.tag })
    }
    return [ordered]@{
        log       = [ordered]@{ loglevel = 'warning'; error = (Join-Path $Run 'xray-test.log'); access = 'none' }
        inbounds  = $ins
        outbounds = $outs
        routing   = [ordered]@{ domainStrategy = 'AsIs'; rules = $rules }
    }
}

# ---------------------------------------------------------------- sing-box config

function Get-DirectDns($s) {
    $d = "$($s.dns.direct)".Trim()
    if ($d -and $d -ne 'auto') { return $d }
    try {
        $skip = '(?i)' + [regex]::Escape("$($s.tun.name)") + '|happ|check point|wintun|sing-box|xray|radmin|virtualbox|wireguard'
        $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric }
        foreach ($r in $routes) {
            $ad = Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction SilentlyContinue
            if (-not $ad) { continue }
            if ($ad.InterfaceDescription -match $skip -or $ad.Name -match $skip) { continue }
            $dns = @((Get-DnsClientServerAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
            if ($dns.Count -gt 0 -and $dns[0]) { return "$($dns[0])" }
        }
    } catch {}
    return '77.88.8.8'
}

# True when a physical adapter has a global (2000::/3) IPv6 address, i.e. the uplink really provides IPv6.
function Test-NativeIPv6($s) {
    try {
        $skip = '(?i)' + [regex]::Escape("$($s.tun.name)") + '|happ|check point|wintun|sing-tun|sing-box|xray|radmin|virtualbox|wireguard|vmware|hyper-v|loopback|bluetooth'
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop | Where-Object { $_.IPAddress -match '^[23]' -and $_.AddressState -eq 'Preferred' })) {
            $ad = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            if ($ad -and $ad.Status -eq 'Up' -and $ad.InterfaceDescription -notmatch $skip -and $ad.Name -notmatch $skip) { return $true }
        }
    } catch {}
    return $false
}

function Get-CheckpointExcludes($s) {
    $ips = @()
    if (-not $s.checkpoint -or -not $s.checkpoint.enabled) { return , ([string[]]$ips) }
    foreach ($x in (L $s.checkpoint.exclude_ips)) { $ips += $x }
    if ($s.checkpoint.auto_detect_gateway) {
        $trac = Join-Path "$($s.checkpoint.path)" 'Endpoint Connect\trac.exe'
        if (Test-Path $trac) {
            $r = Invoke-Capture $trac 'info' 6000
            foreach ($m in [regex]::Matches($r.out, 'gw:\s*(\d+\.\d+\.\d+\.\d+)')) { $ips += ($m.Groups[1].Value + '/32') }
        }
    }
    return , ([string[]]@($ips | Select-Object -Unique))
}

function Get-ServerExcludes($s, $nodes) {
    $hosts = @()
    foreach ($n in $nodes) { $hosts += $n.address }
    try { $hosts += ([Uri]"$($s.subscription.url)").Host } catch {}
    $ips = @()
    foreach ($h in ($hosts | Select-Object -Unique)) {
        $ip = $null
        if ([Net.IPAddress]::TryParse($h, [ref]$ip)) {
            if ($ip.AddressFamily -eq 'InterNetworkV6') { $ips += "$h/128" } else { $ips += "$h/32" }
        } else {
            try { foreach ($a in (Resolve-DnsName $h -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })) { $ips += ($a.IPAddress + '/32') } } catch {}
        }
    }
    return , ([string[]]@($ips | Select-Object -Unique))
}

# Turns a list of domain entries into sing-box matcher fields.
# Plain entry = the domain and all its subdomains. Prefixes: full: keyword: regex:
function Add-DomainFields($rule, $entries) {
    $dom = @(); $suf = @(); $kw = @(); $rx = @()
    foreach ($e in (L $entries)) {
        $v = $e.ToLower()
        if ($v.StartsWith('full:')) { $dom += $v.Substring(5) }
        elseif ($v.StartsWith('keyword:')) { $kw += $v.Substring(8) }
        elseif ($v.StartsWith('regex:')) { $rx += $e.Substring(6) }
        else { $v = $v.TrimStart('.'); $dom += $v; $suf += ('.' + $v) }
    }
    if ($dom.Count) { $rule.domain = [string[]]$dom }
    if ($suf.Count) { $rule.domain_suffix = [string[]]$suf }
    if ($kw.Count) { $rule.domain_keyword = [string[]]$kw }
    if ($rx.Count) { $rule.domain_regex = [string[]]$rx }
}

function Add-RouteRule($list, $match, [string]$target, [bool]$blockQuic) {
    if ($match.Count -eq 0) { return }
    if ($target -eq 'block') {
        $r = [ordered]@{}; foreach ($k in $match.Keys) { $r[$k] = $match[$k] }
        $r.action = 'reject'
        [void]$list.Add($r); return
    }
    if ($target -eq 'proxy' -and $blockQuic) {
        $qr = [ordered]@{}; foreach ($k in $match.Keys) { $qr[$k] = $match[$k] }
        $qr.protocol = 'quic'; $qr.action = 'reject'
        [void]$list.Add($qr)
    }
    $r = [ordered]@{}; foreach ($k in $match.Keys) { $r[$k] = $match[$k] }
    $r.outbound = $target
    [void]$list.Add($r)
}

# ---------------------------------------------------------------- settings defaults / apps

function Initialize-Settings {
    $s = Get-Settings
    $changed = $false
    if (-not $s.PSObject.Properties['api']) { $s | Add-Member -NotePropertyName api -NotePropertyValue ([pscustomobject]@{ port = 19090; secret = '' }) -Force; $changed = $true }
    if (-not $s.api.secret) { $s.api.secret = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')); $changed = $true }
    if (-not $s.PSObject.Properties['apps']) { $s | Add-Member -NotePropertyName apps -NotePropertyValue @() -Force; $changed = $true }
    if (-not $s.PSObject.Properties['ru_direct']) { $s | Add-Member -NotePropertyName ru_direct -NotePropertyValue ([pscustomobject]@{ enabled = $true; geoip = @('ru'); geosite = @('category-ru', 'tld-ru', 'available-only-in-ru'); blocked_geosite = @('blocked-in-ru') }) -Force; $changed = $true }
    if ($changed) { Save-Settings $s }
    return $s
}

# An app = a named group of exe files with a switch: vpn=true -> through VLESS, vpn=false -> direct.
function Get-Apps($s) {
    $out = @()
    foreach ($a in @($s.apps)) {
        if ($a -and $a.name) { $out += [pscustomobject]@{ name = "$($a.name)"; processes = (L $a.processes); vpn = [bool]$a.vpn } }
    }
    return , $out
}

function Set-Apps($s, $apps) {
    $arr = @()
    foreach ($a in $apps) { $arr += [pscustomobject][ordered]@{ name = "$($a.name)"; processes = [string[]]$a.processes; vpn = [bool]$a.vpn } }
    $s | Add-Member -NotePropertyName apps -NotePropertyValue $arr -Force
}

# Creates or updates an app. Processes listed here are removed from every other app.
function Set-AppEntry($s, [string]$name, [string[]]$procs, [bool]$vpn) {
    $lower = @($procs | ForEach-Object { $_.ToLower() })
    $new = @(); $found = $false
    foreach ($a in (Get-Apps $s)) {
        if ($a.name -eq $name) { $found = $true; $new += [pscustomobject]@{ name = $name; processes = $procs; vpn = $vpn }; continue }
        $keep = [string[]]@($a.processes | Where-Object { $lower -notcontains $_.ToLower() })
        if ($keep.Count) { $a.processes = $keep; $new += $a }
    }
    if (-not $found) { $new += [pscustomobject]@{ name = $name; processes = $procs; vpn = $vpn } }
    Set-Apps $s $new
}

function Remove-AppEntry($s, [string]$name) {
    Set-Apps $s @((Get-Apps $s) | Where-Object { $_.name -ne $name })
}

function Remove-AppProcess($s, [string]$proc) {
    $new = @()
    foreach ($a in (Get-Apps $s)) {
        $keep = [string[]]@($a.processes | Where-Object { $_.ToLower() -ne $proc.ToLower() })
        if ($keep.Count) { $a.processes = $keep; $new += $a }
    }
    Set-Apps $s $new
}

# ---------------------------------------------------------------- geo data (reads bin\geoip.dat / geosite.dat)

$GeoSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;

public static class VcGeoDat
{
    public static int LastCount = 0;

    static ulong V(byte[] b, ref int p)
    {
        ulong r = 0; int s = 0;
        while (true) { byte x = b[p++]; r |= ((ulong)(x & 0x7F)) << s; if (x < 0x80) break; s += 7; }
        return r;
    }

    static void Skip(byte[] b, ref int p, int wt)
    {
        if (wt == 0) V(b, ref p);
        else if (wt == 1) p += 8;
        else if (wt == 2) { int l = (int)V(b, ref p); p += l; }
        else if (wt == 5) p += 4;
        else throw new Exception("unsupported wire type " + wt);
    }

    static string Q(string s)
    {
        StringBuilder sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            if (c == '\\' || c == '"') { sb.Append('\\').Append(c); }
            else if (c < 0x20) { sb.Append("\\u").Append(((int)c).ToString("x4")); }
            else sb.Append(c);
        }
        return sb.Append('"').ToString();
    }

    static string Arr(List<string> l)
    {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < l.Count; i++) { if (i > 0) sb.Append(','); sb.Append(Q(l[i])); }
        return sb.Append(']').ToString();
    }

    static bool Has(string[] codes, string cc)
    {
        foreach (string c in codes) { if (string.Equals(c, cc, StringComparison.OrdinalIgnoreCase)) return true; }
        return false;
    }

    // Lists "CODE count" for every entry of a geoip.dat / geosite.dat file.
    public static List<string> Codes(string path)
    {
        byte[] b = File.ReadAllBytes(path); List<string> res = new List<string>(); int p = 0;
        while (p < b.Length)
        {
            ulong tag = V(b, ref p); int wt = (int)(tag & 7);
            if ((tag >> 3) != 1 || wt != 2) { Skip(b, ref p, wt); continue; }
            int len = (int)V(b, ref p); int end = p + len; int q = p; string cc = ""; int n = 0;
            while (q < end)
            {
                ulong t = V(b, ref q); int w = (int)(t & 7); int f = (int)(t >> 3);
                if (f == 1 && w == 2) { int l = (int)V(b, ref q); cc = Encoding.UTF8.GetString(b, q, l); q += l; }
                else { if (f == 2) n++; Skip(b, ref q, w); }
            }
            res.Add(cc + " " + n); p = end;
        }
        return res;
    }

    // sing-box source rule-set with every CIDR of the given country codes.
    public static string GeoIpJson(string path, string[] codes)
    {
        byte[] b = File.ReadAllBytes(path); List<string> res = new List<string>(); int p = 0;
        while (p < b.Length)
        {
            ulong tag = V(b, ref p); int wt = (int)(tag & 7);
            if ((tag >> 3) != 1 || wt != 2) { Skip(b, ref p, wt); continue; }
            int len = (int)V(b, ref p); int end = p + len; int q = p; bool match = false;
            while (q < end)
            {
                ulong t = V(b, ref q); int w = (int)(t & 7); int f = (int)(t >> 3);
                if (f == 1 && w == 2)
                {
                    int l = (int)V(b, ref q); string cc = Encoding.UTF8.GetString(b, q, l); q += l;
                    match = Has(codes, cc); if (!match) break;
                }
                else if (f == 2 && w == 2 && match)
                {
                    int l = (int)V(b, ref q); int e = q + l; byte[] ip = null; int prefix = 0;
                    while (q < e)
                    {
                        ulong t2 = V(b, ref q); int w2 = (int)(t2 & 7); int f2 = (int)(t2 >> 3);
                        if (f2 == 1 && w2 == 2) { int l2 = (int)V(b, ref q); ip = new byte[l2]; Array.Copy(b, q, ip, 0, l2); q += l2; }
                        else if (f2 == 2 && w2 == 0) { prefix = (int)V(b, ref q); }
                        else Skip(b, ref q, w2);
                    }
                    if (ip != null && (ip.Length == 4 || ip.Length == 16)) res.Add(new IPAddress(ip).ToString() + "/" + prefix);
                }
                else Skip(b, ref q, w);
            }
            p = end;
        }
        LastCount = res.Count;
        if (res.Count == 0) return "{\"version\":3,\"rules\":[]}";
        return "{\"version\":3,\"rules\":[{\"ip_cidr\":" + Arr(res) + "}]}";
    }

    // sing-box source rule-set with every domain of the given geosite categories.
    public static string GeoSiteJson(string path, string[] codes)
    {
        byte[] b = File.ReadAllBytes(path); int p = 0;
        List<string> dom = new List<string>(); List<string> suf = new List<string>(); List<string> kw = new List<string>(); List<string> rx = new List<string>();
        while (p < b.Length)
        {
            ulong tag = V(b, ref p); int wt = (int)(tag & 7);
            if ((tag >> 3) != 1 || wt != 2) { Skip(b, ref p, wt); continue; }
            int len = (int)V(b, ref p); int end = p + len; int q = p; bool match = false;
            while (q < end)
            {
                ulong t = V(b, ref q); int w = (int)(t & 7); int f = (int)(t >> 3);
                if (f == 1 && w == 2)
                {
                    int l = (int)V(b, ref q); string cc = Encoding.UTF8.GetString(b, q, l); q += l;
                    match = Has(codes, cc); if (!match) break;
                }
                else if (f == 2 && w == 2 && match)
                {
                    int l = (int)V(b, ref q); int e = q + l; int type = 0; string val = null;
                    while (q < e)
                    {
                        ulong t2 = V(b, ref q); int w2 = (int)(t2 & 7); int f2 = (int)(t2 >> 3);
                        if (f2 == 1 && w2 == 0) { type = (int)V(b, ref q); }
                        else if (f2 == 2 && w2 == 2) { int l2 = (int)V(b, ref q); val = Encoding.UTF8.GetString(b, q, l2); q += l2; }
                        else Skip(b, ref q, w2);
                    }
                    if (!string.IsNullOrEmpty(val))
                    {
                        if (type == 0) kw.Add(val);
                        else if (type == 1) rx.Add(val);
                        else if (type == 2) { dom.Add(val); suf.Add("." + val); }
                        else dom.Add(val);
                    }
                }
                else Skip(b, ref q, w);
            }
            p = end;
        }
        LastCount = dom.Count + kw.Count + rx.Count;
        List<string> parts = new List<string>();
        if (dom.Count > 0) parts.Add("\"domain\":" + Arr(dom));
        if (suf.Count > 0) parts.Add("\"domain_suffix\":" + Arr(suf));
        if (kw.Count > 0) parts.Add("\"domain_keyword\":" + Arr(kw));
        if (rx.Count > 0) parts.Add("\"domain_regex\":" + Arr(rx));
        if (parts.Count == 0) return "{\"version\":3,\"rules\":[]}";
        return "{\"version\":3,\"rules\":[{" + string.Join(",", parts.ToArray()) + "}]}";
    }
}
'@

function Initialize-Geo { if (-not ('VcGeoDat' -as [type])) { Add-Type -TypeDefinition $GeoSource -Language CSharp } }

# Writes runtime\rules\geoip-ru.json and geosite-ru.json from the Xray geo databases (cached by a stamp file).
function Export-GeoRules($s) {
    if (-not (Test-Path $RulesDir)) { New-Item -ItemType Directory -Force $RulesDir | Out-Null }
    $ipFile = Join-Path $RulesDir 'geoip-ru.json'
    $siteFile = Join-Path $RulesDir 'geosite-ru.json'
    $stampFile = Join-Path $RulesDir 'geo.stamp'
    $ipDat = Join-Path $Bin 'geoip.dat'
    $siteDat = Join-Path $Bin 'geosite.dat'
    $blockedFile = Join-Path $RulesDir 'geosite-ru-blocked.json'
    $ipCodes = [string[]]@(); $siteCodes = [string[]]@(); $blockedCodes = [string[]]@()
    if ($s.ru_direct -and $s.ru_direct.enabled) { $ipCodes = L $s.ru_direct.geoip; $siteCodes = L $s.ru_direct.geosite; $blockedCodes = L $s.ru_direct.blocked_geosite }
    $t1 = 0; $t2 = 0
    if (Test-Path $ipDat) { $t1 = (Get-Item $ipDat).LastWriteTimeUtc.Ticks }
    if (Test-Path $siteDat) { $t2 = (Get-Item $siteDat).LastWriteTimeUtc.Ticks }
    $stamp = 'v2|{0}|{1}|{2}|{3}|{4}' -f ($ipCodes -join ','), ($siteCodes -join ','), ($blockedCodes -join ','), $t1, $t2
    if ((Test-Path $ipFile) -and (Test-Path $siteFile) -and (Test-Path $blockedFile) -and (Test-Path $stampFile) -and ([IO.File]::ReadAllText($stampFile, $Utf8) -eq $stamp)) { return }
    $empty = '{"version":3,"rules":[]}'
    $ipJson = $empty; $siteJson = $empty; $blockedJson = $empty; $nIp = 0; $nSite = 0; $nBlocked = 0
    try {
        Initialize-Geo
        if ($ipCodes.Count -and $t1) { $ipJson = [VcGeoDat]::GeoIpJson($ipDat, $ipCodes); $nIp = [VcGeoDat]::LastCount }
        if ($siteCodes.Count -and $t2) { $siteJson = [VcGeoDat]::GeoSiteJson($siteDat, $siteCodes); $nSite = [VcGeoDat]::LastCount }
        if ($blockedCodes.Count -and $t2) { $blockedJson = [VcGeoDat]::GeoSiteJson($siteDat, $blockedCodes); $nBlocked = [VcGeoDat]::LastCount }
    } catch { Write-Log "geo: export failed: $_" }
    Write-Text $ipFile $ipJson
    Write-Text $siteFile $siteJson
    Write-Text $blockedFile $blockedJson
    Write-Text $stampFile $stamp
    Write-Text (Join-Path $RulesDir 'geo.info') ("{0} {1} {2}" -f $nIp, $nSite, $nBlocked)
    Write-Log "geo: exported $nIp RU networks, $nSite RU domains, $nBlocked blocked-in-RU domains"
}

# ---------------------------------------------------------------- user rule-sets (hot-reloaded by sing-box)

function Write-IfChanged([string]$path, [string]$text) {
    $old = $null
    if (Test-Path $path) { $old = [IO.File]::ReadAllText($path, $Utf8) }
    if ($old -ne $text) { Write-Text $path $text; return $true }
    return $false
}

function New-ProcRegex($names) {
    $r = @()
    foreach ($n in (L $names)) { $r += ('(?i)(^|[\\/])' + [regex]::Escape($n) + '$') }
    return , ([string[]]$r)
}

$UserRuleSets = @('apps-block', 'apps-direct', 'apps-proxy', 'direct-domains', 'direct-ips', 'proxy-domains', 'proxy-ips')
$GeoRuleSets = @('geosite-ru-blocked', 'geosite-ru', 'geoip-ru')

# Rewrites the small rule-set files from settings.json. sing-box watches them, so changes apply without a restart.
function Write-RuleSets($s) {
    if (-not (Test-Path $RulesDir)) { New-Item -ItemType Directory -Force $RulesDir | Out-Null }
    $direct = @(); $proxy = @()
    foreach ($a in (Get-Apps $s)) { foreach ($p in $a.processes) { if ($a.vpn) { $proxy += $p } else { $direct += $p } } }
    $sets = [ordered]@{}
    foreach ($pair in @(@('apps-block', (L $s.rules.block_processes)), @('apps-direct', $direct), @('apps-proxy', $proxy))) {
        $m = [ordered]@{}
        $rx = New-ProcRegex $pair[1]
        if ($rx.Count) { $m.process_path_regex = $rx }
        $sets[$pair[0]] = $m
    }
    foreach ($t in 'direct', 'proxy') {
        $m = [ordered]@{}
        Add-DomainFields $m $s.rules."${t}_domains"
        $sets["$t-domains"] = $m
        $m = [ordered]@{}
        $ips = L $s.rules."${t}_ips"
        if ($ips.Count) { $m.ip_cidr = $ips }
        $sets["$t-ips"] = $m
    }
    $changed = $false
    foreach ($tag in $sets.Keys) {
        $rules = @()
        if ($sets[$tag].Count) { $rules = @($sets[$tag]) }
        $json = ([ordered]@{ version = 3; rules = $rules } | ConvertTo-Json -Depth 6 -Compress)
        if (Write-IfChanged (Join-Path $RulesDir "$tag.json") $json) { $changed = $true }
    }
    return $changed
}

function New-SingboxConfig($s, [bool]$tun, $nodes) {
    $default = 'proxy'; if ("$($s.default)" -eq 'direct') { $default = 'direct' }
    # The list opposite to the default is the main one; the list equal to the default holds overrides and goes first.
    $order = @($default, $(if ($default -eq 'proxy') { 'direct' } else { 'proxy' }))
    $blockQuic = [bool]$s.block_quic_on_proxy
    $r = $s.rules

    # --- route rules
    $rules = New-Object System.Collections.ArrayList
    [void]$rules.Add([ordered]@{ action = 'sniff' })
    [void]$rules.Add([ordered]@{ protocol = 'dns'; action = 'hijack-dns' })
    [void]$rules.Add([ordered]@{ process_path_regex = [string[]]@('(?i)^' + [regex]::Escape($XrayExe) + '$'); outbound = 'direct' })
    if ($s.checkpoint -and $s.checkpoint.enabled) {
        [void]$rules.Add([ordered]@{ process_path_regex = [string[]]@('(?i)^' + [regex]::Escape("$($s.checkpoint.path)".TrimEnd('\')) + '\\'); outbound = 'direct' })
        [void]$rules.Add([ordered]@{ network = 'udp'; port = @(500, 4500); outbound = 'direct' })
        $cpIps = Get-CheckpointExcludes $s
        if ($cpIps.Count) { [void]$rules.Add([ordered]@{ ip_cidr = $cpIps; outbound = 'direct' }) }
    }
    [void]$rules.Add([ordered]@{ ip_is_private = $true; outbound = 'direct' })

    # User lists live in rule-set files (runtime\rules\*.json) so they can change without restarting sing-box.
    Add-RouteRule $rules ([ordered]@{ rule_set = [string[]]@('apps-block') }) 'block' $false
    Add-RouteRule $rules ([ordered]@{ rule_set = [string[]]@('apps-direct') }) 'direct' $blockQuic
    Add-RouteRule $rules ([ordered]@{ rule_set = [string[]]@('apps-proxy') }) 'proxy' $blockQuic
    foreach ($t in $order) {
        Add-RouteRule $rules ([ordered]@{ rule_set = [string[]]@("$t-domains", "$t-ips") }) $t $blockQuic
    }
    # Russian sites and networks (geosite/geoip) go direct, except domains known to be blocked in Russia.
    Add-RouteRule $rules ([ordered]@{ rule_set = [string[]]@('geosite-ru-blocked') }) 'proxy' $blockQuic
    Add-RouteRule $rules ([ordered]@{ rule_set = [string[]]@('geosite-ru', 'geoip-ru') }) 'direct' $false
    if ($default -eq 'proxy' -and $blockQuic) { [void]$rules.Add([ordered]@{ protocol = 'quic'; action = 'reject' }) }

    # --- dns
    $dnsDirect = [ordered]@{ type = 'local'; tag = 'dns-direct' }
    if ($tun) { $dnsDirect = [ordered]@{ type = 'udp'; tag = 'dns-direct'; server = (Get-DirectDns $s) } }
    $dnsProxyAddr = "$($s.dns.proxy)"; if (-not $dnsProxyAddr) { $dnsProxyAddr = '1.1.1.1' }
    $dnsRules = New-Object System.Collections.ArrayList
    foreach ($t in $order) {
        [void]$dnsRules.Add([ordered]@{ rule_set = [string[]]@("$t-domains"); server = "dns-$t" })
    }
    [void]$dnsRules.Add([ordered]@{ rule_set = [string[]]@('geosite-ru-blocked'); server = 'dns-proxy' })
    [void]$dnsRules.Add([ordered]@{ rule_set = [string[]]@('geosite-ru'); server = 'dns-direct' })
    $dns = [ordered]@{
        servers  = @(
            [ordered]@{ type = 'https'; tag = 'dns-proxy'; server = $dnsProxyAddr; detour = 'proxy' },
            $dnsDirect
        )
        rules    = $dnsRules
        final    = "dns-$default"
        strategy = 'ipv4_only'
    }

    $ruleSetDefs = New-Object System.Collections.ArrayList
    foreach ($tag in ($UserRuleSets + $GeoRuleSets)) {
        [void]$ruleSetDefs.Add([ordered]@{ type = 'local'; tag = $tag; format = 'source'; path = (Join-Path $RulesDir "$tag.json") })
    }

    # --- inbounds
    $inbounds = New-Object System.Collections.ArrayList
    [void]$inbounds.Add([ordered]@{ type = 'mixed'; tag = 'mixed-in'; listen = "$($s.proxy.listen)"; listen_port = [int]$s.proxy.port })
    if ($tun) {
        $addr = @("$($s.tun.address4)")
        $v6 = "$($s.tun.address6)".Trim()
        # tun.ipv6: "auto" (default) | "on" | "off". Without native IPv6 on the uplink the tunnel must not offer an
        # IPv6 route: direct IPv6 would hang, while without the route Windows simply uses IPv4.
        $v6mode = "$($s.tun.ipv6)"
        if ($v6mode -eq 'off' -or ($v6mode -ne 'on' -and -not (Test-NativeIPv6 $s))) { $v6 = '' }
        if ($v6) { $addr += $v6 }
        $ex = @()
        foreach ($x in (L $s.tun.exclude_routes)) { $ex += $x }
        foreach ($x in (Get-ServerExcludes $s $nodes)) { $ex += $x }
        foreach ($x in (Get-CheckpointExcludes $s)) { $ex += $x }
        if (-not $v6) { $ex = @($ex | Where-Object { $_ -notmatch ':' }) }
        [void]$inbounds.Add([ordered]@{
                type                  = 'tun'
                tag                   = 'tun-in'
                interface_name        = "$($s.tun.name)"
                address               = [string[]]$addr
                mtu                   = [int]$s.tun.mtu
                auto_route            = $true
                strict_route          = $false
                stack                 = "$($s.tun.stack)"
                route_exclude_address = [string[]]@($ex | Select-Object -Unique)
            })
    }

    return [ordered]@{
        log       = [ordered]@{ level = $(if ($s.log_level) { "$($s.log_level)" } else { 'warn' }); output = $SingLog; timestamp = $true }
        dns       = $dns
        inbounds  = $inbounds
        outbounds = @(
            [ordered]@{ type = 'socks'; tag = 'proxy'; server = '127.0.0.1'; server_port = [int]$s.proxy.xray_port; version = '5' },
            [ordered]@{ type = 'direct'; tag = 'direct' }
        )
        route     = [ordered]@{
            rules                   = $rules
            rule_set                = $ruleSetDefs
            final                   = $default
            auto_detect_interface   = $true
            default_domain_resolver = 'dns-direct'
        }
        experimental = [ordered]@{
            clash_api = [ordered]@{ external_controller = ('127.0.0.1:{0}' -f [int]$s.api.port); secret = "$($s.api.secret)" }
        }
    }
}

# Generates runtime\xray.json and runtime\sing-box.json. Returns info object; .ok is false when validation failed.
function Build-Configs([bool]$allowTun) {
    $s = Initialize-Settings
    Export-GeoRules $s
    [void](Write-RuleSets $s)
    $nodes = Get-Nodes
    if ($nodes.Count -eq 0) { return [pscustomobject]@{ ok = $false; error = 'no nodes (subscription cache is empty)'; tun = $false; node = '' } }
    $selected = Select-Nodes $s $nodes
    $tun = ("$($s.mode)" -eq 'tun') -and $allowTun

    $fallback = $null
    if (@($selected).Count -eq 1 -and "$($s.node_fallback)" -ne 'off') {
        # spare node: the first one of the auto group (auto_filter / auto_exclude apply) that is not the pinned node
        $pool = Select-Nodes ([pscustomobject]@{ node = 'auto'; auto_filter = "$($s.auto_filter)"; auto_exclude = "$($s.auto_exclude)" }) $nodes
        $fallback = @($pool | Where-Object { $_.index -ne $selected[0].index }) | Select-Object -First 1
    }
    Write-Json $XrayCfg (New-XrayConfig $selected ([int]$s.proxy.xray_port) $XrayLog $fallback)
    Write-Json $SingCfg (New-SingboxConfig $s $tun $nodes)

    $x = Invoke-Capture $XrayExe ('run -test -c "{0}"' -f $XrayCfg) 20000
    if ($x.code -ne 0) { return [pscustomobject]@{ ok = $false; error = "xray config invalid: $($x.out) $($x.err)"; tun = $tun; node = '' } }
    $b = Invoke-Capture $SingExe ('check -c "{0}" -D "{1}"' -f $SingCfg, $Run) 20000
    if ($b.code -ne 0) { return [pscustomobject]@{ ok = $false; error = "sing-box config invalid: $($b.out) $($b.err)"; tun = $tun; node = '' } }

    $label = $selected[0].name
    if ($fallback) { $label += " (spare: $($fallback.name))" }
    if (@($selected).Count -gt 1) { $label = "auto (fastest of $(@($selected).Count))" }
    return [pscustomobject]@{ ok = $true; error = ''; tun = $tun; node = $label }
}

# ---------------------------------------------------------------- daemon

function Stop-Cores($procs) {
    foreach ($p in $procs) { if ($p) { try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) } } catch {} } }
    # sweep leftovers started from our bin folder
    foreach ($name in 'sing-box', 'xray') {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = $null; try { $path = $p.Path } catch {}
            if ($path -and $path.StartsWith($Bin, [StringComparison]::OrdinalIgnoreCase)) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {} }
        }
    }
}

function Limit-Log([string]$path) {
    try { if ((Test-Path $path) -and (Get-Item $path).Length -gt 5MB) { Move-Item $path ($path + '.old') -Force } } catch {}
}

function Invoke-Daemon {
    $created = $false
    try { $mutex = New-Object Threading.Mutex($true, 'Global\VlessClientDaemon', [ref]$created) } catch { $created = $false }
    if (-not $created) { Write-Log 'daemon: another instance is already running, exiting'; return }

    $admin = Test-Admin
    Write-Log "daemon: started (pid $PID, admin=$admin)"
    Remove-Item $StopFlag, $ReloadFlag -ErrorAction SilentlyContinue
    $xr = $null; $sb = $null; $fail = 0
    try {
        while ($true) {
            Limit-Log $DaemonLog; Limit-Log $XrayLog; Limit-Log $SingLog
            $s = Get-Settings
            $hours = [double]$s.subscription.update_hours; if ($hours -le 0) { $hours = 12 }
            if ((Get-SubscriptionAgeHours) -gt $hours) { [void](Update-Subscription) }
            $nextSub = (Get-Date).AddHours([Math]::Min($hours, 1))

            Stop-Cores @($sb, $xr); $xr = $null; $sb = $null
            $info = $null
            try { $info = Build-Configs $admin } catch { $info = [pscustomobject]@{ ok = $false; error = "$_"; tun = $false; node = '' } }

            $started = Get-Date
            if ($info.ok) {
                if (("$($s.mode)" -eq 'tun') -and -not $admin) { Write-Log 'daemon: mode=tun but not elevated -> local proxy only. Run "vpn install" once.' }
                $xr = Start-Process -FilePath $XrayExe -ArgumentList ('run -c "{0}"' -f $XrayCfg) -WorkingDirectory $Run -WindowStyle Hidden -PassThru
                Start-Sleep -Milliseconds 600
                $sb = Start-Process -FilePath $SingExe -ArgumentList ('run -c "{0}" -D "{1}"' -f $SingCfg, $Run) -WorkingDirectory $Run -WindowStyle Hidden -PassThru
                Write-Log "daemon: cores started (xray $($xr.Id), sing-box $($sb.Id)), tun=$($info.tun), node=$($info.node)"
            } else {
                Write-Log "daemon: cannot start: $($info.error)"
            }
            Write-Json $StatePath ([ordered]@{
                    daemon_pid  = $PID
                    admin       = $admin
                    xray_pid    = $(if ($xr) { $xr.Id } else { 0 })
                    singbox_pid = $(if ($sb) { $sb.Id } else { 0 })
                    tun         = [bool]$info.tun
                    node        = "$($info.node)"
                    error       = "$($info.error)"
                    started     = $started.ToString('s')
                })

            $action = $null
            while (-not $action) {
                Start-Sleep -Milliseconds 700
                if (Test-Path $StopFlag) { $action = 'stop'; break }
                if (Test-Path $ReloadFlag) { Remove-Item $ReloadFlag -ErrorAction SilentlyContinue; $fail = 0; $action = 'reload'; break }
                if ($info.ok) {
                    if ($xr.HasExited -or $sb.HasExited) {
                        $fail++
                        $wait = [Math]::Min(30, 2 * $fail)
                        Write-Log "daemon: a core exited (xray exited=$($xr.HasExited), sing-box exited=$($sb.HasExited)); restart in ${wait}s"
                        Start-Sleep -Seconds $wait
                        $action = 'reload'; break
                    }
                    if ($fail -gt 0 -and ((Get-Date) - $started).TotalSeconds -gt 90) { $fail = 0 }
                }
                if ((Get-Date) -gt $nextSub) {
                    $nextSub = (Get-Date).AddHours(1)
                    if ((Get-SubscriptionAgeHours) -gt $hours -or -not $info.ok) {
                        $before = ''; if (Test-Path $SubCache) { $before = [IO.File]::ReadAllText($SubCache, $Utf8) }
                        if (Update-Subscription) {
                            $after = [IO.File]::ReadAllText($SubCache, $Utf8)
                            if ($before -ne $after -or -not $info.ok) { $action = 'reload'; break }
                        }
                    }
                }
            }
            if ($action -eq 'stop') { break }
        }
    } finally {
        Stop-Cores @($sb, $xr)
        Remove-Item $StatePath, $StopFlag, $ReloadFlag -ErrorAction SilentlyContinue
        Write-Log 'daemon: stopped'
        try { $mutex.ReleaseMutex() } catch {}
    }
}

# ---------------------------------------------------------------- client commands

function Get-Task {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task -or @($task.Actions).Count -ne 1) { return $null }
    $action = $task.Actions[0]
    $legacy = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" daemon' -f $PSCommandPath
    if ($action.Execute -in @($ConsoleHost, 'conhost.exe') -and $action.Arguments -in @($DaemonArguments, $legacy)) { return $task }
    return $null
}

function Request-Reload {
    if (Test-DaemonRunning) {
        $old = Get-State
        Write-Text $ReloadFlag '1'
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            $st = Get-State
            if ($st -and -not (Test-Path $ReloadFlag) -and ("$($st.started)" -ne "$($old.started)" -or $st.xray_pid -ne $old.xray_pid)) { break }
        }
        return $true
    }
    return $false
}

function Start-Client([switch]$Quiet, [switch]$RequireTun) {
    if (Test-DaemonRunning) {
        if (-not $Quiet) { 'Already running -> reloading configuration.' }
        [void](Request-Reload)
        if (-not $Quiet) { Show-Status }
        return
    }
    Remove-Item $StopFlag, $ReloadFlag -ErrorAction SilentlyContinue
    $s = Get-Settings
    if (-not "$($s.subscription.url)") { if ($Quiet) { throw 'subscription-required' }; 'ERROR: configure a subscription first.'; return }
    if (-not (Test-Path $SubCache)) {
        'Fetching subscription...'
        if (-not (Update-Subscription)) {
            if ($Quiet) { throw 'subscription-fetch' }
            'ERROR: cannot fetch the subscription and there is no cached copy.'
            return
        }
    }
    $viaTask = $false
    if (Get-Task) {
        try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop; $viaTask = $true } catch { "Could not start the scheduled task ($_), starting directly." }
    }
    if (-not $viaTask) {
        if (("$($s.mode)" -eq 'tun') -and -not (Test-Admin)) {
            if ($RequireTun) { throw 'elevation-required' }
            'NOTE: mode=tun needs admin rights. Use the desktop window or run "vpn install" for TUN.'
        }
        Start-Process -FilePath $ConsoleHost -ArgumentList $DaemonArguments -WorkingDirectory $Root -WindowStyle Hidden
    }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $st = Get-State
        if ($st -and ($st.error -or (Test-Port ([int]$s.proxy.port)))) { break }
    }
    if (-not $Quiet) { Show-Status }
}

function Stop-Client {
    if (-not (Test-DaemonRunning)) { if (-not $Installed) { Stop-Cores @() }; Remove-Item $StatePath -ErrorAction SilentlyContinue; 'Not running.'; return }
    $st = Get-State
    Write-Text $StopFlag '1'
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if (-not (Test-Pid $st.daemon_pid 'powershell*')) { break } }
    if (Test-Pid $st.daemon_pid 'powershell*') { 'WARNING: daemon did not stop in 20 s.' } else { Remove-Item $StopFlag -ErrorAction SilentlyContinue; 'Stopped.' }
}

function Get-Trace([string]$proxyArg) {
    $r = Invoke-Capture 'curl.exe' ("-s -m 8 $proxyArg -w `"\ncode=%{http_code}\ntime=%{time_total}`" https://www.cloudflare.com/cdn-cgi/trace") 12000
    $ip = ''; $loc = ''; $ms = $null
    if ($r.out -match '(?m)^ip=(.+)$') { $ip = $Matches[1].Trim() }
    if ($r.out -match '(?m)^loc=(.+)$') { $loc = $Matches[1].Trim() }
    if ($ip -and $r.out -match '(?m)^time=([\d\.]+)') { $ms = [int]([double]::Parse($Matches[1], $Inv) * 1000) }
    return [pscustomobject]@{ ip = $ip; loc = $loc; ms = $ms }
}

function Show-Status {
    $s = Get-Settings
    $st = Get-State
    $running = Test-DaemonRunning
    $port = [int]$s.proxy.port
    if ($running) {
        "Daemon      : running (pid $($st.daemon_pid), elevated=$($st.admin), since $($st.started))"
        "Cores       : xray=$(if (Test-Pid $st.xray_pid 'xray') {'up'} else {'DOWN'})  sing-box=$(if (Test-Pid $st.singbox_pid 'sing-box') {'up'} else {'DOWN'})"
        if ($st.error) { "ERROR       : $($st.error)" }
        "Mode        : $(if ($st.tun) {'tun (system-wide, per-exe rules active)'} elseif ("$($s.mode)" -eq 'tun') {'LOCAL PROXY ONLY (tun requested but daemon is not elevated)'} else {'local proxy only'})"
        "Node        : $($st.node)"
    } else {
        'Daemon      : stopped'
        "Mode        : $($s.mode) (configured)"
        "Node        : $($s.node) (configured)"
    }
    "Default     : unmatched traffic -> $($s.default)"
    "Local proxy : socks5/http $($s.proxy.listen):$port  $(if (Test-Port $port) {'[listening]'} else {'[not listening]'})"
    "Autostart   : $(if (Get-Task) {'installed (scheduled task ' + $TaskName + ')'} else {'not installed'})"
    if (Test-Path $SubCache) {
        $nodes = Get-Nodes
        "Subscription: $($nodes.Count) nodes, updated $([int](Get-SubscriptionAgeHours)) h ago"
    }
    if ($running -and (Test-Port $port)) {
        $t = Get-Trace "-x socks5h://127.0.0.1:$port"
        if ($t.ip) { "Via proxy   : exit IP $($t.ip) ($($t.loc)), $($t.ms) ms" } else { 'Via proxy   : NO CONNECTIVITY' }
        $d = Get-Trace '--noproxy *'
        if ($d.ip) { "System path : exit IP $($d.ip) ($($d.loc))" }
    }
}

function Show-Nodes {
    $s = Get-Settings
    $nodes = Get-Nodes
    if ($nodes.Count -eq 0) { 'No nodes. Run: vpn update'; return }
    $sel = Select-Nodes $s $nodes
    $selIdx = @($sel | ForEach-Object { $_.index })
    foreach ($n in $nodes) {
        '{0} {1,2}  {2,-28} {3,-20} {4}:{5}' -f $(if ($selIdx -contains $n.index) { '*' } else { ' ' }), $n.index, $n.name, (Get-NodeKind $n), $n.address, $n.port
    }
    "Selected: $($s.node)   (* = in use)"
}

function Invoke-NodeTest {
    $s = Get-Settings
    $nodes = Get-Nodes
    if ($nodes.Count -eq 0) { 'No nodes. Run: vpn update'; return }
    $base = 21000
    $cfgPath = Join-Path $Run 'xray-test.json'
    Write-Json $cfgPath (New-XrayTestConfig $nodes $base)
    $chk = Invoke-Capture $XrayExe ('run -test -c "{0}"' -f $cfgPath) 20000
    if ($chk.code -ne 0) { "xray rejected the test config: $($chk.out) $($chk.err)"; return }
    $p = Start-Process -FilePath $XrayExe -ArgumentList ('run -c "{0}"' -f $cfgPath) -WorkingDirectory $Run -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Seconds 2
        $selIdx = @((Select-Nodes $s $nodes) | ForEach-Object { $_.index })
        foreach ($n in $nodes) {
            $t = Get-Trace ("-x socks5h://127.0.0.1:{0}" -f ($base + $n.index))
            $res = 'FAIL'; if ($t.ip) { $res = '{0,5} ms  {1} ({2})' -f $t.ms, $t.ip, $t.loc }
            '{0} {1,2}  {2,-28} {3,-20} {4}' -f $(if ($selIdx -contains $n.index) { '*' } else { ' ' }), $n.index, $n.name, (Get-NodeKind $n), $res
        }
    } finally {
        try { $p.Kill() } catch {}
        Remove-Item $cfgPath -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- UDP quality per node (what voice chat feels)

# Opens a SOCKS5 UDP association on a local xray port. Returns $null when the node does not answer.
function Open-SocksUdp([int]$port, [string]$targetHost, [int]$targetPort) {
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $tcp.Connect('127.0.0.1', $port)
        $ns = $tcp.GetStream(); $ns.ReadTimeout = 3000
        $ns.Write([byte[]](5, 1, 0), 0, 3)
        $b = New-Object byte[] 2; [void]$ns.Read($b, 0, 2)
        $ns.Write([byte[]](5, 3, 0, 1, 0, 0, 0, 0, 0, 0), 0, 10)
        $r = New-Object byte[] 10; $got = 0
        while ($got -lt 10) { $n = $ns.Read($r, $got, 10 - $got); if ($n -le 0) { break }; $got += $n }
        if ($got -lt 10 -or $r[1] -ne 0) { $tcp.Close(); return $null }
        $ip = New-Object Net.IPAddress (, [byte[]]$r[4..7])
        if ($ip.Equals([Net.IPAddress]::Any)) { $ip = [Net.IPAddress]::Loopback }
        $udp = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
        $udp.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Loopback, 0)))
        $name = [Text.Encoding]::ASCII.GetBytes($targetHost)
        $hdr = [byte[]](@(0, 0, 0, 3, $name.Length) + $name + @(([int][Math]::Floor($targetPort / 256)), ($targetPort % 256)))
        return @{ tcp = $tcp; udp = $udp; relay = (New-Object Net.IPEndPoint($ip, ($r[8] * 256 + $r[9]))); hdr = $hdr }
    } catch { return $null }
}

# Sends STUN binding requests (one small UDP packet every 50 ms) and reports loss, latency and jitter.
#   vpn quality [seconds]       - through every node of the subscription (separate xray process)
#   vpn quality live [seconds]  - through the running client, one probe per stage of its pipeline
function Invoke-QualityTest($argv) {
    $argv = @($argv)
    $live = ($argv -contains 'live')
    $seconds = 10
    foreach ($a in $argv) { if ("$a" -match '^\d+$') { $seconds = [int]$a } }
    $interval = 50
    $count = [int]($seconds * 1000 / $interval)
    $s = Get-Settings
    $states = @()
    $p = $null
    $cfgPath = Join-Path $Run 'xray-quality.json'
    $mkState = {
        param($c, [string]$label, [string]$kind, [int]$index, [bool]$selected)
        if (-not $c) { $c = @{ dead = $true } }
        $c.label = $label; $c.kind = $kind; $c.index = $index; $c.selected = $selected; $c.warm = $false
        $c.sent = New-Object double[] $count; $c.rtt = New-Object double[] $count
        for ($i = 0; $i -lt $count; $i++) { $c.rtt[$i] = -1 }
        return $c
    }
    try {
        if ($live) {
            $states += (& $mkState (Open-SocksUdp ([int]$s.proxy.xray_port) 'stun.l.google.com' 19302) 'xray only' 'socks 127.0.0.1' 1 $false)
            $states += (& $mkState (Open-SocksUdp ([int]$s.proxy.port) 'stun.l.google.com' 19302) 'sing-box proxy -> xray' 'socks 127.0.0.1' 2 $false)
            $raw = $null
            try {
                $ip = [Net.Dns]::GetHostAddresses('stun.l.google.com') | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                $u = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
                $u.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)))
                $raw = @{ udp = $u; relay = (New-Object Net.IPEndPoint($ip, 19302)); hdr = (New-Object byte[] 0); raw = $true }
            } catch {}
            $states += (& $mkState $raw 'TUN -> sing-box -> xray' 'what apps use' 3 $true)
        } else {
            $nodes = Get-Nodes
            if ($nodes.Count -eq 0) { 'No nodes. Run: vpn update'; return }
            $base = 21100
            Write-Json $cfgPath (New-XrayTestConfig $nodes $base)
            $p = Start-Process -FilePath $XrayExe -ArgumentList ('run -c "{0}"' -f $cfgPath) -WorkingDirectory $Run -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds 2
            $selIdx = @((Select-Nodes $s $nodes) | ForEach-Object { $_.index })
            foreach ($n in $nodes) { $states += (& $mkState (Open-SocksUdp ($base + $n.index) 'stun.l.google.com' 19302) $n.name (Get-NodeKind $n) $n.index ($selIdx -contains $n.index)) }
        }
        $alive = @($states | Where-Object { -not $_.dead })
        $byHandle = @{}
        foreach ($st in $alive) { $byHandle[[string]$st.udp.Handle] = $st }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $buf = New-Object byte[] 2048
        $rnd = New-Object Random
        $drain = {
            param([double]$until)
            while ($true) {
                $left = $until - $sw.Elapsed.TotalMilliseconds
                if ($left -le 0) { break }
                $list = New-Object System.Collections.ArrayList
                foreach ($st in $alive) { [void]$list.Add($st.udp) }
                if ($list.Count -eq 0) { Start-Sleep -Milliseconds ([int][Math]::Min($left, 20)); continue }
                [Net.Sockets.Socket]::Select($list, $null, $null, [int]([Math]::Min($left, 20) * 1000))
                foreach ($sock in $list) {
                    try { $n = $sock.Receive($buf) } catch { continue }
                    $st = $byHandle[[string]$sock.Handle]
                    $off = 0
                    if (-not $st.raw) { $off = 10; if ($buf[3] -eq 3) { $off = 7 + $buf[4] } elseif ($buf[3] -eq 4) { $off = 22 } }
                    if ($n -lt $off + 20 -or $buf[$off] -ne 1 -or $buf[$off + 1] -ne 1) { continue }
                    $seq = $buf[$off + 8] * 16777216 + $buf[$off + 9] * 65536 + $buf[$off + 10] * 256 + $buf[$off + 11]
                    if ($seq -eq 4294967295) { $st.warm = $true; continue }
                    if ($seq -lt $count -and $st.rtt[$seq] -lt 0) { $st.rtt[$seq] = $sw.Elapsed.TotalMilliseconds - $st.sent[$seq] }
                }
            }
        }
        $send = {
            param($st, [long]$seq)
            $pkt = New-Object byte[] ($st.hdr.Length + 20)
            if ($st.hdr.Length) { [Array]::Copy($st.hdr, $pkt, $st.hdr.Length) }
            $o = $st.hdr.Length
            $pkt[$o + 1] = 1; $pkt[$o + 4] = 0x21; $pkt[$o + 5] = 0x12; $pkt[$o + 6] = 0xA4; $pkt[$o + 7] = 0x42
            $pkt[$o + 8] = [byte](($seq -shr 24) -band 255); $pkt[$o + 9] = [byte](($seq -shr 16) -band 255); $pkt[$o + 10] = [byte](($seq -shr 8) -band 255); $pkt[$o + 11] = [byte]($seq -band 255)
            for ($k = 12; $k -lt 20; $k++) { $pkt[$o + $k] = [byte]$rnd.Next(256) }
            try { [void]$st.udp.SendTo($pkt, $st.relay) } catch {}
        }
        # warm-up: the first packet makes xray open the tunnel to the node
        for ($w = 0; $w -lt 6; $w++) { foreach ($st in $alive) { if (-not $st.warm) { & $send $st 4294967295 } }; & $drain ($sw.Elapsed.TotalMilliseconds + 500) }
        "Measuring for $seconds s (one UDP packet every $interval ms through each path)..."
        $t0 = $sw.Elapsed.TotalMilliseconds
        for ($i = 0; $i -lt $count; $i++) {
            foreach ($st in $alive) { if ($st.warm) { $st.sent[$i] = $sw.Elapsed.TotalMilliseconds; & $send $st $i } }
            & $drain ($t0 + ($i + 1) * $interval)
        }
        & $drain ($sw.Elapsed.TotalMilliseconds + 1500)
    } finally {
        foreach ($st in $states) { try { if ($st.udp) { $st.udp.Close() }; if ($st.tcp) { $st.tcp.Close() } } catch {} }
        if ($p) { try { $p.Kill() } catch {} }
        Remove-Item $cfgPath -ErrorAction SilentlyContinue
    }
    $rows = @()
    foreach ($st in $states) {
        $row = [pscustomobject]@{ index = $st.index; name = $st.label; kind = $st.kind; sel = $st.selected; ok = $false; loss = 100.0; med = 0.0; p95 = 0.0; max = 0.0; jitter = 0.0; spikes = 0 }
        if (-not $st.dead -and $st.warm) {
            $got = @($st.rtt | Where-Object { $_ -ge 0 })
            if ($got.Count -gt 0) {
                $sorted = @($got | Sort-Object)
                $row.ok = $true
                $row.loss = 100.0 * ($count - $got.Count) / $count
                $row.med = $sorted[[int][Math]::Floor($sorted.Count / 2)]
                $row.p95 = $sorted[[int][Math]::Floor(($sorted.Count - 1) * 0.95)]
                $row.max = $sorted[$sorted.Count - 1]
                $prev = -1.0; $sum = 0.0; $k = 0
                foreach ($v in $st.rtt) { if ($v -ge 0) { if ($prev -ge 0) { $sum += [Math]::Abs($v - $prev); $k++ }; $prev = $v } }
                if ($k) { $row.jitter = $sum / $k }
                $row.spikes = @($got | Where-Object { $_ -gt $row.med + 60 }).Count
            }
        }
        $rows += $row
    }
    '  #  path                         type                  loss   median    p95     max   jitter  spikes(>median+60ms)'
    foreach ($r in $rows) {
        $mark = ' '; if ($r.sel) { $mark = '*' }
        if ($r.ok) { '{0}{1,2}  {2,-28} {3,-20} {4,4:N0}% {5,6:N0} ms {6,5:N0} {7,6:N0}  {8,5:N1} ms  {9,4}' -f $mark, $r.index, $r.name, $r.kind, $r.loss, $r.med, $r.p95, $r.max, $r.jitter, $r.spikes }
        else { '{0}{1,2}  {2,-28} {3,-20} no answer' -f $mark, $r.index, $r.name, $r.kind }
    }
    'Lower is better everywhere. For voice: loss ~0%, jitter under ~10 ms and few spikes matter more than the median.'
    if (-not $live) {
        $best = $rows | Where-Object { $_.ok -and $_.loss -lt 2 } | Sort-Object { $_.jitter * 3 + $_.spikes * 2 + $_.p95 / 10 } | Select-Object -First 3
        if ($best) { 'Steadiest right now: ' + (($best | ForEach-Object { "#$($_.index) $($_.name)" }) -join ', ') }
    }
}

$ListMap = @{
    'direct-exe' = 'apps'; 'proxy-exe' = 'apps'; 'block-exe' = 'block_processes'
    'direct-domain' = 'direct_domains'; 'proxy-domain' = 'proxy_domains'
    'direct-ip' = 'direct_ips'; 'proxy-ip' = 'proxy_ips'
}

function Edit-Rule([string]$op, $argv) {
    $argv = @($argv)
    if ($argv.Count -lt 2 -or -not $ListMap.ContainsKey($argv[0])) { "Usage: vpn $op <$(($ListMap.Keys | Sort-Object) -join '|')> <value> [value...]"; return }
    $key = $ListMap[$argv[0]]
    $s = Initialize-Settings
    if ($key -eq 'apps') {
        # exe rules are stored as apps with a vpn switch
        $touched = @()
        foreach ($v in $argv[1..($argv.Count - 1)]) {
            if ($v -notmatch '\.exe$') { $v += '.exe' }
            $touched += $v
            if ($op -eq 'add') { Set-AppEntry $s ($v -replace '\.exe$', '') ([string[]]@($v)) ($argv[0] -eq 'proxy-exe'); "set     $v -> $(if ($argv[0] -eq 'proxy-exe') {'vpn'} else {'direct'})" }
            else { Remove-AppProcess $s $v; "removed $v" }
        }
        Save-Settings $s
        [void](Write-RuleSets $s)
        Start-Sleep -Milliseconds 400
        Initialize-Api $s
        Close-ProcConnections ([string[]]$touched)
        'Applied without a restart; open connections of these programs were closed so they reconnect on the new route.'
        return
    }
    [string[]]$cur = L $s.rules.$key
    foreach ($v in $argv[1..($argv.Count - 1)]) {
        if ($op -eq 'add') { if ($cur -notcontains $v) { $cur += $v; "added   $($argv[0]): $v" } else { "exists  $($argv[0]): $v" } }
        else { if ($cur -contains $v) { $cur = [string[]]@($cur | Where-Object { $_ -ne $v }); "removed $($argv[0]): $v" } else { "absent  $($argv[0]): $v" } }
    }
    $s.rules.$key = [string[]]$cur
    Save-Settings $s
    [void](Write-RuleSets $s)
    Start-Sleep -Milliseconds 400
    Initialize-Api $s
    $n = 0
    if ($key -ne 'block_processes') { $n = Close-HostConnections ($argv[1..($argv.Count - 1)]) } else { Close-ProcConnections ([string[]]$argv[1..($argv.Count - 1)]) }
    "Applied without a restart; open connections to these addresses closed: $n."
}

function Show-Rules {
    $s = Get-Settings
    "default: unmatched traffic -> $($s.default)"
    'apps (exe switches):'
    foreach ($a in (Get-Apps $s)) { '  [{0}] {1,-20} {2}' -f $(if ($a.vpn) { 'vpn   ' } else { 'direct' }), $a.name, ($a.processes -join ', ') }
    foreach ($k in ($ListMap.Keys | Where-Object { $ListMap[$_] -ne 'apps' } | Sort-Object)) { '{0,-14}: {1}' -f $k, ((L $s.rules.($ListMap[$k])) -join ', ') }
    if ($s.ru_direct -and $s.ru_direct.enabled) { "ru_direct     : geoip $((L $s.ru_direct.geoip) -join ',') + geosite $((L $s.ru_direct.geosite) -join ',') -> direct; geosite $((L $s.ru_direct.blocked_geosite) -join ',') -> vpn" }
    'Order: block-exe, apps, domain/ip lists (the list equal to the default is an override and goes first), blocked-in-RU -> vpn, Russian sites/IPs -> direct, default.'
}

function Set-Option([string]$name, [string]$value, $allowed) {
    if (-not $value -or ($allowed -and $allowed -notcontains $value)) { "Usage: vpn $name <$($allowed -join '|')>"; return }
    $s = Get-Settings
    $s.$name = $value
    Save-Settings $s
    "$name = $value"
    if (Request-Reload) { Show-Status }
}

function Install-Autostart {
    $log = Join-Path $Run 'install.log'
    if (-not (Test-Admin)) {
        Remove-Item $log -ErrorAction SilentlyContinue
        'Requesting elevation (approve the UAC prompt)...'
        try {
            $p = Start-Process -FilePath $PowerShellExe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" install {1}' -f $PSCommandPath, $Identity.User.Value)
            [void]$p.WaitForExit(120000)
            if ($p.HasExited -and $p.ExitCode -eq 5) { 'Use the same account to approve UAC.'; return }
        } catch { "Elevation was declined or failed: $_"; return }
        if (Test-Path $log) { Get-Content $log } else { 'No result from the elevated installer.' }
        return
    }
    try {
        $user = $Identity.Name
        $action = New-ScheduledTaskAction -Execute $ConsoleHost -Argument $DaemonArguments -WorkingDirectory $Root
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $set -Description 'VlessClient: xray + sing-box (TUN, split tunneling, local proxy)' -Force | Out-Null
        Write-Text $log "Autostart installed: scheduled task '$TaskName' runs elevated at logon of $user."
    } catch { Write-Text $log "Install failed: $_" }
    Get-Content $log
}

function Uninstall-Autostart {
    $log = Join-Path $Run 'install.log'
    if (-not (Get-Task)) { 'Autostart is not installed.'; return }
    if (-not (Test-Admin)) {
        Remove-Item $log -ErrorAction SilentlyContinue
        'Requesting elevation (approve the UAC prompt)...'
        try {
            $p = Start-Process -FilePath $PowerShellExe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" uninstall {1}' -f $PSCommandPath, $Identity.User.Value)
            [void]$p.WaitForExit(120000)
            if ($p.HasExited -and $p.ExitCode -eq 5) { 'Use the same account to approve UAC.'; return }
        } catch { "Elevation was declined or failed: $_"; return }
        if (Test-Path $log) { Get-Content $log }
        return
    }
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Text $log 'Autostart removed.' } catch { Write-Text $log "Uninstall failed: $_" }
    Get-Content $log
}

function Show-Logs($argv) {
    $argv = @($argv)
    $which = 'daemon'; if ($argv.Count -ge 1 -and $argv[0]) { $which = $argv[0] }
    $n = 40; if ($argv.Count -ge 2) { $n = [int]$argv[1] }
    $map = @{ 'daemon' = $DaemonLog; 'xray' = $XrayLog; 'sing-box' = $SingLog; 'singbox' = $SingLog }
    if (-not $map.ContainsKey($which)) { 'Usage: vpn logs <daemon|xray|sing-box> [lines]'; return }
    if (Test-Path $map[$which]) { Get-Content $map[$which] -Tail $n -Encoding UTF8 } else { "No log yet: $($map[$which])" }
}

function Invoke-Doctor {
    $s = Get-Settings
    $st = Get-State
    "== VlessClient =="
    Show-Status
    ''
    '== Adapters =='
    Get-NetAdapter | Where-Object { $_.Status -ne 'Not Present' } | ForEach-Object { '{0,-28} {1,-12} {2}' -f $_.Name, $_.Status, $_.InterfaceDescription }
    ''
    '== IPv4 default / split routes =='
    $tunRoutes = @(Get-NetRoute -AddressFamily IPv4 -InterfaceAlias "$($s.tun.name)" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' })
    "$($s.tun.name): $($tunRoutes.Count) split routes (everything except excluded ranges)"
    Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or ($_.DestinationPrefix -match '/[1-8]$' -and $_.InterfaceAlias -ne "$($s.tun.name)" -and $_.DestinationPrefix -notmatch '^(224|127)\.') } | Sort-Object InterfaceAlias | ForEach-Object { '{0,-18} via {1,-15} metric {2,-4} {3}' -f $_.DestinationPrefix, $_.NextHop, ([int]$_.RouteMetric + [int]$_.InterfaceMetric), $_.InterfaceAlias }
    ''
    '== DNS per adapter =='
    Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object { '{0,-28} {1}' -f $_.InterfaceAlias, ($_.ServerAddresses -join ', ') }
    "Direct DNS used by sing-box in tun mode: $(Get-DirectDns $s)"
    ''
    '== NRPT (per-suffix DNS, used by Check Point) =='
    $nrpt = @(Get-DnsClientNrptPolicy -ErrorAction SilentlyContinue)
    if ($nrpt.Count) { $nrpt | ForEach-Object { '{0,-28} -> {1}' -f ($_.Namespace -join ','), ($_.NameServers -join ', ') } } else { '(none)' }
    ''
    '== Check Point =='
    $trac = Join-Path "$($s.checkpoint.path)" 'Endpoint Connect\trac.exe'
    if (Test-Path $trac) {
        $r = Invoke-Capture $trac 'info' 6000
        ($r.out -split "`r?`n" | Where-Object { $_ -match 'Conn |gw:|status:|\*' }) | ForEach-Object { $_.TrimEnd() }
    } else { "trac.exe not found under $($s.checkpoint.path)" }
    $ex = Get-CheckpointExcludes $s
    "Gateway IPs kept out of the tunnel: $($ex -join ', ')"
    $targets = @()
    foreach ($e in $ex) { $targets += ($e -split '/')[0] }
    foreach ($x in $nrpt) { foreach ($ns in $x.NameServers) { $targets += "$ns" } }
    foreach ($t in ($targets | Select-Object -Unique)) {
        try {
            $fr = Find-NetRoute -RemoteIPAddress $t -ErrorAction Stop | Select-Object -Last 1
            '  route to {0,-16} -> {1}' -f $t, $fr.InterfaceAlias
        } catch { "  route to $t -> (lookup failed)" }
    }
    if ($st -and $st.tun) { 'Expected: none of the lines above may point to ' + $s.tun.name + '.' }
}

function Show-Help {
    @'
VlessClient - xray (VLESS) + sing-box (TUN, split tunneling, local proxy)

  vpn ui                     open the desktop window (app rules and live traffic)
  vpn status                 state, mode, node, exit IP
  vpn start | stop | restart
  vpn reload                 re-read settings.json and restart the cores
  vpn update                 re-download the subscription
  vpn nodes                  list nodes
  vpn test                   check every node (latency + exit IP)
  vpn quality [seconds]      UDP loss / latency / jitter through every node (pick a node for voice chat)
  vpn use <auto|N|name>      pick a node (auto = fastest alive)
  vpn mode <tun|proxy>       tun = system-wide + per-exe rules; proxy = local proxy only
  vpn default <proxy|direct> where unmatched traffic goes
  vpn rules                  show split-tunneling lists
  vpn add    <list> <value...>   lists: direct-exe proxy-exe block-exe direct-domain proxy-domain direct-ip proxy-ip
  vpn remove <list> <value...>
  vpn install | uninstall    autostart at logon (elevated scheduled task; one UAC prompt)
  vpn doctor                 routes / DNS / Check Point diagnostics
  vpn logs [daemon|xray|sing-box] [lines]

Settings live in settings.json next to this script.
'@
}

# ---------------------------------------------------------------- web UI (local page on http://localhost:<ui.port>/)
# The desktop worker runs as the user and watches connections through the sing-box Clash API.
# Statistics exist only while the desktop window is open.

$script:Conns = @{}      # live connections: id -> info
$script:Stats = @{}      # per exe: key -> counters
$script:DestMap = @{}    # 'host:port' / 'ip:port' -> last exe that connected there
$script:LogPos = -1
$script:FirstPoll = $true
$script:LastTick = $null
$script:ApiOk = $false
$script:ProcCache = $null
$script:ProcCacheTime = [DateTime]::MinValue
$script:PathCache = @{}

function Invoke-Clash([string]$method, [string]$path) {
    try {
        $req = [Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}{1}' -f $script:ApiPort, $path))
        $req.Method = $method
        $req.Timeout = 1500
        $req.ReadWriteTimeout = 1500
        $req.Proxy = $null
        $req.Headers['Authorization'] = 'Bearer ' + $script:ApiSecret
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return "$t"
    } catch { return $null }
}

function Get-ExeFromPath([string]$processPath) {
    if (-not $processPath) { return '' }
    $m = [regex]::Match($processPath, '^(.*?\.exe)( \(.*\))?$', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return $processPath
}

function Get-Stat([string]$key, [string]$name, [string]$path) {
    $st = $script:Stats[$key]
    if (-not $st) {
        # up/down = bytes since the UI server started; pBytes/dBytes = the same split by route (VPN / direct);
        # t* = bytes in the current tick; r* = smoothed bytes per second; hosts = per-destination counters.
        $st = @{ key = $key; name = $name; path = $path; total = 0; ok = 0; fail = 0; udp = 0; up = [long]0; down = [long]0; proxy = 0; direct = 0; fproxy = 0; fdirect = 0; fails = (New-Object System.Collections.ArrayList); last = (Get-Date)
            pBytes = [long]0; dBytes = [long]0; tUp = [long]0; tDown = [long]0; tP = [long]0; tD = [long]0; rUp = 0.0; rDown = 0.0; rP = 0.0; rD = 0.0; hosts = @{}
        }
        $script:Stats[$key] = $st
    }
    if ($path -and -not $st.path) { $st.path = $path }
    return $st
}

function Add-Fail($st, [string]$dest, [string]$out, [string]$reason, [bool]$udp) {
    if ($udp) { $st.udp++ } else { $st.fail++; if ($out -eq 'proxy') { $st.fproxy++ } else { $st.fdirect++ } }
    $st.last = Get-Date
    if ($st.fails.Count -gt 0 -and $st.fails[0].dest -eq $dest -and $st.fails[0].reason -eq $reason -and $st.fails[0].out -eq $out) {
        $st.fails[0].n++; $st.fails[0].t = (Get-Date).ToString('HH:mm:ss'); return
    }
    $st.fails.Insert(0, @{ t = (Get-Date).ToString('HH:mm:ss'); dest = $dest; out = $out; reason = $reason; udp = $udp; n = 1 })
    while ($st.fails.Count -gt 10) { $st.fails.RemoveAt($st.fails.Count - 1) }
}

# Polls /connections. A connection that sent data but never received a byte counts as a problem.
function Update-ConnStats {
    $raw = Invoke-Clash 'GET' '/connections'
    if ($null -eq $raw) { $script:ApiOk = $false; return }
    $script:ApiOk = $true
    $json = $script:Js.DeserializeObject($raw)
    $now = Get-Date
    $seen = @{}
    $list = $json['connections']
    if ($list) {
        foreach ($c in $list) {
            $id = "$($c['id'])"
            $seen[$id] = 1
            $t = $script:Conns[$id]
            if (-not $t) {
                $m = $c['metadata']
                $path = Get-ExeFromPath "$($m['processPath'])"
                $name = '(unknown)'; $key = '(unknown)'
                if ($path) { $name = [IO.Path]::GetFileName($path); $key = $name.ToLower() }
                $port = "$($m['destinationPort'])"
                $ipDest = "$($m['destinationIP']):$port"
                if ("$($m['destinationIP'])".Contains(':')) { $ipDest = "[$($m['destinationIP'])]:$port" }
                $dest = $ipDest
                if ($m['host']) { $dest = "$($m['host']):$port" }
                $out = 'proxy'
                $chains = @($c['chains'])
                if ($chains -contains 'direct') { $out = 'direct' } elseif ($chains -notcontains 'proxy' -and $chains.Count) { $out = "$($chains[0])" }
                $hostKey = "$($m['destinationIP'])"
                if ($m['host']) { $hostKey = "$($m['host'])" }
                $t = @{ key = $key; dest = $dest; hostKey = $hostKey; udp = ("$($m['network'])" -eq 'udp'); out = $out; start = $now; up = [long]0; down = [long]0; flagged = $false }
                # Connections that were already open when the server started: count only what they transfer from now on.
                if ($script:FirstPoll) { $t.up = [long]$c['upload']; $t.down = [long]$c['download'] }
                $script:Conns[$id] = $t
                $st = Get-Stat $key $name $path
                $st.total++
                if ($out -eq 'direct') { $st.direct++ } else { $st.proxy++ }
                $script:DestMap[$ipDest] = @{ key = $key; time = $now }
                $script:DestMap[$dest] = @{ key = $key; time = $now }
            }
            $up = [long]$c['upload']; $down = [long]$c['download']
            if ($up -ne $t.up -or $down -ne $t.down) {
                $st = $script:Stats[$t.key]
                $du = $up - $t.up; $dd = $down - $t.down
                $st.up += $du; $st.down += $dd; $st.last = $now
                $st.tUp += $du; $st.tDown += $dd
                if ($t.out -eq 'direct') { $st.dBytes += ($du + $dd); $st.tD += ($du + $dd) } else { $st.pBytes += ($du + $dd); $st.tP += ($du + $dd) }
                $hs = $st.hosts[$t.hostKey]
                if (-not $hs) { $hs = @{ host = $t.hostKey; out = $t.out; up = [long]0; down = [long]0; tUp = [long]0; tDown = [long]0; rUp = 0.0; rDown = 0.0; last = $now }; $st.hosts[$t.hostKey] = $hs }
                $hs.up += $du; $hs.down += $dd; $hs.tUp += $du; $hs.tDown += $dd; $hs.out = $t.out; $hs.last = $now
                $t.up = $up; $t.down = $down
            }
            if (-not $t.flagged -and $down -eq 0 -and $up -gt 0 -and ($now - $t.start).TotalSeconds -ge 6) {
                $t.flagged = $true
                Add-Fail $script:Stats[$t.key] $t.dest $t.out 'no-answer' $t.udp
            }
        }
    }
    foreach ($id in @($script:Conns.Keys)) {
        if ($seen.ContainsKey($id)) { continue }
        $t = $script:Conns[$id]
        if (-not $t.flagged) {
            if ($t.down -gt 0) { $script:Stats[$t.key].ok++ }
            elseif ($t.up -gt 0 -and ($now - $t.start).TotalSeconds -ge 2) { Add-Fail $script:Stats[$t.key] $t.dest $t.out 'no-answer' $t.udp }
        }
        $script:Conns.Remove($id)
    }
    if ($script:DestMap.Count -gt 4000) {
        foreach ($k in @($script:DestMap.Keys)) { if (($now - $script:DestMap[$k].time).TotalSeconds -gt 60) { $script:DestMap.Remove($k) } }
    }

    # Turn this tick's byte counts into smoothed speeds (bytes per second).
    $dt = 1.0
    if ($script:LastTick) { $dt = ($now - $script:LastTick).TotalSeconds; if ($dt -lt 0.2) { $dt = 0.2 } }
    $script:LastTick = $now
    $script:FirstPoll = $false
    foreach ($st in $script:Stats.Values) {
        $st.rUp = 0.5 * $st.rUp + 0.5 * ($st.tUp / $dt); if ($st.rUp -lt 50) { $st.rUp = 0.0 }
        $st.rDown = 0.5 * $st.rDown + 0.5 * ($st.tDown / $dt); if ($st.rDown -lt 50) { $st.rDown = 0.0 }
        $st.rP = 0.5 * $st.rP + 0.5 * ($st.tP / $dt); if ($st.rP -lt 50) { $st.rP = 0.0 }
        $st.rD = 0.5 * $st.rD + 0.5 * ($st.tD / $dt); if ($st.rD -lt 50) { $st.rD = 0.0 }
        $st.tUp = [long]0; $st.tDown = [long]0; $st.tP = [long]0; $st.tD = [long]0
        if ($st.hosts.Count) {
            foreach ($hs in $st.hosts.Values) {
                $hs.rUp = 0.5 * $hs.rUp + 0.5 * ($hs.tUp / $dt); if ($hs.rUp -lt 50) { $hs.rUp = 0.0 }
                $hs.rDown = 0.5 * $hs.rDown + 0.5 * ($hs.tDown / $dt); if ($hs.rDown -lt 50) { $hs.rDown = 0.0 }
                $hs.tUp = [long]0; $hs.tDown = [long]0
            }
            if ($st.hosts.Count -gt 120) {
                # keep the list bounded: drop the destinations that have been silent the longest
                $drop = @($st.hosts.Values | Sort-Object { $_.last } | Select-Object -First ($st.hosts.Count - 80) | ForEach-Object { $_.host })
                foreach ($k in $drop) { $st.hosts.Remove($k) }
            }
        }
    }
}

# Reads new ERROR lines from sing-box.log (failed dials) and attributes them to the exe that connected to that address.
function Read-NewLogErrors {
    $text = $null
    try { $fs = [IO.File]::Open($SingLog, 'Open', 'Read', 'ReadWrite, Delete') } catch { return }
    try {
        if ($script:LogPos -lt 0 -or $script:LogPos -gt $fs.Length) { $script:LogPos = $fs.Length }
        if ($fs.Length -gt $script:LogPos) {
            $fs.Position = $script:LogPos
            $len = [int][Math]::Min($fs.Length - $script:LogPos, 262144)
            $buf = New-Object byte[] $len
            $n = $fs.Read($buf, 0, $len)
            $script:LogPos += $n
            $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        }
    } finally { $fs.Close() }
    if (-not $text) { return }
    $now = Get-Date
    foreach ($line in ($text -split "`n")) {
        if ($line.IndexOf('ERROR') -lt 0) { continue }
        $m = [regex]::Match(($line -replace "\x1b\[[0-9;]*m", ''), 'connection: open connection to (\S+) using outbound/[\w-]+\[([\w-]+)\]: (.+)$')
        if (-not $m.Success) { continue }
        $dest = $m.Groups[1].Value; $out = $m.Groups[2].Value; $msg = $m.Groups[3].Value
        $reason = 'error'
        if ($msg -match 'timeout|timed out|did not properly respond') { $reason = 'timeout' }
        elseif ($msg -match 'refused') { $reason = 'refused' }
        elseif ($msg -match 'reset|forcibly closed|aborted') { $reason = 'reset' }
        elseif ($msg -match 'unreachable|no route') { $reason = 'unreachable' }
        elseif ($msg -match 'lookup|empty result') { $reason = 'dns' }
        $key = '(unknown)'
        $d = $script:DestMap[$dest]
        if ($d -and ($now - $d.time).TotalSeconds -lt 30) { $key = $d.key }
        $st = Get-Stat $key $key ''
        Add-Fail $st $dest $out $reason $false
    }
}

function Get-RunningProcs {
    if ($script:ProcCache -and ((Get-Date) - $script:ProcCacheTime).TotalSeconds -lt 5) { return $script:ProcCache }
    $map = @{}
    foreach ($p in [Diagnostics.Process]::GetProcesses()) {
        try {
            $name = $p.ProcessName + '.exe'
            $key = $name.ToLower()
            $e = $map[$key]
            if (-not $e) { $e = @{ name = $name; path = "$($script:PathCache[$key])"; window = $false }; $map[$key] = $e }
            if (-not $e.window -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $e.window = $true }
            if (-not $e.path -and -not $script:PathCache.ContainsKey($key)) {
                $fp = ''
                try { $fp = "$($p.MainModule.FileName)" } catch {}
                $script:PathCache[$key] = $fp
                $e.path = $fp
            }
        } catch {} finally { $p.Dispose() }
    }
    $script:ProcCache = $map
    $script:ProcCacheTime = Get-Date
    return $map
}

function Get-UiState([bool]$all) {
    $s = Get-Settings
    $st = Get-State
    $running = Test-DaemonRunning
    $procs = Get-RunningProcs
    $apps = Get-Apps $s
    $appOf = @{}
    $appList = @()
    foreach ($a in $apps) {
        $isRun = $false
        foreach ($p in $a.processes) { $appOf[$p.ToLower()] = $a; if ($procs.ContainsKey($p.ToLower())) { $isRun = $true } }
        $appList += @{ name = $a.name; processes = @($a.processes); vpn = $a.vpn; running = $isRun }
    }
    $active = @{}
    foreach ($c in $script:Conns.Values) { $active[$c.key] = 1 + [int]$active[$c.key] }

    $keys = @{}
    foreach ($k in $script:Stats.Keys) { $keys[$k] = 1 }
    foreach ($k in $procs.Keys) { if ($all -or $procs[$k].window -or $appOf.ContainsKey($k)) { $keys[$k] = 1 } }
    $rows = @()
    foreach ($k in $keys.Keys) {
        $x = $script:Stats[$k]; $p = $procs[$k]
        $row = @{ key = $k; name = $k; path = ''; running = [bool]$p; window = $false; app = ''; vpn = $null
            total = 0; active = [int]$active[$k]; ok = 0; fail = 0; udp = 0; up = 0; down = 0; proxy = 0; direct = 0; fproxy = 0; fdirect = 0; fails = @(); last = 0
            rUp = 0; rDown = 0; rP = 0; rD = 0; pBytes = 0; dBytes = 0; hosts = @(); nHosts = 0
        }
        if ($p) { $row.name = $p.name; $row.path = $p.path; $row.window = $p.window }
        if ($x) {
            if (-not $p) { $row.name = $x.name }
            if (-not $row.path) { $row.path = $x.path }
            $row.total = $x.total; $row.ok = $x.ok; $row.fail = $x.fail; $row.udp = $x.udp; $row.up = $x.up; $row.down = $x.down
            $row.proxy = $x.proxy; $row.direct = $x.direct; $row.fproxy = $x.fproxy; $row.fdirect = $x.fdirect
            $row.fails = @($x.fails)
            $row.rUp = [long]$x.rUp; $row.rDown = [long]$x.rDown; $row.rP = [long]$x.rP; $row.rD = [long]$x.rD
            $row.pBytes = $x.pBytes; $row.dBytes = $x.dBytes
            $row.hosts = @($x.hosts.Values | Sort-Object @{ Expression = { $_.rUp + $_.rDown }; Descending = $true }, @{ Expression = { $_.up + $_.down }; Descending = $true } | Select-Object -First 10 | ForEach-Object { @{ host = $_.host; out = $_.out; up = $_.up; down = $_.down; rUp = [long]$_.rUp; rDown = [long]$_.rDown } })
            $row.nHosts = $x.hosts.Count
            $row.last = [long]($x.last.ToUniversalTime() - [DateTime]'1970-01-01').TotalSeconds
        }
        $a = $appOf[$k]
        if ($a) { $row.app = $a.name; $row.vpn = $a.vpn }
        $rows += $row
    }
    $geo = @(0, 0, 0)
    $gi = Join-Path $RulesDir 'geo.info'
    if (Test-Path $gi) { $geo = @(([IO.File]::ReadAllText($gi) -split ' ') | ForEach-Object { [int]$_ }) }
    return @{
        status  = @{
            running = $running; tun = [bool]($running -and $st.tun); admin = [bool]($running -and $st.admin); node = "$(if ($running) { $st.node } else { $s.node })"
            ready = [bool]($running -and (Test-Pid $st.xray_pid 'xray') -and (Test-Pid $st.singbox_pid 'sing-box'))
            error = "$(if ($running) { $st.error })"; mode = "$($s.mode)"; default = "$($s.default)"; since = "$(if ($running) { $st.started })"
            api = $script:ApiOk; proxy = ('{0}:{1}' -f $s.proxy.listen, $s.proxy.port)
            ruDirect = [bool]($s.ru_direct -and $s.ru_direct.enabled); geo = $geo
        }
        apps    = $appList
        rows    = $rows
        domains = @{ direct = @((L $s.rules.direct_domains) + (L $s.rules.direct_ips)); proxy = @((L $s.rules.proxy_domains) + (L $s.rules.proxy_ips)) }
        configured = [bool]$s.subscription.url
    }
}

function Close-ProcConnections([string[]]$procs) {
    $lower = @($procs | ForEach-Object { $_.ToLower() })
    $raw = Invoke-Clash 'GET' '/connections'
    if (-not $raw) { return }
    $json = $script:Js.DeserializeObject($raw)
    if (-not $json['connections']) { return }
    foreach ($c in $json['connections']) {
        $path = Get-ExeFromPath "$($c['metadata']['processPath'])"
        if ($path -and ($lower -contains [IO.Path]::GetFileName($path).ToLower())) { [void](Invoke-Clash 'DELETE' ('/connections/' + $c['id'])) }
    }
}

# Makes Invoke-Clash usable outside the UI server (CLI commands).
function Initialize-Api($s) {
    $script:ApiPort = [int]$s.api.port
    $script:ApiSecret = "$($s.api.secret)"
    if (-not $script:Js) {
        Add-Type -AssemblyName System.Web.Extensions
        $script:Js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $script:Js.MaxJsonLength = 67108864
    }
}

# Closes live connections to the given list entries (domains, full:, keyword:, IPv4 or IPv4 CIDR) so that
# they are re-opened under the new rule. regex: entries are skipped.
function Close-HostConnections($entries) {
    $doms = @(); $nets = @()
    foreach ($e in (L $entries)) {
        $v = $e.ToLower()
        if ($v.StartsWith('regex:')) { continue }
        if ($v.StartsWith('full:')) { $doms += @{ exact = $v.Substring(5) }; continue }
        if ($v.StartsWith('keyword:')) { $doms += @{ kw = $v.Substring(8) }; continue }
        $m = [regex]::Match($v, '^(\d{1,3}(\.\d{1,3}){3})(/(\d{1,2}))?$')
        if ($m.Success) {
            $b = [Net.IPAddress]::Parse($m.Groups[1].Value).GetAddressBytes()
            $bits = 32; if ($m.Groups[4].Success) { $bits = [int]$m.Groups[4].Value }
            $nets += @{ n = ([double]$b[0] * 16777216 + [double]$b[1] * 65536 + [double]$b[2] * 256 + [double]$b[3]); div = [Math]::Pow(2, 32 - $bits) }
            continue
        }
        if ($v -match ':') { continue }
        $doms += @{ suffix = $v.TrimStart('.') }
    }
    if (($doms.Count + $nets.Count) -eq 0) { return 0 }
    $raw = Invoke-Clash 'GET' '/connections'
    if (-not $raw) { return 0 }
    $json = $script:Js.DeserializeObject($raw)
    if (-not $json['connections']) { return 0 }
    $closed = 0
    foreach ($c in $json['connections']) {
        $h = "$($c['metadata']['host'])".ToLower()
        $ip = "$($c['metadata']['destinationIP'])"
        $hit = $false
        if ($h) {
            foreach ($d in $doms) {
                if ($d.exact -and $h -eq $d.exact) { $hit = $true }
                elseif ($d.kw -and $h.Contains($d.kw)) { $hit = $true }
                elseif ($d.suffix -and ($h -eq $d.suffix -or $h.EndsWith('.' + $d.suffix))) { $hit = $true }
                if ($hit) { break }
            }
        }
        if (-not $hit -and $nets.Count -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
            $b = [Net.IPAddress]::Parse($ip).GetAddressBytes()
            $n = [double]$b[0] * 16777216 + [double]$b[1] * 65536 + [double]$b[2] * 256 + [double]$b[3]
            foreach ($net in $nets) { if ([Math]::Floor($n / $net.div) -eq [Math]::Floor($net.n / $net.div)) { $hit = $true; break } }
        }
        if ($hit) { [void](Invoke-Clash 'DELETE' ('/connections/' + $c['id'])); $closed++ }
    }
    return $closed
}

function Invoke-DesktopAction([string]$action, $d) {
    if (-not $d) { return @{ ok = $false; error = 'bad-request' } }
    switch ($action) {
        'app' {
            $s = Initialize-Settings
            $name = "$($d.name)".Trim()
            if (-not $name -or $name.Length -gt 60) { return @{ ok = $false; error = 'bad-name' } }
            $existing = (Get-Apps $s) | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if ("$($d.op)" -eq 'remove') {
                if (-not $existing) { return @{ ok = $false; error = 'not-found' } }
                Remove-AppEntry $s $name
                Save-Settings $s; [void](Write-RuleSets $s)
                Close-ProcConnections $existing.processes
                return @{ ok = $true }
            }
            $procs = [string[]]@()
            if ($d.processes) { $procs = L $d.processes } elseif ($existing) { $procs = $existing.processes }
            if ($procs.Count -eq 0) { return @{ ok = $false; error = 'no-processes' } }
            foreach ($p in $procs) { if ($p -notmatch '^[^\\/:*?"<>|\r\n]{1,100}\.exe$') { return @{ ok = $false; error = 'bad-exe' } } }
            Set-AppEntry $s $name $procs ([bool]$d.vpn)
            Save-Settings $s; [void](Write-RuleSets $s)
            Start-Sleep -Milliseconds 400   # let sing-box pick up the changed rule-set before cutting connections
            Close-ProcConnections $procs
            return @{ ok = $true }
        }
        'domain' {
            $s = Initialize-Settings
            $list = "$($d.list)"; $value = "$($d.value)".Trim().ToLower()
            if ($list -ne 'direct' -and $list -ne 'proxy') { return @{ ok = $false; error = 'bad-list' } }
            if ($value -match '^https?://') { $value = $value -replace '^https?://', '' -replace '/.*$', '' }
            if ($value -notmatch '^\S{1,200}$' -or $value -match '["\\<>]') { return @{ ok = $false; error = 'bad-value' } }
            $isIp = ($value -match '^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$') -or ($value -match '^[0-9a-f:]+:[0-9a-f:]*(/\d{1,3})?$')
            $key = "${list}_domains"; if ($isIp) { $key = "${list}_ips" }
            [string[]]$cur = L $s.rules.$key
            if ("$($d.op)" -eq 'remove') { $cur = [string[]]@($cur | Where-Object { $_ -ne $value }) }
            elseif ($cur -notcontains $value) { $cur += $value }
            $s.rules.$key = [string[]]$cur
            Save-Settings $s; [void](Write-RuleSets $s)
            Start-Sleep -Milliseconds 400   # let sing-box pick up the changed rule-set before cutting connections
            [void](Close-HostConnections @($value))
            return @{ ok = $true }
        }
        'reset' {
            $script:Stats = @{}; $script:Conns = @{}; $script:DestMap = @{}; $script:FirstPoll = $true
            return @{ ok = $true }
        }
        'control' {
            $op = "$($d.op)"
            if (@('start', 'stop', 'restart') -notcontains $op) { return @{ ok = $false; error = 'bad-op' } }
            if ($op -in @('stop', 'restart')) {
                $message = (Stop-Client) -join "`n"
                if (Test-DaemonRunning) { throw $message }
            }
            if ($op -in @('start', 'restart')) { Start-DesktopClient }
            return @{ ok = $true }
        }
        'settings' {
            $s = Get-Settings
            $task = Get-Task
            $nodes = @((Get-Nodes) | ForEach-Object { @{ index = $_.index; name = $_.name } })
            return @{ ok = $true; mode = $s.mode; default = $s.default; node = $s.node; nodes = $nodes
                configured = [bool]$s.subscription.url; insecureTls = [bool]$s.subscription.insecure_tls
                autostart = [bool]$task; path = $SettingsPath }
        }
        'save-settings' {
            $s = Initialize-Settings
            $url = "$($d.url)".Trim()
            $mode = "$($d.mode)"
            $route = "$($d.default)"
            $node = "$($d.node)".Trim()
            if ($mode -notin @('tun', 'proxy') -or $route -notin @('proxy', 'direct') -or -not $node) { throw 'bad-request' }
            if ($url) {
                $uri = $null
                if ($url -notmatch '^https?://[^\x00-\x20"\x7f]+$' -or $url.EndsWith('\') -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or -not $uri.Host) { throw 'bad-subscription' }
                $s.subscription.url = $url
            }
            $s.subscription.insecure_tls = [bool]$d.insecureTls
            if ($url -and -not (Update-Subscription $s)) { throw 'subscription-fetch' }
            $s.mode = $mode; $s.default = $route; $s.node = $node
            Save-Settings $s
            if ((Test-DaemonRunning) -and $mode -eq 'tun' -and -not (Get-State).admin) {
                [void](Stop-Client)
                if (Test-DaemonRunning) { throw 'stop-failed' }
                Start-DesktopClient
            } else { [void](Request-Reload) }
            return @{ ok = $true }
        }
        'update' {
            if (-not (Update-Subscription)) { throw 'subscription-fetch' }
            [void](Request-Reload)
            return @{ ok = $true }
        }
        'import-settings' {
            if (Test-DaemonRunning) { throw 'stop-before-import' }
            try { $source = Get-Content -LiteralPath "$($d.path)" -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { throw 'bad-import' }
            if (-not ($source -is [pscustomobject]) -or -not $source.subscription -or -not $source.proxy -or
                -not $source.tun -or -not $source.rules -or $source.mode -notin @('tun', 'proxy') -or
                $source.default -notin @('direct', 'proxy') -or -not $source.node) { throw 'bad-import' }
            if ($source.api) { $source.api.secret = '' }
            Save-Settings $source
            Remove-Item -LiteralPath $SubCache, $SubHeaders -ErrorAction SilentlyContinue
            [void](Initialize-Settings)
            return @{ ok = $true }
        }
        'autostart' {
            if ([bool]$d.enabled) { $message = (Install-Autostart) -join "`n" } else { $message = (Uninstall-Autostart) -join "`n" }
            if ([bool](Get-Task) -ne [bool]$d.enabled) { throw $message }
            return @{ ok = $true }
        }
    }
    return @{ ok = $false; error = 'not-found' }
}

function Start-DesktopClient {
    $s = Get-Settings
    if (-not "$($s.subscription.url)") { throw 'subscription-required' }
    if ($s.mode -eq 'tun' -and -not (Test-Admin)) {
        try { [void](Start-Client -Quiet -RequireTun) }
        catch {
            if ($_.Exception.Message -ne 'elevation-required') { throw }
            $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" desktop-start {1}' -f $PSCommandPath, $Identity.User.Value
            try { $child = Start-Process -FilePath $PowerShellExe -ArgumentList $args -Verb RunAs -WindowStyle Hidden -PassThru }
            catch { throw 'elevation-declined' }
            if (-not $child.WaitForExit(105000)) { throw 'start-timeout' }
            if ($child.ExitCode -eq 5) { throw 'elevation-account' }
            if ($child.ExitCode -ne 0) { throw 'start-failed' }
        }
    } else { [void](Start-Client -Quiet) }
    $st = Get-State
    if ($st -and $st.error) { throw "$($st.error)" }
    if (-not (Test-DaemonRunning) -or -not (Test-Pid $st.singbox_pid 'sing-box') -or -not (Test-Pid $st.xray_pid 'xray')) { throw 'start-failed' }
    if ($s.mode -eq 'tun' -and -not $st.tun) { throw 'elevation-required' }
}

function Invoke-DesktopWorker {
    [Console]::InputEncoding = $Utf8
    [Console]::OutputEncoding = $Utf8
    while ($null -ne ($line = [Console]::ReadLine())) {
        try {
            $request = ConvertFrom-Json -InputObject $line
            Initialize-Api (Initialize-Settings)
            if ($request.action -eq 'state') {
                Update-ConnStats
                Read-NewLogErrors
                $reply = @{ ok = $true; state = (Get-UiState ([bool]$request.data.all)) }
            } else {
                $reply = Invoke-DesktopAction "$($request.action)" $request.data
            }
        } catch {
            $reply = @{ ok = $false; error = $_.Exception.Message }
        }
        [Console]::WriteLine(($reply | ConvertTo-Json -Depth 15 -Compress))
    }
}

function Open-Ui {
    $exe = Join-Path $Root 'VlessClient.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $Root 'desktop\bin\Release\net472\VlessClient.exe' }
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Desktop app not found. Install the MSI or build desktop/VlessClient.csproj in Release.' }
    Start-Process -FilePath $exe -WorkingDirectory $Root
}

# ---------------------------------------------------------------- dispatch

switch ($Command.ToLower()) {
    'daemon' { Invoke-Daemon }
    'desktop-start' {
        if ("$(@($Rest)[0])" -ne $Identity.User.Value -or -not (Test-Admin)) { exit 5 }
        try { [void](Start-Client -Quiet); exit 0 } catch { Write-Log "desktop: start failed: $_"; exit 1 }
    }
    'start' { Start-Client }
    'stop' { Stop-Client }
    'restart' { Stop-Client; Start-Client }
    'reload' { if (Request-Reload) { Show-Status } else { 'Not running. Use: vpn start' } }
    'status' { Show-Status }
    'update' { if (Update-Subscription) { Show-Nodes; if (Request-Reload) { 'Reloaded.' } } else { 'Subscription update FAILED (see: vpn logs daemon).' } }
    'nodes' { Show-Nodes }
    'test' { Invoke-NodeTest }
    'quality' { Invoke-QualityTest $Rest }
    'use' { $v = "$(@($Rest)[0])"; if (-not $v) { 'Usage: vpn use <auto|N|name>' } else { Set-Option 'node' $v $null } }
    'mode' { Set-Option 'mode' "$(@($Rest)[0])" @('tun', 'proxy') }
    'default' { Set-Option 'default' "$(@($Rest)[0])" @('proxy', 'direct') }
    'rules' { Show-Rules }
    'add' { Edit-Rule 'add' $Rest }
    'remove' { Edit-Rule 'remove' $Rest }
    'install' { if ($Rest -and "$($Rest[0])" -ne $Identity.User.Value) { exit 5 }; Install-Autostart }
    'uninstall' { if ($Rest -and "$($Rest[0])" -ne $Identity.User.Value) { exit 5 }; Uninstall-Autostart }
    'doctor' { Invoke-Doctor }
    'logs' { Show-Logs $Rest }
    'ui' { Open-Ui }
    'desktop-worker' { Invoke-DesktopWorker }
    'geo' { Initialize-Geo; $f = "$(@($Rest)[0])"; foreach ($d in 'geoip.dat', 'geosite.dat') { "== $d =="; [VcGeoDat]::Codes((Join-Path $Bin $d)) | Where-Object { -not $f -or $_ -match $f } } }
    'build' { [void](Update-Subscription); $i = Build-Configs ((Test-Admin) -or ("$(@($Rest)[0])" -eq 'tun')); if ($i.ok) { "OK: configs generated (tun=$($i.tun), node=$($i.node))" } else { "FAILED: $($i.error)" } }
    default { Show-Help }
}
