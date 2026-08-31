# ══════════════════════════════════════════════════════════════
#  祈願觀測站 · 一鍵抓取原神祈願紀錄 (輸出 UIGF v4 JSON)
#  原理:讀取本機遊戲網頁快取中的祈願歷史連結 (authkey),
#        向米哈遊官方 API 抓取完整紀錄。authkey 只會傳給官方伺服器。
#  使用前:先在遊戲裡打開 祈願 → 查看歷史紀錄 (24 小時內有效)
# ══════════════════════════════════════════════════════════════
param([switch]$Silent)   # -Silent:排程背景模式,不暫停等待、結果寫入 fetch.log
$ErrorActionPreference = 'Stop'
function Read-SharedText($path){
  # 遊戲執行中會鎖住檔案,用共享模式讀取
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  $bytes = New-Object byte[] ([int]$fs.Length)
  [void]$fs.Read($bytes, 0, $bytes.Length)
  $fs.Close()
  return [Text.Encoding]::UTF8.GetString($bytes)
}
function Fail($msg){
  if($Silent){
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm') FAIL $msg" | Add-Content -Path (Join-Path $PSScriptRoot 'fetch.log')
    exit 1
  }
  Write-Host ''
  Write-Host "[X] $msg" -ForegroundColor Red
  Read-Host '按 Enter 關閉'
  exit 1
}

Write-Host '=== 祈願觀測站:抓取祈願紀錄 ===' -ForegroundColor Yellow

# ── 1. 找遊戲 log,定位安裝路徑 ─────────────────────────────
$logs = @(
  "$env:USERPROFILE\AppData\LocalLow\miHoYo\Genshin Impact\output_log.txt",
  "$env:USERPROFILE\AppData\LocalLow\miHoYo\原神\output_log.txt"
) | Where-Object { Test-Path $_ }
if(-not $logs){ Fail '找不到原神的 log 檔。請先在這台電腦開啟原神,打開 祈願 → 查看歷史紀錄,再執行本工具。' }

$gameData = $null
foreach($lg in $logs){
  $txt = Read-SharedText $lg
  $m = [regex]::Match($txt, '[A-Za-z]:[/\\][^\r\n:*?"<>|]+?(GenshinImpact_Data|YuanShen_Data)')
  if($m.Success){ $gameData = $m.Value -replace '/','\'; break }
}
if(-not $gameData -or -not (Test-Path $gameData)){ Fail '在 log 裡找不到遊戲安裝路徑。請進遊戲開一次 祈願 → 查看歷史紀錄 後再試。' }

# ── 2. 找 webCaches 裡最新的快取檔 data_2 ──────────────────
$web = Join-Path $gameData 'webCaches'
if(-not (Test-Path $web)){ Fail "找不到 webCaches 資料夾:$web" }
$verDirs = @(Get-ChildItem $web -Directory | Where-Object { $_.Name -match '^\d+\.' } | Sort-Object { [version]$_.Name })
$cacheDir = if($verDirs.Count){ $verDirs[-1].FullName } else { $web }
$data2 = Join-Path $cacheDir 'Cache\Cache_Data\data_2'
if(-not (Test-Path $data2)){ Fail "找不到快取檔。請先在遊戲裡打開 祈願 → 查看歷史紀錄。`n($data2)" }

# ── 3. 從快取撈出最新的祈願歷史連結 ────────────────────────
$fs = [IO.File]::Open($data2, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
$bytes = New-Object byte[] ([int]$fs.Length)
[void]$fs.Read($bytes, 0, $bytes.Length)
$fs.Close()
$blob = [Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
$urls = @([regex]::Matches($blob, 'https?://[^\x00-\x20"]+') |
          ForEach-Object { $_.Value } |
          Where-Object { $_ -match 'authkey=' -and $_ -match 'game_biz=hk4e' -and $_ -match 'gacha' })
if(-not $urls.Count){ Fail '快取裡沒有祈願紀錄連結。請進遊戲打開 祈願 → 查看歷史紀錄 (翻一頁),再執行本工具。' }
$qs = ($urls[-1] -replace '#.*$','') -replace '^[^?]*\?',''
# 只保留授權必要的參數 (白名單),其餘全丟掉 —
# 頁面網址自帶的 gacha_id/init_type/size 等參數會干擾查詢範圍與分頁
$keep = 'authkey','authkey_ver','sign_type','auth_appid','game_biz','lang','region'
$qs = (($qs -split '&') | Where-Object { $keep -contains ($_ -split '=',2)[0] }) -join '&'

# ── 4. 選 API 端點並驗證 authkey ───────────────────────────
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Invoke-Api($u){
  # PS 5.1 的 Invoke-RestMethod 會把回應誤當 ISO-8859-1,中文會壞掉;改手動用 UTF-8 解
  $resp = Invoke-WebRequest -Uri $u -TimeoutSec 20 -UseBasicParsing
  return ([Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json)
}
$isCN = $qs -match 'game_biz=hk4e_cn'
$endpoints = if($isCN){
  @('https://public-operation-hk4e.mihoyo.com/gacha_info/api/getGachaLog',
    'https://hk4e-api.mihoyo.com/event/gacha_info/api/getGachaLog')
}else{
  @('https://public-operation-hk4e-sg.hoyoverse.com/gacha_info/api/getGachaLog',
    'https://hk4e-api-os.hoyoverse.com/event/gacha_info/api/getGachaLog')
}
$api = $null
foreach($ep in $endpoints){
  try{
    $r = Invoke-Api ($ep + '?' + $qs + '&gacha_type=301&page=1&size=5&end_id=0')
    if($r.retcode -eq -101){ Fail '授權已過期 (有效 24 小時)。請進遊戲重新打開 祈願 → 查看歷史紀錄,再執行一次。' }
    $api = $ep
    if($r.retcode -eq 0){ break }
  }catch{ continue }
}
if(-not $api){ Fail '連不上祈願查詢 API,請確認網路後再試。' }

function Get-Page($gt, $endId){
  $r = $null
  for($try=1; $try -le 4; $try++){
    $u = $api + '?' + $qs + "&gacha_type=$gt&page=1&size=20&end_id=$endId"
    try{ $r = Invoke-Api $u }
    catch{ Start-Sleep -Milliseconds 1500; continue }
    if($r.retcode -eq 0){
      if($null -eq $r.data.list){ return ,@() }
      return ,@($r.data.list)
    }
    if($r.retcode -eq -101){ Fail '授權已過期。請進遊戲重新打開 祈願 → 查看歷史紀錄,再執行一次。' }
    Start-Sleep -Milliseconds (1200 * $try)   # 觸發限速時退避重試
  }
  $code = if($r){ "$($r.retcode) $($r.message)" } else { '連線失敗' }
  Fail "API 持續回應錯誤 ($code),請稍後再試。"
}

# ── 5. 逐池抓取 (301 會一併回傳 400 的紀錄) ────────────────
$names = @{ '301'='角色活動祈願'; '302'='武器活動祈願'; '200'='常駐祈願'; '500'='集錄祈願'; '100'='新手祈願' }
$all = New-Object System.Collections.ArrayList
foreach($gt in '301','302','200','500','100'){
  Write-Host ('抓取 {0} ' -f $names[$gt]) -NoNewline
  $endId = '0'; $n = 0
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  while($true){
    $page = Get-Page $gt $endId
    if($page.Count -eq 0){ break }
    if(-not $seen.Add([string]$page[0].id)){ break }   # 保險:同一頁重複出現就停
    foreach($it in $page){ [void]$all.Add($it) }
    $n += $page.Count
    $endId = [string]$page[-1].id
    Write-Host '.' -NoNewline
    Start-Sleep -Milliseconds 400
    # 不能用「不滿 20 筆」判斷結束 — API 有時會提早斷頁,要抓到空頁為止
  }
  Write-Host (' {0} 筆' -f $n)
}
if($all.Count -eq 0){ Fail '一筆紀錄都沒抓到。官方只保留約半年內的紀錄。' }

# ── 6. 組成 UIGF v4 並輸出 ─────────────────────────────────
foreach($it in $all){
  $ug = if("$($it.gacha_type)" -eq '400'){ '301' } else { [string]$it.gacha_type }
  $it | Add-Member -NotePropertyName uigf_gacha_type -NotePropertyValue $ug -Force
}
$uid  = [string]$all[0].uid
$lang = if($qs -match 'lang=([^&]+)'){ $Matches[1] } else { 'zh-tw' }
$tz = 8
if($qs -match 'region=os_usa'){ $tz = -5 } elseif($qs -match 'region=os_euro'){ $tz = 1 }
$export = [ordered]@{
  info = [ordered]@{
    export_app = 'wish-observatory'
    export_app_version = '1.0'
    export_timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    version = 'v4.0'
  }
  hk4e = @([ordered]@{ uid = $uid; timezone = $tz; lang = $lang; list = $all.ToArray() })
}
$out = Join-Path $PSScriptRoot '祈願紀錄-UIGF.json'
$json = ConvertTo-Json -InputObject $export -Depth 8 -Compress
[IO.File]::WriteAllText($out, $json, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('[OK] 完成!共 {0} 筆,UID {1}' -f $all.Count, $uid) -ForegroundColor Green
Write-Host ('檔案已存到:{0}' -f $out)
if($Silent){
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm') OK $($all.Count) 筆" | Add-Content -Path (Join-Path $PSScriptRoot 'fetch.log')
}else{
  Write-Host '打開「祈願觀測站」的 資料 分頁,把這個檔案拖進去就匯入完成了。'
  Read-Host '按 Enter 關閉'
}
