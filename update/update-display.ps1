<#
  ============================================================
   อัพเดทเครื่องจอ "ระบบแสดงผล 3 มิติ" (BMS-3D-Home ทั้งชุด)
   ดึงไฟล์จากเครื่องพัฒนาที่เปิด start.bat อยู่ ผ่าน HTTP

   รันที่เครื่องจอ (กด Win+R พิมพ์ cmd แล้ววางคำสั่งนี้ — เปลี่ยน IP เป็นของเครื่องพัฒนา):

     powershell -ep bypass -c "iwr http://<IP เครื่องพัฒนา>:8805/update/update-display.ps1 -OutFile $env:TEMP\ud.ps1 -UseBasicParsing; & $env:TEMP\ud.ps1 -Src http://<IP เครื่องพัฒนา>:8805"

   - ดึงเฉพาะไฟล์ที่ใหม่หรือต่างจากเครื่องนี้ (เทียบ SHA-256 กับ update/manifest.json)
   - ตรวจทุกไฟล์ที่ดาวน์โหลดก่อน ถ้ามีไฟล์ไหนเสีย/ไม่ครบ จะหยุดโดยไม่แก้อะไรเลย
   - สำรองไฟล์เดิมที่จะถูกทับไว้ที่ backup-<วันเวลา>\ ในโฟลเดอร์เดียวกันก่อนทับทุกครั้ง
   - ไม่ลบไฟล์ที่มีอยู่แล้วในเครื่องนี้ · start.bat ใช้ PORT เดิมของเครื่องนี้ต่อ
   - ไม่ปิด/เปิดเซิร์ฟเวอร์ให้

   -Src  = ที่อยู่เครื่องพัฒนา เช่น http://<IP เครื่องพัฒนา>:8805 (ต้องใส่)
   -Dir  = บอกโฟลเดอร์ BMS-3D-Home ของเครื่องนี้เอง (ถ้าหาไม่เจอ หรือมีหลายชุด)
   -Yes  = ไม่ต้องถามยืนยัน
  ============================================================
#>
param(
  [string]$Src,
  [string]$Dir,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$line = '=' * 64
$script:Served = $false   # พิสูจน์แล้วว่าเป็นโฟลเดอร์ที่เซิร์ฟเวอร์ของจอเสิร์ฟอยู่
$script:Picked = $false   # ผู้ใช้เลือกจากรายการเอง

function Test-HomeFolder([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $false }
    foreach ($f in @('index.html', 'start.bat', 'serve.py')) {
      if (-not (Test-Path -LiteralPath (Join-Path $p $f) -PathType Leaf)) { return $false }
    }
    $t = Get-Content -LiteralPath (Join-Path $p 'index.html') -Raw -Encoding UTF8
    return ($t -like '*bms3d.host*')
  } catch { return $false }
}

function Find-HomeFolders {
  # หา "ทุก" โฟลเดอร์ BMS-3D-Home ในเครื่อง — บางเครื่องมีหลายชุด (เช่นสำเนาบน Desktop กับตัวที่เปิดจอจริง)
  $found = New-Object System.Collections.Generic.List[string]
  $add = { param($p) try { $r = (Resolve-Path -LiteralPath $p).Path.TrimEnd('\'); if (-not $found.Contains($r)) { $found.Add($r) } } catch {} }
  foreach ($p in @($PSScriptRoot, (Get-Location).Path)) { if (Test-HomeFolder $p) { & $add $p } }
  $bases = @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Downloads",
             'C:\', 'D:\', 'E:\', 'C:\BMS', 'D:\BMS')
  foreach ($b in $bases) {
    if (-not (Test-Path -LiteralPath $b -PathType Container)) { continue }
    if (Test-HomeFolder $b) { & $add $b }
    foreach ($d in (Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue)) {
      if (Test-HomeFolder $d.FullName) { & $add $d.FullName }
    }
  }
  Write-Host '  กำลังค้นหาโฟลเดอร์ BMS-3D-Home ทั้งหมดในเครื่องนี้ (อาจใช้เวลาสักครู่) ...'
  $skip = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin',
            'System Volume Information', 'OneDriveTemp', 'PerfLogs', 'Recovery')
  foreach ($root in @('C:\', 'D:\', 'E:\')) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    foreach ($top in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
      if ($skip -contains $top.Name) { continue }
      if (Test-HomeFolder $top.FullName) { & $add $top.FullName }
      foreach ($h in (Get-ChildItem -LiteralPath $top.FullName -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue)) {
        if ($h.Name -like 'backup-*') { continue }
        if (Test-HomeFolder $h.FullName) { & $add $h.FullName }
      }
    }
  }
  return ,$found.ToArray()
}

# โฟลเดอร์นี้คือตัวที่เซิร์ฟเวอร์ของจอกำลังเสิร์ฟอยู่จริงไหม: วางไฟล์ทดสอบชั่วคราว แล้วถามเซิร์ฟเวอร์ในเครื่องนี้ว่าเห็นไหม
function Test-Served([string]$p) {
  $port = '8805'
  try { $m = [regex]::Match((Get-Content -LiteralPath (Join-Path $p 'start.bat') -Raw), '(?im)^set PORT=(\d+)'); if ($m.Success) { $port = $m.Groups[1].Value } } catch {}
  $name = '__bms3d-probe-' + [guid]::NewGuid().ToString('N') + '.txt'
  $file = Join-Path $p $name
  $token = [guid]::NewGuid().ToString('N')
  try {
    [IO.File]::WriteAllText($file, $token)
    try {
      $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/' + $name) -UseBasicParsing -TimeoutSec 5
      return ($r.Content.Trim() -eq $token)
    } catch { return $false }
  } catch { return $false }
  finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Find-HomeFolder {
  if ($Dir) {
    if (Test-HomeFolder $Dir) { return (Resolve-Path -LiteralPath $Dir).Path }
    Write-Host ('  [คำเตือน] -Dir ที่ให้มาไม่ใช่โฟลเดอร์ BMS-3D-Home : ' + $Dir)
  }
  $all = Find-HomeFolders
  if (-not $all.Count) { return $null }
  Write-Host ('  พบโฟลเดอร์ BMS-3D-Home {0} ชุด:' -f $all.Count)
  $served = @()
  foreach ($p in $all) {
    $s = Test-Served $p
    if ($s) { $served += $p }
    Write-Host ('      {0} {1}' -f $(if ($s) { '[ตัวที่เปิดจออยู่]' } else { '[  -  ]          ' }), $p)
  }
  if ($served.Count -eq 1) { $script:Served = $true; return $served[0] }
  if ($served.Count -gt 1) { Write-Host '  [คำเตือน] มีหลายโฟลเดอร์ที่เซิร์ฟเวอร์เห็น — ต้องเลือกเอง' }
  else { Write-Host '  ไม่เจอโฟลเดอร์ที่เซิร์ฟเวอร์ของจอเสิร์ฟอยู่ (start.bat อาจปิดอยู่) — ต้องเลือกเอง' }
  if ($all.Count -eq 1) { return $all[0] }
  for ($i = 0; $i -lt $all.Count; $i++) { Write-Host ('      {0}) {1}' -f ($i + 1), $all[$i]) }
  $n = Read-Host '  เลือกหมายเลขโฟลเดอร์ที่จะอัพเดท (Enter = ยกเลิก)'
  if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $all.Count) { $script:Picked = $true; return $all[[int]$n - 1] }
  return $null
}

function Get-Sha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpper() }
function Get-UrlPath([string]$rel) { return (($rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/' }

Write-Host ''
Write-Host $line
Write-Host '  อัพเดทเครื่องจอ "ระบบแสดงผล 3 มิติ"'
Write-Host $line

if (-not $Src) { $Src = Read-Host '  ที่อยู่เครื่องพัฒนา (เช่น http://<IP เครื่องพัฒนา>:8805)' }
if (-not $Src) { Write-Host '  [หยุด] ไม่ได้ใส่ที่อยู่เครื่องพัฒนา ไม่ได้แก้ไฟล์ใด ๆ'; exit 1 }
if ($Src -notmatch '^https?://') { $Src = 'http://' + $Src }
$Src = $Src.TrimEnd('/')
Write-Host ('  ดึงไฟล์จาก : ' + $Src)

$target = Find-HomeFolder
if (-not $target) {
  Write-Host ''
  Write-Host '  ไม่พบโฟลเดอร์ BMS-3D-Home ในเครื่องนี้ (ต้องมี index.html, start.bat, serve.py)'
  $ans = Read-Host '  พิมพ์ที่อยู่โฟลเดอร์ แล้วกด Enter (กด Enter เลย = ยกเลิก)'
  if (Test-HomeFolder $ans) { $target = (Resolve-Path -LiteralPath $ans).Path }
}
if (-not $target) { Write-Host '  [หยุด] ไม่ได้แก้ไฟล์ใด ๆ'; exit 1 }
Write-Host ('  โฟลเดอร์   : ' + $target)
if ($script:Served) { Write-Host '               (ยืนยันแล้วว่าเป็นโฟลเดอร์ที่เซิร์ฟเวอร์ของจอเปิดอยู่)' }
if (-not $Yes -and -not $Dir -and -not $script:Served -and -not $script:Picked) {
  $c = Read-Host '  ใช่โฟลเดอร์นี้ไหม (Enter = ใช่, n = ไม่ใช่)'
  if ($c -and $c.Trim().ToLower().StartsWith('n')) {
    $ans = Read-Host '  พิมพ์ที่อยู่โฟลเดอร์ที่ถูกต้อง (Enter = ยกเลิก)'
    if (Test-HomeFolder $ans) { $target = (Resolve-Path -LiteralPath $ans).Path; Write-Host ('  โฟลเดอร์   : ' + $target) }
    else { Write-Host '  [หยุด] ไม่ได้แก้ไฟล์ใด ๆ'; exit 1 }
  }
}

# ---- [1/4] รายการไฟล์ -------------------------------------------------------
Write-Host ''
Write-Host '  [1/4] ดึงรายการไฟล์จากเครื่องพัฒนา'
try {
  $raw = Invoke-WebRequest -Uri ($Src + '/update/manifest.json') -UseBasicParsing -TimeoutSec 60
  $text = [Text.Encoding]::UTF8.GetString($raw.RawContentStream.ToArray())
  $man = $text | ConvertFrom-Json
} catch {
  Write-Host ('        [หยุด] ดึงรายการไฟล์ไม่ได้ : ' + $_.Exception.Message)
  Write-Host '        เช็คว่าเครื่องพัฒนาเปิด start.bat อยู่ และเปิดที่อยู่นี้ได้จากเครื่องนี้:'
  Write-Host ('            ' + $Src + '/index.html')
  Write-Host '        ยังไม่ได้แก้ไฟล์ใด ๆ'
  exit 1
}
if (-not $man.files -or $man.files.Count -lt 10) { Write-Host '        [หยุด] รายการไฟล์ไม่สมบูรณ์ ไม่ได้แก้ไฟล์ใด ๆ'; exit 1 }
Write-Host ('        {0} ไฟล์ (สร้างเมื่อ {1})' -f $man.files.Count, $man.generated)

# ---- [2/4] เทียบกับเครื่องนี้ --------------------------------------------------
Write-Host ''
Write-Host '  [2/4] เทียบกับไฟล์ในเครื่องนี้'
$todo = @()
foreach ($f in $man.files) {
  $dst = Join-Path $target ($f.p -replace '/', '\')
  if (Test-Path -LiteralPath $dst -PathType Leaf) {
    if ((Get-Item -LiteralPath $dst).Length -eq [int64]$f.n -and (Get-Sha256 $dst) -eq $f.h) { continue }
    $todo += [pscustomobject]@{ p = $f.p; n = [int64]$f.n; h = $f.h; dst = $dst; kind = 'แก้' }
  } else {
    $todo += [pscustomobject]@{ p = $f.p; n = [int64]$f.n; h = $f.h; dst = $dst; kind = 'ใหม่' }
  }
}
if (-not $todo.Count) {
  Write-Host ''
  Write-Host '  เครื่องนี้เป็นรุ่นเดียวกับเครื่องพัฒนาอยู่แล้ว ไม่ต้องอัพเดท'
  exit 0
}
$mb = ($todo | Measure-Object -Property n -Sum).Sum / 1MB
Write-Host ('        ต้องอัพเดท {0} ไฟล์ ({1:N1} MB) : ใหม่ {2} · แก้ {3}' -f $todo.Count, $mb,
  @($todo | Where-Object kind -eq 'ใหม่').Count, @($todo | Where-Object kind -eq 'แก้').Count)
foreach ($t in ($todo | Where-Object kind -eq 'แก้')) { Write-Host ('          แก้   ' + $t.p) }
$newDirs = $todo | Where-Object kind -eq 'ใหม่' | ForEach-Object { ($_.p -split '/')[0] } | Sort-Object -Unique
foreach ($d in $newDirs) {
  $n = @($todo | Where-Object { $_.kind -eq 'ใหม่' -and ($_.p -split '/')[0] -eq $d -and $_.p -ne $d }).Count
  if ($n) { Write-Host ('          ใหม่  ' + $d + '\ (' + $n + ' ไฟล์)') } else { Write-Host ('          ใหม่  ' + $d) }
}

# ---- [3/4] ดาวน์โหลดและตรวจ -------------------------------------------------
Write-Host ''
Write-Host '  [3/4] ดาวน์โหลดและตรวจทุกไฟล์'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp = Join-Path $env:TEMP ('bms3d-update-' + $ts)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$i = 0
foreach ($t in $todo) {
  $i++
  $t | Add-Member -NotePropertyName tmp -NotePropertyValue (Join-Path $tmp ('f' + $i))
  try {
    Invoke-WebRequest -Uri ($Src + '/' + (Get-UrlPath $t.p)) -OutFile $t.tmp -UseBasicParsing -TimeoutSec 120
  } catch {
    Write-Host ('        [หยุด] ดึง ' + $t.p + ' ไม่ได้ : ' + $_.Exception.Message)
    Write-Host '        ยังไม่ได้แก้ไฟล์ใด ๆ'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
  }
  if ((Get-Item -LiteralPath $t.tmp).Length -ne $t.n -or (Get-Sha256 $t.tmp) -ne $t.h) {
    Write-Host ('        [หยุด] ' + $t.p + ' ที่ได้มาไม่ตรงกับรายการ (ไฟล์เสียระหว่างทาง หรือเครื่องพัฒนาแก้ไฟล์ค้างอยู่)')
    Write-Host '        ยังไม่ได้แก้ไฟล์ใด ๆ — ลองรันใหม่อีกครั้ง'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
  }
}
Write-Host ('        ครบ {0} ไฟล์ ตรงกับรายการทุกไฟล์' -f $todo.Count)

# start.bat: ใช้ PORT เดิมของเครื่องนี้ต่อ (ถ้าเคยเปลี่ยนไว้)
$sb = $todo | Where-Object { $_.p -eq 'start.bat' -and $_.kind -eq 'แก้' }
if ($sb) {
  $old = Get-Content -LiteralPath $sb.dst -Raw
  $m = [regex]::Match($old, '(?im)^set PORT=(\d+)')
  if ($m.Success) {
    $new = Get-Content -LiteralPath $sb.tmp -Raw
    $mm = [regex]::Match($new, '(?im)^set PORT=(\d+)')
    if ($mm.Success -and $mm.Groups[1].Value -ne $m.Groups[1].Value) {
      $new = $new.Substring(0, $mm.Index) + ('set PORT=' + $m.Groups[1].Value) + $new.Substring($mm.Index + $mm.Length)
      [IO.File]::WriteAllText($sb.tmp, $new, (New-Object Text.UTF8Encoding($false)))
      Write-Host ('        start.bat : คง PORT=' + $m.Groups[1].Value + ' ของเครื่องนี้ไว้')
    }
  }
}

# ---- [4/4] สำรองแล้วทับ ------------------------------------------------------
Write-Host ''
$bk = Join-Path $target ('backup-' + $ts)
$changed = @($todo | Where-Object kind -eq 'แก้')
if ($changed.Count) {
  Write-Host ('  [4/4] สำรองไฟล์เดิม {0} ไฟล์ -> backup-{1} แล้วทับ' -f $changed.Count, $ts)
  try {
    foreach ($t in $changed) {
      $b = Join-Path $bk ($t.p -replace '/', '\')
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null
      Copy-Item -LiteralPath $t.dst -Destination $b -Force
    }
  } catch {
    Write-Host ('        [หยุด] สำรองไม่ได้ : ' + $_.Exception.Message)
    Write-Host '        ไม่ได้แก้ไฟล์ใด ๆ (ลองเปิด PowerShell แบบ Run as administrator)'
    exit 1
  }
} else {
  Write-Host '  [4/4] วางไฟล์ใหม่ (ไม่มีไฟล์เดิมต้องสำรอง)'
}
foreach ($t in $todo) {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $t.dst) | Out-Null
    Copy-Item -LiteralPath $t.tmp -Destination $t.dst -Force
  } catch {
    Write-Host ('        [ผิดพลาด] วาง ' + $t.p + ' ไม่ได้ : ' + $_.Exception.Message)
    if ($changed.Count) { Write-Host ('        ของเดิมอยู่ที่ ' + $bk + ' คัดลอกทับกลับได้') }
    exit 1
  }
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ('        เรียบร้อย {0} ไฟล์' -f $todo.Count)

$restart = @($todo | Where-Object { $_.p -in @('serve.py', 'serve.ps1', 'start.bat') }).Count -gt 0
Write-Host ''
Write-Host $line
Write-Host '  เสร็จแล้ว'
Write-Host ''
if ($restart) {
  Write-Host '  ** serve.py / start.bat เปลี่ยน: ปิดหน้าต่างดำของเซิร์ฟเวอร์ แล้วดับเบิลคลิก start.bat ใหม่ **'
  Write-Host '     (แอปใหม่ทุกตัวเปิดจากพอร์ตเดียวกับหน้ารวม ต้องใช้เซิร์ฟเวอร์ตัวใหม่)'
} else {
  Write-Host '  กด F5 ที่เบราว์เซอร์ก็เห็นของใหม่ ไม่ต้องปิดเซิร์ฟเวอร์'
}
if ($changed.Count) {
  Write-Host ''
  Write-Host ('  ของเดิมเก็บไว้ที่ : ' + $bk)
  Write-Host '  ถ้าของใหม่มีปัญหา : คัดลอกไฟล์จากโฟลเดอร์นั้นทับกลับ'
}
Write-Host $line
Write-Host ''
exit 0
