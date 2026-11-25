# BMS Patient Journey 3D - local web server + HOSxP API proxy (PowerShell version)
#
# start.bat uses this when Python 3.7+ is not installed. It needs only the
# Windows PowerShell 5.1 that ships with Windows 10/11: no install.
#
# Other PCs (http://<this-PC-IP>:PORT/) need a one-time URL reservation for
# http://+:PORT/ plus a firewall rule - run Enable-LAN.bat once (admin).
# Without it the server still starts, for this PC only (http://localhost:PORT/
# needs no admin rights).
#
# Same job as serve.py:
#   - serves index.html (the launcher), both app folders and /proxy from this folder
#   - forwards /proxy?url=<https://...hosxp.net/...> server-side and adds CORS
#     headers, because the HOSxP tunnel sends no CORS headers to localhost pages
#
# ASCII only on purpose: Windows PowerShell reads BOM-less .ps1 files in the
# ANSI code page, so Thai text in this file would be garbled.

param(
    [int]$Port = 8805,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
$AllowHosts = @('hosxp.net')              # only proxy to HOSxP hosts (not an open proxy)
$UserAgent = 'BMS-PatientJourney3D/1.0'        # hosxp.net answers 403 HTML when no User-Agent is sent
$Mime = @{
    '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'
    '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'; '.md' = 'text/plain; charset=utf-8'
    '.txt' = 'text/plain; charset=utf-8'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'
    '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.svg' = 'image/svg+xml'
    '.ico' = 'image/x-icon'; '.pdf' = 'application/pdf'
}

# Shared /api/sql cache: every screen sends the same SQL text, so when many PCs
# open http://<this-PC>:PORT/live.html the database sees roughly the load of ONE
# screen. A successful answer is reused for $CacheSec seconds. The key includes
# the Authorization header, so a different BMS session never gets another
# session's answer. Set the environment variable BMS_PJ3D_CACHE_SEC=0 to turn it off.
$CacheSec = 15
if ($env:BMS_PJ3D_CACHE_SEC -match '^\d+(\.\d+)?$') { $CacheSec = [double]$env:BMS_PJ3D_CACHE_SEC }
$CacheMaxBytes = 64MB
$Cache = @{}
$Stats = @{ hit = 0; miss = 0 }

# hosxp.net needs TLS 1.2 - older .NET defaults do not always turn it on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Send-Bytes($ctx, [int]$status, [byte[]]$body, [string]$ctype) {
    $res = $ctx.Response
    $res.StatusCode = $status
    $res.AddHeader('Access-Control-Allow-Origin', '*')
    $res.AddHeader('Access-Control-Allow-Headers', 'Authorization, Accept, Content-Type')
    $res.AddHeader('Access-Control-Allow-Methods', 'GET, OPTIONS')
    if ($ctype) { $res.ContentType = $ctype }
    if ($null -eq $body) { $body = [byte[]]@() }
    $res.ContentLength64 = $body.Length
    if ($body.Length -gt 0 -and $ctx.Request.HttpMethod -ne 'HEAD') {
        $res.OutputStream.Write($body, 0, $body.Length)
    }
    $res.Close()
}

function Send-Text($ctx, [int]$status, [string]$text) {
    Send-Bytes $ctx $status ([Text.Encoding]::UTF8.GetBytes($text)) 'text/plain; charset=utf-8'
}

function Test-AllowedHost([string]$name) {
    foreach ($h in $AllowHosts) {
        if ($name -eq $h -or $name.EndsWith('.' + $h)) { return $true }
    }
    return $false
}

function Invoke-Proxy($ctx) {
    # Read url= from the raw query and decode it once ourselves: the page encoded
    # an already-encoded tunnel URL, so its own %XX escapes must survive intact.
    $m = [regex]::Match($ctx.Request.RawUrl, '[?&]url=([^&]*)')
    if (-not $m.Success -or -not $m.Groups[1].Value) { Send-Text $ctx 400 'missing url'; return }
    $target = [Uri]::UnescapeDataString($m.Groups[1].Value)
    $uri = $null
    if (-not [Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not (Test-AllowedHost $uri.Host)) {
        Send-Text $ctx 403 'target host not allowed'; return
    }

    $auth = $ctx.Request.Headers['Authorization']
    if (-not $auth) { $auth = '' }

    # shared /api/sql cache (see the note at $CacheSec). This server handles one
    # request at a time, so screens asking the same query while it runs simply
    # get the cached answer next.
    $key = $null
    if ($CacheSec -gt 0 -and $uri.AbsolutePath.TrimEnd('/').EndsWith('/api/sql')) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($target + "`n" + $auth)))
        $sha.Dispose()
        $hit = $Cache[$key]
        if ($hit -and ([DateTime]::UtcNow - $hit.T).TotalSeconds -le $CacheSec) {
            $Stats.hit++
            $ctx.Response.AddHeader('X-Cache', 'HIT')
            Send-Bytes $ctx 200 $hit.Body $hit.Type; return
        }
        $Stats.miss++
    }

    $req = [Net.HttpWebRequest]::Create($uri)
    $req.Method = 'GET'
    $req.Accept = 'application/json'
    $req.UserAgent = $UserAgent
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 60000
    if ($auth) { $req.Headers['Authorization'] = $auth }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch {
        # 4xx/5xx still carry a body (the SQL error text) - pass it back to the page
        $e = $_.Exception
        while ($e -and -not ($e -is [Net.WebException])) { $e = $e.InnerException }
        if ($e -and $e.Response) { $resp = $e.Response }
        else { Send-Text $ctx 502 ('proxy error: ' + $_.Exception.Message); return }
    }
    try {
        $ms = New-Object IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $ctype = $resp.ContentType
        if (-not $ctype) { $ctype = 'application/json' }
        $code = [int]$resp.StatusCode
        $body = $ms.ToArray()
        if ($key) {
            # keep only successful answers (HTTP 200 + MessageCode 200), never errors or "busy"
            if ($code -eq 200 -and [Text.Encoding]::UTF8.GetString($body) -match '"MessageCode"\s*:\s*200\b') {
                Remove-OldCache
                $Cache[$key] = @{ T = [DateTime]::UtcNow; Body = $body; Type = $ctype }
            }
            $ctx.Response.AddHeader('X-Cache', 'MISS')
        }
        Send-Bytes $ctx $code $body $ctype
    } finally {
        $resp.Close()
    }
}

function Remove-OldCache {
    $now = [DateTime]::UtcNow
    foreach ($k in @($Cache.Keys)) {
        if (($now - $Cache[$k].T).TotalSeconds -gt $CacheSec) { $Cache.Remove($k) }
    }
    $total = 0
    foreach ($v in $Cache.Values) { $total += $v.Body.Length }
    if ($total -gt $CacheMaxBytes) {
        foreach ($k in @($Cache.Keys | Sort-Object { $Cache[$_].T })) {
            $total -= $Cache[$k].Body.Length
            $Cache.Remove($k)
            if ($total -le $CacheMaxBytes) { break }
        }
    }
}

function Send-Stats($ctx) {
    $json = '{"hit":' + $Stats.hit + ',"miss":' + $Stats.miss + ',"entries":' + $Cache.Count + ',"ttl_sec":' + $CacheSec + '}'
    Send-Bytes $ctx 200 ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json'
}

function Send-File($ctx) {
    $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
    if ($path -eq '/') { $path = '/index.html' }
    $full = [IO.Path]::GetFullPath($Root + $path.TrimStart('/').Replace('/', '\'))
    # stay inside this folder
    if (-not $full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.File]::Exists($full)) {
        Send-Text $ctx 404 'File not found'; return
    }
    $ctype = $Mime[[IO.Path]::GetExtension($full).ToLowerInvariant()]
    if (-not $ctype) { $ctype = 'application/octet-stream' }
    Send-Bytes $ctx 200 ([IO.File]::ReadAllBytes($full)) $ctype
}

function Start-Listener([string]$prefix) {
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add($prefix)
    try { $l.Start() } catch { $l.Close(); throw }
    return $l
}
function Get-RootException($err) {
    $e = $err.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e
}
# IPv4 addresses other PCs can use to reach this one
function Get-LanAddresses {
    try {
        [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.ToString().StartsWith('169.254.') } |
            ForEach-Object { $_.Address.ToString() } | Sort-Object -Unique
    } catch { @() }
}

# 1) all addresses (other PCs can connect) - needs the URL reservation from Enable-LAN.bat
# 2) access denied -> no reservation yet -> this PC only
$listener = $null
$lan = $false
$failure = $null
try {
    $listener = Start-Listener "http://+:$Port/"
    $lan = $true
} catch {
    $failure = Get-RootException $_
    if ($failure -is [Net.HttpListenerException] -and $failure.ErrorCode -eq 5) {
        try { $listener = Start-Listener "http://localhost:$Port/"; $failure = $null }
        catch { $failure = Get-RootException $_ }
    }
}
if (-not $listener) {
    Write-Host ''
    Write-Host "Could not start the server on port $Port : $($failure.Message)" -ForegroundColor Red
    Write-Host 'Is this tool already running in another window? Close it, or change PORT in start.bat.'
    exit 1
}

$url = "http://localhost:$Port/index.html"
Write-Host '=============================================================='
Write-Host '  BMS 3D - launcher + both 3D apps on one port (PowerShell)'
Write-Host "  This PC:    $url"
if ($lan) {
    $ips = @(Get-LanAddresses)
    foreach ($ip in $ips) { Write-Host "  Other PCs:  http://${ip}:$Port/index.html" }
    Write-Host '  (other PCs cannot connect? run Enable-LAN.bat once to open the firewall)'
} else {
    Write-Host '  Other PCs cannot connect yet: run Enable-LAN.bat once' -ForegroundColor Yellow
    Write-Host '  (it asks for administrator rights), then start this tool again.' -ForegroundColor Yellow
}
if ($CacheSec -gt 0) { Write-Host "  SQL cache: screens share each answer for $CacheSec s  (stats: /cache-stats)" }
else { Write-Host '  SQL cache: off (BMS_PJ3D_CACHE_SEC=0)' }
Write-Host '  Press Ctrl+C or close this window to stop.'
Write-Host '=============================================================='
if ($Open) { Start-Process $url }

try {
    while ($listener.IsListening) {
        # wait in short slices so Ctrl+C can stop the loop
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(500)) { }
        $ctx = $listener.EndGetContext($ar)
        try {
            $method = $ctx.Request.HttpMethod
            $path = $ctx.Request.Url.AbsolutePath
            if ($method -eq 'OPTIONS') { Send-Bytes $ctx 204 $null $null }
            elseif ($method -ne 'GET' -and $method -ne 'HEAD') { Send-Text $ctx 405 'method not allowed' }
            elseif ($path -eq '/proxy' -or $path.StartsWith('/proxy/')) { Invoke-Proxy $ctx }
            elseif ($path -eq '/cache-stats') { Send-Stats $ctx }
            else { Send-File $ctx }
        } catch {
            # one broken request (e.g. the browser closed the tab) must not stop the server
            try { Send-Text $ctx 500 ('server error: ' + $_.Exception.Message) } catch { }
        }
    }
} finally {
    $listener.Close()
    Write-Host 'Server stopped.'
}
