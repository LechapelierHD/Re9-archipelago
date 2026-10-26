# Usage : .\make_patch.ps1 -Title "Interface RE4R" -Notes "Modif 1","Modif 2" [-Version 0.3.0] [-Label "1.0.0 alpha"] [-Output <dossier>] [-Launcher] [-GitHub]
# -Launcher : embarque aussi l'exe du lanceur (le bouton "Mettre a jour" le remplace puis redemarre)
# -GitHub : enchaine sur publish_github.ps1 ; -TitleEn / -NotesEn vont dans notes_en.json
param(
    [string]$Title = "",
    [string[]]$Notes = @(),
    [string]$TitleEn = "",
    [string[]]$NotesEn = @(),
    [string]$Version = "",
    [string]$Label = "",   # affiche a la place de Version, qui reste le numero compare
    [string]$Output = "",
    [switch]$Launcher,
    [switch]$GitHub
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Client = Split-Path -Parent $Here
$Root = Split-Path -Parent (Split-Path -Parent $Client)
$ApworldDir = Join-Path $Root "re9_apworld"
if (-not $Output) { $Output = Join-Path $Root "RE9 AP Patches" }
New-Item -ItemType Directory -Force $Output | Out-Null
$Utf8 = New-Object Text.UTF8Encoding($false)

$feedPath = Join-Path $Output "patches.json"
$patches = @()
if (Test-Path $feedPath) {
    $feed = [IO.File]::ReadAllText($feedPath, $Utf8) | ConvertFrom-Json
    $patches = @($feed.patches | Where-Object { $_ })
}

if (-not $Version) {
    $csproj = Get-Content -Raw (Join-Path $Here "RE9.AP.Launcher\RE9.AP.Launcher.csproj")
    $base = [version]"0.0.0"
    if ($csproj -match "<Version>([\d\.]+)</Version>") { $base = [version]$Matches[1] }
    foreach ($p in $patches) { $v = [version]$p.version; if ($v -gt $base) { $base = $v } }
    $build = [math]::Max(0, $base.Build) + 1
    $Version = "{0}.{1}.{2}" -f $base.Major, $base.Minor, $build
}
if ($patches | Where-Object { $_.version -eq $Version }) { throw "Version $Version already published." }
if (-not $Label) { $Label = $Version }
if (-not $Title) { $Title = "Patch $Label" }
$date = Get-Date -Format "yyyy-MM-dd HH:mm"

$dataDir = Join-Path $Client "reframework\data\ArchipelagoRE9"
# apworld attendu = world_version de l'apworld emballé (warn client ↔ seed)
$apworldVer = ""
$apJson = Join-Path $ApworldDir "resident_evil_requiem\archipelago.json"
if (Test-Path $apJson) {
    $apMeta = [IO.File]::ReadAllText($apJson, $Utf8) | ConvertFrom-Json
    if ($apMeta.world_version) { $apworldVer = [string]$apMeta.world_version }
}
# version = ordre de MAJ ; label = texte UI (ex. Version 1.0.105, Label 1.0)
$versionJson = [ordered]@{ version = $Version; date = $date; label = $Label }
if ($apworldVer -ne "") { $versionJson.apworld = $apworldVer }
[IO.File]::WriteAllText((Join-Path $dataDir "client_version.json"), (ConvertTo-Json -InputObject $versionJson), $Utf8)
if ($apworldVer -ne "") { Write-Host ("Apworld attendu : {0}" -f $apworldVer) -ForegroundColor Cyan }

# Meme arborescence que le dossier assets\ du lanceur
& (Join-Path $Client "sync_optional.ps1")
if (-not $?) { throw "sync_optional.ps1 a échoué." }

$stage = Join-Path $env:TEMP ("re9ap_patch_" + $Version)
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
# Important : même forme que Get-ChildItem.FullName (évite TEMP 8.3 → clés ".66/..." cassées)
$stage = (Get-Item -LiteralPath $stage).FullName
function Put($from, $rel) {
    if (-not (Test-Path $from)) { Write-Host "  (missing, skipped) $from" -ForegroundColor Yellow; return }
    $to = Join-Path $stage $rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    Copy-Item $from $to -Force
}
Put (Join-Path $Client "reframework\autorun\ArchipelagoRE9.lua") "Lua\ArchipelagoRE9.lua"
foreach ($f in Get-ChildItem (Join-Path $Client "reframework\autorun\ArchipelagoRE9") -Filter *.lua) {
    Put $f.FullName ("Lua\ArchipelagoRE9\" + $f.Name)
}
# Modules optionnels : installes seulement depuis la page "Etat de la configuration" du lanceur
foreach ($f in Get-ChildItem (Join-Path $Client "reframework\optional") -Filter *.lua -ErrorAction SilentlyContinue) {
    Put $f.FullName ("Lua\Optional\" + $f.Name)
}
Put (Join-Path $dataDir "item_list.json") "Lua\data\ArchipelagoRE9\item_list.json"
Put (Join-Path $dataDir "client_version.json") "Lua\data\ArchipelagoRE9\client_version.json"
Put (Join-Path $dataDir "pickup_event_flags.json") "Lua\data\ArchipelagoRE9\pickup_event_flags.json"
$ids = Join-Path $dataDir "re9_ap_ids.json"
$apIds = Join-Path $ApworldDir "re9_ap_ids.json"
if ((Test-Path $apIds) -and (Get-Item $apIds).LastWriteTime -gt (Get-Item $ids).LastWriteTime) { $ids = $apIds }
Put $ids "Lua\data\ArchipelagoRE9\re9_ap_ids.json"
Put (Join-Path $ApworldDir "resident_evil_requiem.apworld") "Data\resident_evil_requiem.apworld"
Put (Join-Path $ApworldDir "Resident Evil Requiem.yaml") "Data\Resident Evil Requiem.yaml"

# DLL WebSocket AP (compression permessage-deflate) — installée à la racine du jeu
$nativeDir = Join-Path $Client "native"
if (-not (Test-Path (Join-Path $nativeDir "lua-apclientpp.dll"))) {
    $altNative = Join-Path $env:USERPROFILE "Desktop\dec re9\version 1\Resident Evil 9 AP\assets\native"
    if (Test-Path (Join-Path $altNative "lua-apclientpp.dll")) { $nativeDir = $altNative }
}
Put (Join-Path $nativeDir "lua-apclientpp.dll") "native\lua-apclientpp.dll"
Put (Join-Path $Here "assets\reframework\dinput8.dll") "reframework\dinput8.dll"
Put (Join-Path $nativeDir "THIRD-PARTY-NOTICES-lua-apclientpp.txt") "native\THIRD-PARTY-NOTICES-lua-apclientpp.txt"
Put (Join-Path $nativeDir "lua-apclientpp-license.txt") "native\lua-apclientpp-license.txt"

function PutTree($fromDir, $relRoot) {
    if (-not (Test-Path $fromDir)) {
        Write-Host "  (missing tree, skipped) $fromDir" -ForegroundColor Yellow
        return
    }
    Get-ChildItem $fromDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring((Resolve-Path $fromDir).Path.Length).TrimStart('\', '/')
        Put $_.FullName (Join-Path $relRoot $rel)
    }
}

# Pont Python (websockets officiel + permessage-deflate)
$bridgeDir = Join-Path $Here "assets\bridge"
if (-not (Test-Path $bridgeDir)) {
    $altBridge = Join-Path $env:USERPROFILE "Desktop\dec re9\version 1\Resident Evil 9 AP\assets\bridge"
    if (Test-Path $altBridge) { $bridgeDir = $altBridge }
}
PutTree $bridgeDir "bridge"

# Modular Chapter Skip (overlays natives uniquement — pas de meshes items AP)
$mcsNatives = Join-Path $Here "assets\natives"
if (Test-Path $mcsNatives) {
    PutTree $mcsNatives "natives"
    Write-Host "Chapter Skip : natives MCS embarques" -ForegroundColor Cyan
} else {
    Write-Host "  (missing tree, skipped) $mcsNatives" -ForegroundColor Yellow
}

if ($Launcher) {
    Write-Host "Building the launcher..." -ForegroundColor Cyan
    $publish = Join-Path $Here "publish"
    if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
    dotnet publish (Join-Path $Here "RE9.AP.Launcher\RE9.AP.Launcher.csproj") -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o $publish | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }
    Put (Join-Path $publish "RE9.AP.Launcher.exe") "Launcher\RE9.AP.Launcher.exe"
}

# Empreintes SHA256 de chaque fichier (chemins /) — le lanceur les vérifie avant d'installer
function Get-Sha256Hex([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
        finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}
$fileHashes = [ordered]@{}
$stagePrefix = $stage.TrimEnd('\') + '\'
Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
    $full = $_.FullName
    if (-not $full.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fichier hors stage (chemin 8.3?) : $full vs $stage"
    }
    $rel = $full.Substring($stagePrefix.Length).Replace('\', '/')
    if ($rel -ieq 'patch.json') { return }
    if ($rel.StartsWith('.')) { throw "Chemin relatif invalide dans le manifeste : $rel (bug TEMP/FullName)" }
    $fileHashes[$rel] = Get-Sha256Hex $full
}

$info = [ordered]@{
    version = $Version; date = $date; title = $Title; notes = @($Notes)
    label = $Label
    launcher = [bool]$Launcher; files = $fileHashes
}
[IO.File]::WriteAllText((Join-Path $stage "patch.json"), (ConvertTo-Json -InputObject $info -Depth 6), $Utf8)

$zipName = "re9ap_patch_$Version.zip"
$zipPath = Join-Path $Output $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item $stage -Recurse -Force

$zipSha = Get-Sha256Hex $zipPath
Write-Host ("SHA256 zip : {0}" -f $zipSha) -ForegroundColor Cyan

$entry = [ordered]@{
    version = $Version; date = $date; title = $Title; notes = @($Notes)
    label = $Label
    file = $zipName; launcher = [bool]$Launcher; sha256 = $zipSha
}
$all = @($entry) + @($patches)

# notes_en.json (version -> { title, notes }) est refusionne dans toutes les entrees du feed
$enPath = Join-Path $Output "notes_en.json"
$en = [ordered]@{}
if (Test-Path $enPath) {
    $enJson = [IO.File]::ReadAllText($enPath, $Utf8) | ConvertFrom-Json
    foreach ($prop in $enJson.PSObject.Properties) { $en[$prop.Name] = $prop.Value }
}
if ($TitleEn -or $NotesEn.Count -gt 0) {
    $en[$Version] = [ordered]@{ title = $TitleEn; notes = @($NotesEn) }
    $sorted = [ordered]@{}
    foreach ($k in ($en.Keys | Sort-Object { [version]$_ } -Descending)) { $sorted[$k] = $en[$k] }
    [IO.File]::WriteAllText($enPath, (ConvertTo-Json -InputObject $sorted -Depth 4), $Utf8)
    $en = $sorted
}
$all = @(foreach ($p in $all) {
    $o = [ordered]@{}
    foreach ($prop in ([pscustomobject]$p).PSObject.Properties) {
        if ($prop.Name -ne "title_en" -and $prop.Name -ne "notes_en") { $o[$prop.Name] = $prop.Value }
    }
    $t = $en[[string]$o.version]
    if ($t) {
        if ($t.title) { $o.title_en = [string]$t.title }
        if (@($t.notes).Count -gt 0) { $o.notes_en = @($t.notes) }
    }
    $o
})
$newFeed = [ordered]@{ latest = $Version; patches = $all }
[IO.File]::WriteAllText($feedPath, (ConvertTo-Json -InputObject $newFeed -Depth 6), $Utf8)

Write-Host ("Patch {0} published: {1} ({2} KB)" -f $Version, $zipPath, [math]::Round((Get-Item $zipPath).Length / 1KB)) -ForegroundColor Green
if ($GitHub) { & (Join-Path $Here "publish_github.ps1") -Version $Version -Patches $Output }
