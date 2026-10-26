# Usage : install.bat, ou .\install.ps1 [-GamePath <dossier de re9.exe>] [-IdsFile ...\re9_ap_ids.json]
# re9_ap_ids.json doit sortir du même generate.ps1 que l'apworld de la room

param(
    [string]$GamePath = "",
    [string]$IdsFile = ""
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

function Find-GamePath {
    $candidates = New-Object System.Collections.Generic.List[string]
    $steamRoots = @()
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam")) {
        try {
            $p = (Get-ItemProperty $key -ErrorAction Stop)
            if ($p.SteamPath)   { $steamRoots += $p.SteamPath }
            if ($p.InstallPath) { $steamRoots += $p.InstallPath }
        } catch {}
    }
    $steamRoots += "C:\Program Files (x86)\Steam"
    foreach ($root in ($steamRoots | Select-Object -Unique)) {
        $root = $root -replace "/", "\"
        $candidates.Add((Join-Path $root "steamapps\common"))
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $candidates.Add((Join-Path ($m.Groups[1].Value -replace "\\\\", "\") "steamapps\common"))
            }
        }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
        $candidates.Add((Join-Path $drive "SteamLibrary\steamapps\common"))
    }
    foreach ($common in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path $common)) { continue }
        foreach ($dir in Get-ChildItem $common -Directory -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $dir.FullName "re9.exe")) { return $dir.FullName }
        }
    }
    return ""
}

function Read-Default($prompt, $default) {
    $suffix = if ($default) { " [$default]" } else { "" }
    $v = Read-Host "$prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim()
}

Write-Host ""
Write-Host "  Archipelago - Resident Evil Requiem : installation" -ForegroundColor White
Write-Host ""

Write-Step "Recherche du jeu"
if (-not $GamePath) { $GamePath = Find-GamePath }
if (-not $GamePath -or -not (Test-Path (Join-Path $GamePath "re9.exe"))) {
    $GamePath = Read-Host "Dossier du jeu introuvable. Colle le chemin du dossier qui contient re9.exe"
}
if (-not (Test-Path (Join-Path $GamePath "re9.exe"))) { throw "re9.exe introuvable dans '$GamePath'." }
Write-Ok $GamePath

if (Get-Process -Name "re9" -ErrorAction SilentlyContinue) { throw "RE9 est lancé. Ferme le jeu puis relance l'installation." }

$RefDir = Join-Path $GamePath "reframework"
if (-not (Test-Path (Join-Path $GamePath "dinput8.dll"))) {
    Write-Warn2 "REFramework ne semble pas installé (dinput8.dll absent). Installe-le avant de jouer."
}

Write-Step "lua-apclientpp.dll"
Copy-Item (Join-Path $Here "native\lua-apclientpp.dll") $GamePath -Force
Copy-Item (Join-Path $Here "native\THIRD-PARTY-NOTICES-lua-apclientpp.txt") $GamePath -Force
Write-Ok "copiée à la racine du jeu"

Write-Step "Scripts REFramework"
$Autorun = Join-Path $RefDir "autorun"
New-Item -ItemType Directory -Force (Join-Path $Autorun "ArchipelagoRE9") | Out-Null
Copy-Item (Join-Path $Here "reframework\autorun\ArchipelagoRE9.lua") $Autorun -Force
Copy-Item (Join-Path $Here "reframework\autorun\ArchipelagoRE9\*.lua") (Join-Path $Autorun "ArchipelagoRE9") -Force
Write-Ok "reframework\autorun\ArchipelagoRE9.lua + modules"

# Anciens clients : ils bloqueraient aussi les objets et injecteraient en double
foreach ($old in @("AP_client.lua", "randomizer\pickup.lua", "ArchipelagoRE9_old.lua")) {
    $p = Join-Path $Autorun $old
    if (Test-Path $p) {
        Move-Item $p "$p.disabled" -Force
        Write-Warn2 "ancien script désactivé : $old -> $old.disabled"
    }
}

Write-Step "Données"
$DataDir = Join-Path $RefDir "data\ArchipelagoRE9"
New-Item -ItemType Directory -Force $DataDir | Out-Null
$bundledIds = Join-Path $Here "reframework\data\ArchipelagoRE9\re9_ap_ids.json"
$apworldIds = Join-Path $Here "..\..\re9_apworld\re9_ap_ids.json"
if (-not $IdsFile) {
    $IdsFile = $bundledIds
    if ((Test-Path $apworldIds) -and (Get-Item $apworldIds).LastWriteTime -gt (Get-Item $bundledIds).LastWriteTime) {
        $IdsFile = (Resolve-Path $apworldIds).Path
        Write-Warn2 "re9_ap_ids.json plus récent trouvé dans re9_apworld : utilisé"
    }
}
Copy-Item $IdsFile (Join-Path $DataDir "re9_ap_ids.json") -Force
Copy-Item (Join-Path $Here "reframework\data\ArchipelagoRE9\item_list.json") $DataDir -Force
Write-Ok "reframework\data\ArchipelagoRE9\ (re9_ap_ids.json : $IdsFile)"

Write-Step "Session Archipelago"
$connFile = Join-Path $DataDir "ap_connection.json"
$cur = @{ server_address = ""; slot_name = ""; password = "" }
if (Test-Path $connFile) {
    try {
        $j = Get-Content $connFile -Raw | ConvertFrom-Json
        $cur.server_address = "$($j.server_address)"; $cur.slot_name = "$($j.slot_name)"; $cur.password = "$($j.password)"
    } catch {}
}
$server = Read-Default "Adresse du serveur (ex : archipelago.gg:38281)" $cur.server_address
$slot = Read-Default "Nom du slot" $cur.slot_name
$password = Read-Default "Mot de passe (vide si aucun)" $cur.password
$conn = [ordered]@{ server_address = "$server"; slot_name = "$slot"; password = "$password" } | ConvertTo-Json
[System.IO.File]::WriteAllText($connFile, $conn, $Utf8NoBom)
Write-Ok "ap_connection.json écrit (modifiable aussi en jeu)"

Write-Host ""
Write-Host "Installation terminée." -ForegroundColor Green
Write-Host "En jeu : touche Insert > 'Archipelago - Resident Evil Requiem'."
Write-Host "Connecte-toi au slot AVANT de ramasser des objets (le client doit connaître la liste des checks)."
Write-Host ""
