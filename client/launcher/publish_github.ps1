# A lancer apres make_patch.ps1, avec gh connecte (gh auth login) : une release vX.Y.Z par version
# Usage : .\publish_github.ps1 [-Version 0.2.2] [-Repo owner/name] [-Patches <dossier>] [-NotesFile notes.md]
param(
    [string]$Version = "",
    [string]$Repo = "LechapelierHD/Re9-archipelago",
    [string]$Patches = "",
    [string]$NotesFile = ""
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Here))
if (-not $Patches) { $Patches = Join-Path $Root "RE9 AP Patches" }
$Utf8 = New-Object Text.UTF8Encoding($false)

$feedPath = Join-Path $Patches "patches.json"
if (-not (Test-Path $feedPath)) { throw "No patches.json in $Patches (run make_patch.ps1 first)." }
$feed = [IO.File]::ReadAllText($feedPath, $Utf8) | ConvertFrom-Json
$all = @($feed.patches | Where-Object { $_ })
if (-not $Version) { $Version = $feed.latest }
$entry = $all | Where-Object { $_.version -eq $Version } | Select-Object -First 1
if (-not $entry) { throw "Patch $Version not found in $feedPath." }
$zip = Join-Path $Patches $entry.file
if (-not (Test-Path $zip)) { throw "Missing file: $zip" }

# Le lanceur ne prend que le dernier zip (client complet), les anciennes entrees ne servent qu'aux notes
$tag = "v$Version"
$existing = @()
$json = gh release list --repo $Repo --limit 100 --json tagName 2>$null
if ($LASTEXITCODE -eq 0 -and $json) { $existing = @(($json | ConvertFrom-Json) | ForEach-Object { $_.tagName }) }
$online = @($all | Where-Object { [version]$_.version -le [version]$Version })
$name = if ($entry.label) { $entry.label } else { $Version }
$webFeed = [ordered]@{ latest = $Version; patches = $online }
$stage = Join-Path $env:TEMP ("re9ap_github_" + $Version)
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
$stageFeed = Join-Path $stage "patches.json"
[IO.File]::WriteAllText($stageFeed, (ConvertTo-Json -InputObject $webFeed -Depth 6), $Utf8)

$notesPath = Join-Path $stage "notes.md"
if ($NotesFile) {
    Copy-Item $NotesFile $notesPath
} else {
    $lines = @($entry.title, "") + @($entry.notes | ForEach-Object { "- " + $_ })
    [IO.File]::WriteAllText($notesPath, ($lines -join "`n"), $Utf8)
}

if ($existing -contains $tag) {
    gh release upload $tag $zip $stageFeed --repo $Repo --clobber
} else {
    gh release create $tag $zip $stageFeed --repo $Repo --title $name --notes-file $notesPath --latest
}
if ($LASTEXITCODE -ne 0) { throw "gh release failed." }
Remove-Item $stage -Recurse -Force
Write-Host "Patch $Version published on GitHub ($Repo, release $tag)." -ForegroundColor Green
