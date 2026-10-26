# Usage : .\build_package.ps1 [-Output "C:\...\Resident Evil 9 AP"] [-Zip]
param(
    [string]$Output = "",
    [switch]$Zip
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Client = Split-Path -Parent $Here
$ApworldDir = Join-Path (Split-Path -Parent (Split-Path -Parent $Client)) "re9_apworld"
if (-not $Output) { $Output = Join-Path (Split-Path -Parent (Split-Path -Parent $Client)) "Resident Evil 9 AP" }

function Copy-Into($from, $to) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    Copy-Item $from $to -Force
}

Write-Host "==> Sync optional (source = autorun)" -ForegroundColor Cyan
& (Join-Path $Client "sync_optional.ps1")
if (-not $?) { throw "sync_optional.ps1 a échoué." }

Write-Host "==> Compilation du lanceur" -ForegroundColor Cyan
$publish = Join-Path $Here "publish"
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
dotnet publish (Join-Path $Here "RE9.AP.Launcher\RE9.AP.Launcher.csproj") -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish a échoué." }

Write-Host "==> Assemblage de $Output" -ForegroundColor Cyan
if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
$assets = Join-Path $Output "assets"
New-Item -ItemType Directory -Force $assets | Out-Null
Copy-Item (Join-Path $publish "RE9.AP.Launcher.exe") $Output

Copy-Into (Join-Path $Client "reframework\autorun\ArchipelagoRE9.lua") (Join-Path $assets "Lua\ArchipelagoRE9.lua")
New-Item -ItemType Directory -Force (Join-Path $assets "Lua\ArchipelagoRE9") | Out-Null
Copy-Item (Join-Path $Client "reframework\autorun\ArchipelagoRE9\*.lua") (Join-Path $assets "Lua\ArchipelagoRE9")
Copy-Into (Join-Path $Client "reframework\data\ArchipelagoRE9\item_list.json") (Join-Path $assets "Lua\data\ArchipelagoRE9\item_list.json")
$clientVersion = Join-Path $Client "reframework\data\ArchipelagoRE9\client_version.json"
if (Test-Path $clientVersion) { Copy-Into $clientVersion (Join-Path $assets "Lua\data\ArchipelagoRE9\client_version.json") }

$ids = Join-Path $Client "reframework\data\ArchipelagoRE9\re9_ap_ids.json"
$apIds = Join-Path $ApworldDir "re9_ap_ids.json"
if ((Test-Path $apIds) -and (Get-Item $apIds).LastWriteTime -gt (Get-Item $ids).LastWriteTime) { $ids = $apIds }
Copy-Into $ids (Join-Path $assets "Lua\data\ArchipelagoRE9\re9_ap_ids.json")

Copy-Into (Join-Path $Client "native\lua-apclientpp.dll") (Join-Path $assets "native\lua-apclientpp.dll")
Copy-Into (Join-Path $Here "assets\reframework\dinput8.dll") (Join-Path $assets "reframework\dinput8.dll")
Copy-Into (Join-Path $Client "native\THIRD-PARTY-NOTICES-lua-apclientpp.txt") (Join-Path $assets "native\THIRD-PARTY-NOTICES-lua-apclientpp.txt")

$apworld = Join-Path $ApworldDir "resident_evil_requiem.apworld"
if (-not (Test-Path $apworld)) { throw "apworld introuvable : $apworld (lance build_apworld.ps1)." }
Copy-Into $apworld (Join-Path $assets "Data\resident_evil_requiem.apworld")
Copy-Into (Join-Path $ApworldDir "Resident Evil Requiem.yaml") (Join-Path $assets "Data\Resident Evil Requiem.yaml")


$sha = { param($p) (Get-FileHash $p -Algorithm SHA256).Hash.ToLower() }
$idsJson = Get-Content -Raw (Join-Path $assets "Lua\data\ArchipelagoRE9\re9_ap_ids.json") | ConvertFrom-Json
$stamp = [ordered]@{
    staged_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    payload = [ordered]@{
        exe_sha256 = & $sha (Join-Path $Output "RE9.AP.Launcher.exe")
        apworld_sha256 = & $sha (Join-Path $assets "Data\resident_evil_requiem.apworld")
        locations = @($idsJson.locations).Count
        chapters = @($idsJson.chapters).Count
    }
}
[IO.File]::WriteAllText((Join-Path $assets "PAYLOAD_STAMP.json"), ($stamp | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

Get-ChildItem $Output -Recurse -File | ForEach-Object { "  " + $_.FullName.Substring($Output.Length + 1) + "  (" + [math]::Round($_.Length / 1KB) + " Ko)" }

if ($Zip) {
    $zipPath = "$Output.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($Output, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "Archive : $zipPath" -ForegroundColor Green
}
Write-Host "Paquet prêt : $Output" -ForegroundColor Green
