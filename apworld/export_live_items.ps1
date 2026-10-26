# Usage : powershell -ExecutionPolicy Bypass -File export_live_items.ps1 [-Out file.json]  (defaut : re9_live_<chapter>.json)
param(
    [string]$Api     = "http://localhost:8899/api/items",
    [string]$DataDir = "D:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem\reframework\data",
    [string]$Out
)

$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# Le plugin ne declare pas de charset : decodage UTF-8 a la main (noms de dossiers en japonais)
function Get-Json($url) {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
    $bytes = New-Object byte[] $resp.RawContentStream.Length
    [void]$resp.RawContentStream.Read($bytes, 0, $bytes.Length)
    $Utf8.GetString($bytes) | ConvertFrom-Json
}

$live = Get-Json $Api
if ($live.error) { throw "API error: $($live.error)" }

$chapter = (Get-Json ($Api -replace '/api/items$', '/api/gameinfo')).chapter -replace '_Main$', ''
if (-not $Out) { $Out = Join-Path $PSScriptRoot "re9_live_$(if ($chapter) { $chapter } else { 'unknown' }).json" }

$coreByContext = @{}
foreach ($c in (Get-Json ($Api -replace '/api/items$', '/api/itemcores')).items) {
    if ($c.contextId -and -not $coreByContext.ContainsKey($c.contextId)) { $coreByContext[$c.contextId] = $c }
}

$names = @{}
foreach ($it in (Get-Content -LiteralPath (Join-Path $DataDir "item_list.json") -Raw -Encoding UTF8 | ConvertFrom-Json).items) {
    $names[$it.id] = $it
}

$scan = Get-Content -LiteralPath (Join-Path $DataDir "re9_item_scan.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$scanEntries = foreach ($p in $scan.PSObject.Properties) { $p.Value | Add-Member -NotePropertyName key -NotePropertyValue $p.Name -PassThru -Force }

function Get-ItemId($it) { if ($it.contents.Count) { $it.contents[0].itemId } else { $it.viewItemId } }
function Test-HasPos($it) { $null -ne $it.position.x -and -not ($it.position.x -eq 0 -and $it.position.z -eq 0) }

# Appariement 1-1, paires les plus proches d'abord : les doublons empiles (pieces d'un coffre) ont chacun leur entree
$scanKeyByIndex = @{}
$usedScan = @{}
$pairs = for ($i = 0; $i -lt $live.items.Count; $i++) {
    $it = $live.items[$i]
    if (-not (Test-HasPos $it)) { continue }
    $itemId = Get-ItemId $it
    foreach ($s in $scanEntries) {
        if ($s.item_id -ne $itemId) { continue }
        $d = [math]::Sqrt([math]::Pow($s.x - $it.position.x, 2) + [math]::Pow($s.y - $it.position.y, 2) + [math]::Pow($s.z - $it.position.z, 2))
        if ($d -lt 0.5) { [pscustomobject]@{ I = $i; Key = $s.key; D = $d } }
    }
}
foreach ($p in ($pairs | Sort-Object D)) {
    if ($scanKeyByIndex.ContainsKey($p.I) -or $usedScan.ContainsKey($p.Key)) { continue }
    $scanKeyByIndex[$p.I] = $p.Key; $usedScan[$p.Key] = $true
}

$fpCounts = $live.items | Where-Object { $_.folderPath -and $_.gameObject } | Group-Object { "fp::$($_.folderPath)/$($_.gameObject)" } -AsHashTable -AsString
for ($i = 0; $i -lt $live.items.Count; $i++) {
    if ($scanKeyByIndex.ContainsKey($i)) { continue }
    $it = $live.items[$i]
    if (-not ($it.folderPath -and $it.gameObject)) { continue }
    $fp = "fp::$($it.folderPath)/$($it.gameObject)"
    if ($fpCounts[$fp].Count -eq 1 -and -not $usedScan.ContainsKey($fp) -and $scan.PSObject.Properties.Name -contains $fp) {
        $scanKeyByIndex[$i] = $fp; $usedScan[$fp] = $true
    }
}

$result = [ordered]@{}
for ($i = 0; $i -lt $live.items.Count; $i++) {
    $it = $live.items[$i]
    $itemId = Get-ItemId $it
    $stock  = ($it.contents | Measure-Object -Property stock -Sum).Sum
    $info   = $names[$itemId]
    $key    = if ($it.contextId -and $it.contextId -ne "00000000-0000-0000-0000-000000000000") { $it.contextId }
              else { "fp::$($it.folderPath)/$($it.gameObject)" }
    if ($result.Contains($key)) { $key = "$key#$($result.Count)" }
    $core = $coreByContext[$it.contextId]
    $staticId = if ($core -and $core.staticId -ne "00000000-0000-0000-0000-000000000000") { $core.staticId } else { $null }
    $result[$key] = [ordered]@{
        static_id   = $staticId
        difficulty  = if ($core) { $core.difficulty } else { $null }
        item_id     = $itemId
        item_name   = if ($info) { $info.name } else { $null }
        category    = if ($info) { $info.category } else { $null }
        amount      = [int]$stock
        empty       = ($it.contents.Count -eq 0)
        spawned     = $it.isSpawn
        dynamic     = $it.isDynamic
        x           = [math]::Round([double]$it.position.x, 2)
        y           = [math]::Round([double]$it.position.y, 2)
        z           = [math]::Round([double]$it.position.z, 2)
        game_object = $it.gameObject
        folder_path = $it.folderPath
        scan_key    = $scanKeyByIndex[$i]
    }
}

# Les placements des autres difficultes ont un ItemCore mais rien dans le registre
$registered = @{}; foreach ($it in $live.items) { if ($it.contextId) { $registered[$it.contextId] = $true } }
foreach ($c in (Get-Json ($Api -replace '/api/items$', '/api/itemcores')).items) {
    if ($c.isDynamic -or ($c.contextId -and $registered.ContainsKey($c.contextId))) { continue }
    $info = $names[$c.itemId]
    $key = if ($c.staticId -and $c.staticId -ne "00000000-0000-0000-0000-000000000000") { $c.staticId } else { "fp::$($c.folderPath)/$($c.gameObject)" }
    if ($result.Contains($key)) { $key = "$key#$($result.Count)" }
    $result[$key] = [ordered]@{
        static_id   = if ($key -notlike 'fp::*') { $key } else { $null }
        difficulty  = $c.difficulty
        item_id     = $c.itemId
        item_name   = if ($info) { $info.name } else { $null }
        category    = if ($info) { $info.category } else { $null }
        amount      = [int]$c.amount
        empty       = $false
        spawned     = $false
        dynamic     = $false
        x           = [math]::Round([double]$c.position.x, 2)
        y           = [math]::Round([double]$c.position.y, 2)
        z           = [math]::Round([double]$c.position.z, 2)
        game_object = $c.gameObject
        folder_path = $c.folderPath
        scan_key    = $null
        other_difficulty = $true
    }
}

$doc = [ordered]@{ chapter = $chapter; stage = $live.stage; count = $result.Count; items = $result }
[IO.File]::WriteAllText($Out, ($doc | ConvertTo-Json -Depth 5), $Utf8)

$rows = $result.Values
"Chapter: $chapter   stage: $($live.stage)   placements: $($result.Count)"
"  with static id: $(@($rows | Where-Object static_id).Count)   other difficulties only: $(@($rows | Where-Object other_difficulty).Count)"
"  with contents: $(@($rows | Where-Object { -not $_.empty }).Count)   empty (picked or not yet filled): $(@($rows | Where-Object empty).Count)"
"  runtime drops: $(@($rows | Where-Object dynamic).Count)   unknown item ids: $(@($rows | Where-Object { -not $_.item_name }).Count)"
"  matched to scan: $(@($rows | Where-Object scan_key).Count)   not in scan: $(@($rows | Where-Object { -not $_.scan_key -and -not $_.dynamic }).Count)"
"  scan entries never seen live: $(@($scanEntries | Where-Object { -not $usedScan.ContainsKey($_.key) }).Count) / $($scanEntries.Count)"
"Written: $Out"
