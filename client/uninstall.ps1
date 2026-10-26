# -Purge efface aussi reframework\data\ArchipelagoRE9 (connexion, état de la partie)
param(
    [Parameter(Mandatory = $true)][string]$GamePath,
    [switch]$Purge
)

$ErrorActionPreference = "Stop"
$Autorun = Join-Path $GamePath "reframework\autorun"
Remove-Item (Join-Path $Autorun "ArchipelagoRE9.lua") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $Autorun "ArchipelagoRE9") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $GamePath "lua-apclientpp.dll") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $GamePath "THIRD-PARTY-NOTICES-lua-apclientpp.txt") -Force -ErrorAction SilentlyContinue
if ($Purge) {
    Remove-Item (Join-Path $GamePath "reframework\data\ArchipelagoRE9") -Recurse -Force -ErrorAction SilentlyContinue
}
"Client Archipelago RE9 retiré de $GamePath"
