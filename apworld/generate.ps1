# Sources : ch<NN>_<Chapter>.json (base), puis en option <DataDir>\re9_item_scan.json et re9_live_*.json
# Usage : powershell -ExecutionPolicy Bypass -File generate.ps1 [-DataDir <reframework\data>]
param(
    [string]$DataDir = "D:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem\reframework\data"
)

$ErrorActionPreference = "Stop"
$OutDir   = Join-Path $PSScriptRoot "resident_evil_requiem"
$ItemBase = 7090000
$LocBase  = 7091000
$MergeDistance = 1.0
$FallbackDistance = 3.0
$Utf8     = New-Object System.Text.UTF8Encoding($false)
$Inv      = [cultureinfo]::InvariantCulture

# Script en ASCII pur : PowerShell 5.1 lit en ANSI sans BOM, d'ou le japonais echappe
function U([string]$s) { [regex]::Unescape($s) }

$ZoneTokens = [ordered]@{
    (U '\u30DB\u30FC\u30EB\uFF0B\u897F1st')                                         = 'Hall+West 1st'
    (U '2nd\u4EE5\u964D')                                                            = ''
    (U '\u6771')                                                                     = 'East '
    (U '\u897F')                                                                     = 'West '
    (U '\u91D1\u5EAB')                                                               = 'Safe'
    (U '\u30C8\u30DE\u30DB\u30FC\u30AF\u68DA')                                       = 'Tomahawk Shelf'
    (U '\u30AD\u30FC\u30A2\u30A4\u30C6\u30E0\u7CFB')                                 = 'Key Items'
    (U '\u30AD\u30FC\u30A2\u30A4\u30C6\u30E0')                                       = 'Key Items'
    (U '\u53CE\u96C6\u7CFB')                                                         = 'Collectibles'
    (U '\u76F4\u7F6E\u304D\u7CFB')                                                   = 'Floor'
    (U '\u76F4\u7F6E\u304D')                                                         = 'Floor'
    (U '\u5F15\u304D\u51FA\u3057\u7CFB')                                             = 'Drawer'
    (U '\u30AF\u30E9\u30D5\u30C8\u7CFB')                                             = 'Craft'
    (U '\u6575\u304C\u6301\u3063\u3066\u3044\u308B')                                 = 'Enemy Drop'
    (U '\u8840\u6DB2')                                                               = 'Blood'
    (U '\u30DB\u30C6\u30EB')                                                         = 'Hotel'
    (U '\u5730\u4E0B\u9244')                                                         = 'Subway'
    (U '\u30EA\u30BD\u30FC\u30B9')                                                   = 'Resource'
    (U '\u80CC\u666F\u30BB\u30C3\u30C8')                                             = 'Scenery'
    (U '\u5C4B\u4E0A')                                                               = 'Rooftop'
    (U '\u843D\u3068\u305B\u308B\u5099\u54C1\u30DC\u30C3\u30AF\u30B9')               = 'Supply Box'
    (U '\u30E9\u30B9\u30C8\u306E\u6575')                                             = 'Last Enemy'
    'FlowTryPickup'                                                                  = 'Story Pickup'
    'sapwner'                                                                        = 'Spawner'
}
$IgnoredSegments = '^(MainGame|Chap\d+_\d+|FF_\d+|ChapX_JCT\d+_Item|(Chap\d+_\d+|FF_\d+)_(Item|Gimmick)(_\d+|_Common|_Unique)?|Item_\d+|newFolder|SubFolder)$'
$DifficultyTags  = @{
    'CLASSIC_INSANITY_ONLY' = @('Classic', 'Insanity')
    'CASUAL_MODERN_ONLY'    = @('Casual', 'Modern')
    'INSANITYONLY'          = @('Insanity')
}
# IDs de ItemCore._AssignDifficulty
$DifficultyById = @{ 'ID0010' = 'Casual'; 'ID0020' = 'Modern'; 'ID0030' = 'Classic'; 'ID0040' = 'Insanity' }

$ProgressionCategories = 'KeyItem', 'Flag'
$UsefulCategories      = 'Weapon', 'SubWeapon', 'Attachment', 'Storage', 'Armor', 'Charm'
$ProgressionOverrides  = 'it99_50_005', 'it99_50_006'   # Antique Coin (coin locker), Lockpick

# Ids absents de item_list.json : mettre le nom en jeu ici quand on le connait
$ExtraItemNames = @{
}

function Get-ExtraCategory([string]$id) {
    switch -Regex ($id) {
        '^it00'      { 'Heal' ; break }
        '^it10'      { 'Weapon' ; break }
        '^it20'      { 'SubWeapon' ; break }
        '^it30_00_7' { 'Charm' ; break }
        '^it30'      { 'Attachment' ; break }
        '^it40'      { 'Ammo' ; break }
        '^it50'      { 'Material' ; break }
        '^it60'      { 'KeyItem' ; break }
        '^it70'      { 'Procedure' ; break }
        '^it99_05'   { 'Flag' ; break }
        default      { 'Other' }
    }
}

function Get-Zone([string]$folder) {
    $tags  = @()
    $parts = @()
    foreach ($seg in $folder -split '/') {
        if (-not $seg -or $seg -match $IgnoredSegments) { continue }
        if ($DifficultyTags.ContainsKey($seg)) { $tags += $DifficultyTags[$seg]; continue }
        if ($seg -match '^(st\d+_\d+)_Gimmick(_Common|_Unique)?$') { $parts += $Matches[1]; continue }
        $t = $seg -replace '_(Item|Gimmick)(_Common|_Unique)?$', '' -replace '^Item_', ''
        foreach ($k in $ZoneTokens.Keys) { $t = $t.Replace($k, $ZoneTokens[$k]) }
        $t = (($t -replace '([A-Za-z])(\d+)$', '$1 $2') -replace '\s+', ' ').Trim()
        if ($t -match '[^\x20-\x7E]') { $t = "Misc" }
        if ($t) { $parts += $t }
    }
    if (-not $parts) { $parts = @('Area') }
    [pscustomobject]@{ Zone = ($parts -join ' '); Difficulties = $tags }
}

function Get-ChapterOf([string]$folder) {
    if ($folder -match '^MainGame/(Chap\d+_\d+|FF_\d+)(/|$)') { return $Matches[1] }
    return $null
}

# Les ids de location suivent l'ordre des fichiers ch<NN>, renumeroter ici ne change aucun id
$StoryChapter = [ordered]@{
    'Chap1_00' = 1; 'Chap1_01' = 1; 'Chap1_10' = 2
    'Chap3_01' = 3; 'Chap3_10' = 4; 'Chap3_02' = 5; 'Chap3_20' = 6; 'Chap3_0304' = 7; 'Chap3_03' = 7
    'Chap3_04' = 8; 'Chap3_324' = 9; 'Chap3_40' = 10; 'Chap3_05' = 11; 'Chap3_06' = 12
    'Chap4_00' = 13; 'Chap4_1020' = 13; 'Chap4_10' = 13; 'Chap4_20' = 13; 'Chap4_30' = 14
    'Chap4_4050' = 15; 'Chap4_40' = 15; 'FF_02' = 16; 'Chap4_50' = 17
    'Chap5_10' = 18; 'Chap5_02' = 19; 'Chap5_03' = 20
}
$StoryChapterCount = 20

function Get-ChapterLabel([string]$chapter) {
    if ($chapter -and $StoryChapter.Contains($chapter)) { return "Ch$($StoryChapter[$chapter])" }
    if ($chapter -match '^Chap(\d+)_(\d+)$') { return "Ch$($Matches[1]).$($Matches[2])" }
    if ($chapter -match '^FF_(\d+)$')        { return "FF.$($Matches[1])" }
    return $chapter
}

function Get-NormDiffs($list) {
    $l = @($list | Where-Object { $_ } | Sort-Object -Unique)
    if ($l.Count -ge $DifficultyById.Count) { return ,@() }
    return ,$l
}

function PyStr([string]$s) { '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
function PyTuple($xs) { $a = @($xs); if (-not $a.Count) { '()' } else { '(' + (($a | ForEach-Object { PyStr $_ }) -join ', ') + ',)' } }
function F1([double]$v) { $v.ToString('F1', $Inv) }

$entries = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList

function Add-Entry($src, $chapter, $key, $folder, $itemId, $amount, $x, $y, $z, $diffs) {
    if (-not $itemId -or -not $key) { return }
    if ($folder -like 'AppResident/Instance/*') { [void]$skipped.Add("$key (runtime drop)"); return }
    if ($folder -match '/Door$')                { [void]$skipped.Add("$key (door socket)"); return }
    [void]$entries.Add([pscustomobject]@{
        Src = $src; Chapter = $chapter; Key = $key; Folder = $folder; ItemId = $itemId
        Amount = [math]::Max(1, [int]$amount); X = [double]$x; Y = [double]$y; Z = [double]$z
        Diffs = (Get-NormDiffs $diffs)
    })
}

$ChapterOrder = @{}
$chapterFiles = Get-ChildItem -Path $PSScriptRoot -File | Where-Object { $_.Name -match '^ch\d+_.+\.json$' } | Sort-Object Name
if (-not $chapterFiles) { throw "No ch<NN>_<Chapter>.json file in $PSScriptRoot" }
foreach ($file in $chapterFiles) {
    $doc = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $ChapterOrder[$doc.chapitre] = [int]$doc.numero
    foreach ($it in $doc.items) {
        $diffs = if ("$($it.difficulte)" -eq 'toutes') { @() }
                 else { @(("$($it.difficulte)" -split ',\s*') | ForEach-Object { $DifficultyById[$_.Trim()] }) }
        Add-Entry 'ch' $doc.chapitre $it.cle $it.dossier $it.item_id $it.quantite $it.position.x $it.position.y $it.position.z $diffs
    }
}

$scanFile = Join-Path $DataDir "re9_item_scan.json"
if (Test-Path -LiteralPath $scanFile) {
    $scan = Get-Content -LiteralPath $scanFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $scan.PSObject.Properties) {
        $v = $p.Value
        $chapter = Get-ChapterOf $v.folder_path
        if (-not $chapter -and "$($v.chapter)" -match '(\d+)\.(\d+)') { $chapter = "Chap$($Matches[1])_$($Matches[2])" }
        Add-Entry 'scan' $chapter $p.Name $v.folder_path $v.item_id $v.amount $v.x $v.y $v.z (Get-Zone $v.folder_path).Difficulties
    }
} else {
    Write-Warning "$scanFile not found: only the chapter keys are used"
}

$GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$liveFiles = Get-ChildItem -Path $PSScriptRoot -Recurse -File -Filter 're9_live_*' |
    Where-Object { $_.Extension -in '.json', '.text', '.txt' } |
    Sort-Object { $_.DirectoryName.Length } | Group-Object Name | ForEach-Object { $_.Group[0] } | Sort-Object Name
foreach ($file in $liveFiles) {
    $doc = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $doc.items.PSObject.Properties) {
        $v = $p.Value
        if ($v.dynamic -or -not $v.folder_path) { continue }
        $key = if ($v.static_id) { $v.static_id }
               elseif ($p.Name -match $GuidPattern) { "ctx::$($Matches[0])" }
               else { $p.Name -replace '#\d+$', '' }
        $diffs = @(("$($v.difficulty)" -split ',\s*') | Where-Object { $_ } | ForEach-Object { $DifficultyById[$_] } | Where-Object { $_ })
        Add-Entry 'live' (Get-ChapterOf $v.folder_path) $key $v.folder_path $v.item_id $v.amount $v.x $v.y $v.z $diffs
    }
}

# Meme item a moins de $MergeDistance = meme ramassage, toutes sources et chapitres confondus (Chap3_02/3_20/3_324 = meme hopital).
# Dans une meme source et un meme chapitre, seules les variantes de difficulte au meme point fusionnent (pieces empilees d'un coffre separees).
function Get-Dist($a, $b) { [math]::Sqrt([math]::Pow($a.X - $b.X, 2) + [math]::Pow($a.Y - $b.Y, 2) + [math]::Pow($a.Z - $b.Z, 2)) }
$SrcRank = @{ ch = 0; scan = 1; live = 2 }
function Get-Order($chapter) { if ($chapter -and $ChapterOrder.ContainsKey($chapter)) { $ChapterOrder[$chapter] } else { 9999 } }

$clusters = New-Object System.Collections.ArrayList
$byItem = @{}
foreach ($e in ($entries | Sort-Object { $SrcRank[$_.Src] }, { Get-Order $_.Chapter })) {
    if (-not $byItem.ContainsKey($e.ItemId)) { $byItem[$e.ItemId] = New-Object System.Collections.ArrayList }
    $target = $null
    foreach ($c in $byItem[$e.ItemId]) {
        if ((Get-Dist $c.Rep $e) -ge $MergeDistance) { continue }
        $conflict = $false
        foreach ($m in $c.Members) {
            if ($m.Src -ne $e.Src -or $m.Chapter -ne $e.Chapter) { continue }
            $variant = ((Get-Dist $m $e) -lt 0.05) -and ((@($m.Diffs) -join ',') -ne (@($e.Diffs) -join ','))
            if (-not $variant) { $conflict = $true; break }
        }
        if (-not $conflict) { $target = $c; break }
    }
    # Scan/live n'ajoutent que des cles : sans export de chapitre, ce serait un check inatteignable
    if (-not $target -and $e.Src -ne 'ch') {
        $best = $null; $bestDist = $FallbackDistance
        foreach ($c in $byItem[$e.ItemId]) {
            $d = Get-Dist $c.Rep $e
            if ($d -ge $bestDist) { continue }
            if (@($c.Members | Where-Object { $_.Src -eq $e.Src -and $_.Chapter -eq $e.Chapter }).Count) { continue }
            $best = $c; $bestDist = $d
        }
        if (-not $best) { [void]$skipped.Add("$($e.Key) ($($e.Src): no chapter placement nearby)"); continue }
        $target = $best
    }
    if (-not $target) {
        $target = [pscustomobject]@{ Rep = $e; Members = (New-Object System.Collections.ArrayList) }
        [void]$byItem[$e.ItemId].Add($target)
        [void]$clusters.Add($target)
    }
    [void]$target.Members.Add($e)
}

$items = @((Get-Content -LiteralPath (Join-Path $DataDir "item_list.json") -Raw -Encoding UTF8 | ConvertFrom-Json).items | Sort-Object id)
$knownIds = @{}; foreach ($it in $items) { $knownIds[$it.id] = $true }
$extraIds = @($clusters | ForEach-Object { $_.Rep.ItemId } | Where-Object { -not $knownIds.ContainsKey($_) } | Sort-Object -Unique)
foreach ($id in $extraIds) {
    $name = if ($ExtraItemNames.ContainsKey($id)) { $ExtraItemNames[$id] } else { "Unknown Item ($id)" }
    $items += [pscustomobject]@{ id = $id; name = $name; category = (Get-ExtraCategory $id) }
}

$nameCounts = $items | Group-Object name -AsHashTable
$itemRows = @()
$i = 0
foreach ($it in $items) {
    $name = if ($nameCounts[$it.name].Count -gt 1) { "$($it.name) ($($it.id))" } else { $it.name }
    $cls = if ($ProgressionOverrides -contains $it.id -or $ProgressionCategories -contains $it.category) { "progression" }
           elseif ($UsefulCategories -contains $it.category) { "useful" }
           else { "filler" }
    $itemRows += [pscustomobject]@{ Name = $name; Code = $ItemBase + $i; GameId = $it.id; Category = $it.category; Cls = $cls; Amount = 1 }
    $i++
}
$itemById = @{}; foreach ($r in $itemRows) { $itemById[$r.GameId] = $r }

$locs = @()
foreach ($c in $clusters) {
    $known = @($c.Members | Where-Object { (Get-Order $_.Chapter) -lt 9999 })
    if (-not $known.Count) { [void]$skipped.Add("$($c.Rep.Key) (unknown chapter)"); continue }
    $first = $known | Sort-Object { Get-Order $_.Chapter }, { $SrcRank[$_.Src] } | Select-Object -First 1
    $diffs = if (@($c.Members | Where-Object { @($_.Diffs).Count -eq 0 }).Count) { @() }
             else { Get-NormDiffs ($c.Members | ForEach-Object { $_.Diffs }) }
    $chMember = $c.Members | Where-Object { $_.Src -eq 'ch' } | Select-Object -First 1
    $amount = if ($chMember) { $chMember.Amount } else { $first.Amount }
    $locs += [pscustomobject]@{
        Chapter = $first.Chapter; Order = (Get-Order $first.Chapter); Label = (Get-ChapterLabel $first.Chapter)
        Zone = (Get-Zone $first.Folder).Zone; Item = $itemById[$c.Rep.ItemId]; Amount = $amount
        Difficulties = @($diffs); Members = $c.Members; Pos = @($first.X, $first.Y, $first.Z)
    }
}

# Quantite recue = la plus frequente ; beaucoup de munitions exportent 1, donc mediane des quantites > 1 pour l'Ammo
foreach ($g in ($locs | Group-Object { $_.Item.GameId })) {
    $amounts = @($g.Group | ForEach-Object { [int]$_.Amount })
    $stacks = @($amounts | Where-Object { $_ -gt 1 } | Sort-Object)
    $itemById[$g.Name].Amount = if ($itemById[$g.Name].Category -eq 'Ammo' -and $stacks.Count) { $stacks[[int][math]::Floor(($stacks.Count - 1) / 2)] }
        else { [int](($amounts | Group-Object | Sort-Object Count, { -[int]$_.Name } -Descending | Select-Object -First 1).Name) }
}

$locs = $locs | Sort-Object Order, Zone, { $_.Item.Name }, { $_.Pos[0] }, { $_.Pos[2] }
$locRows = @()
$usedNames = @{}
$j = 0
foreach ($l in $locs) {
    $base = "$($l.Label) $($l.Zone) - $($l.Item.Name)"
    $n = if ($usedNames.ContainsKey($base)) { $usedNames[$base] + 1 } else { 1 }
    $usedNames[$base] = $n
    $locRows += [pscustomobject]@{
        Name = $(if ($n -gt 1) { "$base #$n" } else { $base }); Base = $base; Code = $LocBase + $j
        Chapter = $l.Label; Zone = $l.Zone; Vanilla = $l.Item.Name; VanillaId = $l.Item.GameId; Amount = $l.Amount
        Difficulties = $l.Difficulties; Members = $l.Members; Pos = $l.Pos; Keys = @()
    }
    $j++
}
foreach ($r in $locRows) { if ($usedNames[$r.Base] -gt 1 -and $r.Name -eq $r.Base) { $r.Name = "$($r.Name) #1" } }

# Cle partagee par plusieurs locations : on suffixe la position (@x,y,z) pour que le client les distingue.
# Les ctx::xxxxxxxx-0000-0000-... changent a chaque session, on les jette.
$RuntimeCtx = '^ctx::[0-9a-fA-F]{8}-0000-0000-'
function Get-KeyBase($k) { ($k -split '@', 2)[0] }
$keyUse = @{}
foreach ($r in $locRows) {
    foreach ($k in @($r.Members | ForEach-Object { Get-KeyBase $_.Key } | Sort-Object -Unique)) { $keyUse[$k] = 1 + [int]$keyUse[$k] }
}
foreach ($r in $locRows) {
    $r.Keys = @($r.Members | Where-Object { $_.Key -notmatch $RuntimeCtx } | ForEach-Object {
        if ($keyUse[(Get-KeyBase $_.Key)] -gt 1 -and $_.Key -notmatch '@') { "{0}@{1},{2},{3}" -f $_.Key, (F1 $_.X), (F1 $_.Y), (F1 $_.Z) } else { $_.Key }
    } | Sort-Object -Unique)
}

$chapters = @(1..$StoryChapterCount | ForEach-Object { "Ch$_" })
foreach ($k in $ChapterOrder.Keys) {
    if (-not $StoryChapter.Contains($k)) { throw "Chapter $k has no story number in `$StoryChapter" }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Generated by generate.ps1 from item_list.json and the chapter exports. Do not edit by hand.')
[void]$sb.AppendLine('from typing import NamedTuple')
[void]$sb.AppendLine('from BaseClasses import ItemClassification')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('class RE9ItemData(NamedTuple):')
[void]$sb.AppendLine('    code: int')
[void]$sb.AppendLine('    game_id: str')
[void]$sb.AppendLine('    category: str')
[void]$sb.AppendLine('    classification: ItemClassification')
[void]$sb.AppendLine('    default_amount: int  # quantity given when received')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('item_table: dict[str, RE9ItemData] = {')
foreach ($r in $itemRows) {
    [void]$sb.AppendLine("    $(PyStr $r.Name): RE9ItemData($($r.Code), $(PyStr $r.GameId), $(PyStr $r.Category), ItemClassification.$($r.Cls), $($r.Amount)),")
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('item_name_to_id: dict[str, int] = {name: data.code for name, data in item_table.items()}')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('item_name_groups: dict[str, set[str]] = {}')
[void]$sb.AppendLine('for _name, _data in item_table.items():')
[void]$sb.AppendLine('    item_name_groups.setdefault(_data.category, set()).add(_name)')
[IO.File]::WriteAllText((Join-Path $OutDir "Items.py"), $sb.ToString(), $Utf8)

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Generated by generate.ps1 from the chapter exports. Do not edit by hand.')
[void]$sb.AppendLine('from typing import NamedTuple')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('# Story order')
[void]$sb.AppendLine("CHAPTERS: tuple[str, ...] = $(PyTuple $chapters)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('class RE9LocationData(NamedTuple):')
[void]$sb.AppendLine('    code: int')
[void]$sb.AppendLine('    chapter: str')
[void]$sb.AppendLine('    zone: str')
[void]$sb.AppendLine('    vanilla_item: str')
[void]$sb.AppendLine('    amount: int')
[void]$sb.AppendLine('    difficulties: tuple[str, ...]  # empty = present on every difficulty')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('location_table: dict[str, RE9LocationData] = {')
foreach ($r in $locRows) {
    [void]$sb.AppendLine("    $(PyStr $r.Name): RE9LocationData($($r.Code), $(PyStr $r.Chapter), $(PyStr $r.Zone), $(PyStr $r.Vanilla), $($r.Amount), $(PyTuple $r.Difficulties)),")
}
# Étagère du Supply Box : pas de mesh, le client renomme la ligne. Ids après le dernier pickup.
[void]$sb.AppendLine('    "Supply Box - Handgun Ammo": RE9LocationData(7091619, "Ch1", "Supply Box", "Handgun Ammo", 10, ()),')
[void]$sb.AppendLine('    "Supply Box - Shotgun Shells": RE9LocationData(7091620, "Ch1", "Supply Box", "Shotgun Shells", 3, ()),')
[void]$sb.AppendLine('    "Supply Box - Machine Gun Ammo": RE9LocationData(7091621, "Ch1", "Supply Box", "Machine Gun Ammo", 20, ()),')
[void]$sb.AppendLine('    "Supply Box - Rifle Ammo": RE9LocationData(7091622, "Ch1", "Supply Box", "Rifle Ammo", 3, ()),')
[void]$sb.AppendLine('    "Supply Box - Med Injector": RE9LocationData(7091623, "Ch1", "Supply Box", "Med Injector", 1, ()),')
[void]$sb.AppendLine('    "Supply Box - Silencer 9": RE9LocationData(7091624, "Ch1", "Supply Box", "Silencer 9", 1, ()),')
[void]$sb.AppendLine('    "Supply Box - MSBG 500": RE9LocationData(7091625, "Ch1", "Supply Box", "MSBG 500", 1, ()),')
[void]$sb.AppendLine('    "Supply Box - 990-TAC": RE9LocationData(7091626, "Ch1", "Supply Box", "990-TAC", 1, ()),')
[void]$sb.AppendLine('    "Supply Box - Stiri REVO3 A1": RE9LocationData(7091627, "Ch1", "Supply Box", "Stiri REVO3 A1", 1, ()),')
[void]$sb.AppendLine('    "Supply Box - Body Armor Lv.I": RE9LocationData(7091628, "Ch1", "Supply Box", "Body Armor Lv.I", 1, ()),')
[void]$sb.AppendLine('    "Supply Box - Case Upgrade (8x13)": RE9LocationData(7091629, "Ch1", "Supply Box", "Case Upgrade (8x13)", 1, ()),')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('location_name_to_id: dict[str, int] = {name: data.code for name, data in location_table.items()}')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('location_name_groups: dict[str, set[str]] = {}')
[void]$sb.AppendLine('for _name, _data in location_table.items():')
[void]$sb.AppendLine('    location_name_groups.setdefault(_data.chapter, set()).add(_name)')
[void]$sb.AppendLine('    location_name_groups.setdefault(f"{_data.chapter} {_data.zone}", set()).add(_name)')
[IO.File]::WriteAllText((Join-Path $OutDir "Locations.py"), $sb.ToString(), $Utf8)

# Table de correspondance lue par le client Lua
$keyToLoc = [ordered]@{}
foreach ($r in $locRows) { foreach ($k in $r.Keys) { $keyToLoc[$k] = $r.Code } }
$gameMap = [ordered]@{
    game              = "Resident Evil Requiem"
    chapters          = $chapters
    location_by_key   = $keyToLoc
    locations         = @($locRows | ForEach-Object { [ordered]@{
        id = $_.Code; name = $_.Name; chapter = $_.Chapter; zone = $_.Zone
        vanilla_item = $_.Vanilla; vanilla_game_id = $_.VanillaId; amount = $_.Amount
        keys = @($_.Keys); pos = @($_.Pos | ForEach-Object { [math]::Round($_, 2) }); difficulties = @($_.Difficulties) } })
    items             = [ordered]@{}
}
# Étagère du Supply Box : sans clé ni position, le patcher de scènes ne touche aucun mesh
$gameMap.locations += @(
    [ordered]@{ id = 7091619; name = "Supply Box - Handgun Ammo"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Handgun Ammo"; vanilla_game_id = "it40_00_000"; amount = 10; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091620; name = "Supply Box - Shotgun Shells"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Shotgun Shells"; vanilla_game_id = "it40_01_000"; amount = 3; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091621; name = "Supply Box - Machine Gun Ammo"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Machine Gun Ammo"; vanilla_game_id = "it40_03_000"; amount = 20; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091622; name = "Supply Box - Rifle Ammo"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Rifle Ammo"; vanilla_game_id = "it40_05_000"; amount = 3; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091623; name = "Supply Box - Med Injector"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Med Injector"; vanilla_game_id = "it00_01_000"; amount = 1; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091624; name = "Supply Box - Silencer 9"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Silencer 9"; vanilla_game_id = "it10_00_002"; amount = 1; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091625; name = "Supply Box - MSBG 500"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "MSBG 500"; vanilla_game_id = "it10_01_000"; amount = 1; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091626; name = "Supply Box - 990-TAC"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "990-TAC"; vanilla_game_id = "it10_01_003"; amount = 1; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091627; name = "Supply Box - Stiri REVO3 A1"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Stiri REVO3 A1"; vanilla_game_id = "it10_03_001"; amount = 1; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091628; name = "Supply Box - Body Armor Lv.I"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Body Armor Lv.I"; vanilla_game_id = "it10_30_000"; amount = 1; keys = @(); pos = @(); difficulties = @() },
    [ordered]@{ id = 7091629; name = "Supply Box - Case Upgrade (8x13)"; chapter = "Ch1"; zone = "Supply Box"; vanilla_item = "Case Upgrade (8x13)"; vanilla_game_id = "it99_01_001"; amount = 1; keys = @(); pos = @(); difficulties = @() }
)
# Drops de Leon : déclarés dans __init__.py, sans clé ni position (le client les remplit dans l'ordre)
$gameMap.locations += @(1..50 | ForEach-Object { [ordered]@{
    id = 7092000 + $_ - 1; name = "Enemy Drop #$_"; chapter = "Drop"; zone = "Enemy"
    vanilla_item = ""; vanilla_game_id = ""; amount = 1; keys = @(); pos = @(); difficulties = @() } })
foreach ($r in $itemRows) {
    $gameMap.items["$($r.Code)"] = [ordered]@{ name = $r.Name; game_id = $r.GameId; category = $r.Category; amount = $r.Amount }
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "re9_ap_ids.json"), ($gameMap | ConvertTo-Json -Depth 6), $Utf8)

"Items:     $($itemRows.Count)  ($(($itemRows | Group-Object Cls | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '))"
if ($extraIds.Count) { "  not in item_list.json (named 'Unknown Item'): $($extraIds -join ', ')" }
"Locations: $($locRows.Count)  (from $($entries.Count) entries: $(($entries | Group-Object Src | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '); $($skipped.Count) skipped)"
$locRows | Group-Object Chapter | Sort-Object { $chapters.IndexOf($_.Name) } | ForEach-Object { "  $($_.Name): $($_.Count)" }
"  every difficulty: $(@($locRows | Where-Object { -not @($_.Difficulties).Count }).Count)"
$locRows | Where-Object { @($_.Difficulties).Count } | Group-Object { $_.Difficulties -join '+' } | ForEach-Object { "  only $($_.Name): $($_.Count)" }
"  zones named 'Misc': $(@($locRows | Where-Object { $_.Zone -match 'Misc' }).Count)"
"Output: $OutDir\Items.py, $OutDir\Locations.py, $PSScriptRoot\re9_ap_ids.json"
