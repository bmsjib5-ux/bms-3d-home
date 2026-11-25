# BMS 3D Home - local web server for the 3D app launcher (PowerShell fallback)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 -Port 8805 [-Open]
#
# Serves the files in this folder only (index.html + assets). No proxy, no database.
# ASCII only on purpose - this file is read as ANSI by Windows PowerShell 5.1.
param(
  [int]$Port = 8805,
  [switch]$Open
)

$ErrorActionPreference = 'Stop'
$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Root.EndsWith('\')) { $Root = $Root + '\' }

$Mime = @{
  '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'
  '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8'
  '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
  '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'
  '.svg' = 'image/svg+xml'; '.webp' = 'image/webp'; '.ico' = 'image/x-icon'
  '.woff' = 'font/woff'; '.woff2' = 'font/woff2'; '.txt' = 'text/plain; charset=utf-8'
  '.md' = 'text/markdown; charset=utf-8'
}

function Send-Text($ctx, [int]$code, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text)
  $ctx.Response.StatusCode = $code
  $ctx.Response.ContentType = 'text/plain; charset=utf-8'
  $ctx.Response.ContentLength64 = $b.Length
  $ctx.Response.OutputStream.Write($b, 0, $b.Length)
}

function Send-File($ctx) {
  $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
  if ($path -eq '/') { $path = '/index.html' }
  $full = [IO.Path]::GetFullPath($Root + $path.TrimStart('/').Replace('/', '\'))
  if (-not $full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
    Send-Text $ctx 404 'not found'
    return
  }
  $ext = [IO.Path]::GetExtension($full).ToLower()
  $type = $Mime[$ext]
  if (-not $type) { $type = 'application/octet-stream' }
  $bytes = [IO.File]::ReadAllBytes($full)
  $ctx.Response.StatusCode = 200
  $ctx.Response.ContentType = $type
  if ($ext -eq '.html') { $ctx.Response.Headers.Add('Cache-Control', 'no-store') }
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Start-Server([string[]]$prefixes) {
  $l = New-Object Net.HttpListener
  foreach ($p in $prefixes) { $l.Prefixes.Add($p) }
  $l.Start()
  return $l
}

$listener = $null
try { $listener = Start-Server @("http://+:$Port/") }
catch {
  # No URL reservation for all interfaces (needs Enable-LAN.bat once) - fall back to this PC only.
  # Both spellings are needed: a prefix for "localhost" alone answers 400 to http://127.0.0.1:PORT/
  try { $listener = Start-Server @("http://localhost:$Port/", "http://127.0.0.1:$Port/") }
  catch {
    Write-Host ("[ERROR] Could not listen on port {0}: {1}" -f $Port, $_.Exception.Message)
    Write-Host '        Another program may be using it - change "set PORT=" in start.bat'
    exit 1
  }
}

$ips = @()
try {
  $ips = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('169.254.') } |
    ForEach-Object { $_.ToString() }
} catch {}

Write-Host ('=' * 62)
Write-Host '  BMS 3D Home - 3D app launcher (Windows PowerShell server)'
Write-Host ('=' * 62)
Write-Host ("  This PC   : http://localhost:{0}/index.html" -f $Port)
foreach ($ip in $ips) { Write-Host ("  Other PCs : http://{0}:{1}/index.html" -f $ip, $Port) }
Write-Host '  Close this window (or Ctrl+C) to stop the server.'
Write-Host ('=' * 62)

if ($Open) { Start-Process ("http://localhost:$Port/index.html") }

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      if ($ctx.Request.HttpMethod -eq 'GET') { Send-File $ctx } else { Send-Text $ctx 405 'method not allowed' }
    } catch {
      try { Send-Text $ctx 500 ('server error: ' + $_.Exception.Message) } catch {}
    } finally {
      try { $ctx.Response.OutputStream.Close() } catch {}
    }
  }
} finally {
  try { $listener.Stop() } catch {}
}
