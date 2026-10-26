# Pas de Compress-Archive : sous PS 5.1 il ecrit des "\" que le zipimport d'Archipelago refuse
# Usage : powershell -ExecutionPolicy Bypass -File build_apworld.ps1 [-Install]   (-Install copie dans custom_worlds)
param(
    [switch]$Install,
    [string]$ArchipelagoDir = "C:\ProgramData\Archipelago"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$World = "resident_evil_requiem"
$Src   = Join-Path $PSScriptRoot $World
$Out   = Join-Path $PSScriptRoot "$World.apworld"
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out }

$zip = [IO.Compression.ZipFile]::Open($Out, [IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -LiteralPath $Src -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\__pycache__\\' -and $_.Extension -ne '.pyc' } |
        ForEach-Object {
            $entry = "$World/" + $_.FullName.Substring($Src.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
} finally {
    $zip.Dispose()
}
"Built: $Out"

if ($Install) {
    $dest = Join-Path $ArchipelagoDir "custom_worlds"
    Copy-Item -LiteralPath $Out -Destination $dest -Force
    "Installed: $dest\$World.apworld"
}
