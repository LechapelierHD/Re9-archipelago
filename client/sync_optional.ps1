# Source unique : autorun/ArchipelagoRE9 → optional (modules installables à part).
# Ne pas éditer optional/ à la main — relancer ce script (ou build_package / make_patch).
param()

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Autorun = Join-Path $Here "reframework\autorun\ArchipelagoRE9"
$Optional = Join-Path $Here "reframework\optional"

# Seul module optionnel consommé par le lanceur (ClientInstaller.ChapterSkipFile)
$Modules = @("chapterskip.lua")

New-Item -ItemType Directory -Force $Optional | Out-Null
foreach ($name in $Modules) {
    $src = Join-Path $Autorun $name
    if (-not (Test-Path $src)) { throw "Source manquante : $src" }
    Copy-Item $src (Join-Path $Optional $name) -Force
    Write-Host "  sync optional/$name"
}

# Retirer les miroirs obsolètes (tout sauf la liste ci-dessus)
Get-ChildItem $Optional -Filter *.lua -ErrorAction SilentlyContinue |
    Where-Object { $Modules -notcontains $_.Name } |
    ForEach-Object {
        Write-Host "  remove stale $($_.Name)" -ForegroundColor Yellow
        Remove-Item $_.FullName -Force
    }

Write-Host "optional sync OK" -ForegroundColor Green
exit 0
