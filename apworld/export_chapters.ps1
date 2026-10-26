# Seuls les sous-dossiers "*Item*" sont actives : activer "*Gimmick*" fait crasher le jeu (Chap3_03)
# Usage : powershell -ExecutionPolicy Bypass -File export_chapters.ps1 [-Chapters Chap3_03,Chap4_00]
param(
    [string]$Base     = "http://localhost:8899",
    [string[]]$Chapters,
    [int]$WaitSeconds = 8,
    [string]$Out      = (Join-Path $PSScriptRoot "re9_chapter_items.json")
)

$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Json($url) {
    $resp = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 90
    $bytes = New-Object byte[] $resp.RawContentStream.Length
    [void]$resp.RawContentStream.Read($bytes, 0, $bytes.Length)
    $Utf8.GetString($bytes) | ConvertFrom-Json
}

function Invoke-Folder($address, $method, $arg) {
    $body = @{ address = $address; kind = 'managed'; typeName = 'via.Folder'; methodName = $method }
    if ($null -ne $arg) { $body.args = @(@{ type = 'bool'; value = $arg }) }
    Invoke-RestMethod "$Base/api/explorer/method" -Method Post -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Depth 4 -Compress) | Out-Null
}

function Get-ChapterFolder($name) {
    (Get-Json "$Base/api/folders?depth=2").children | Where-Object name -eq $name
}

$tree = Get-Json "$Base/api/folders?depth=1"
$loaded = @($tree.children | Where-Object active | ForEach-Object name)
if (-not $Chapters) {
    $Chapters = @($tree.children | Where-Object { $_.name -match '^(Chap\d|FF_)' -and -not $_.active } | ForEach-Object name)
}

$result = [ordered]@{}
if (Test-Path $Out) {
    $prev = Get-Content -LiteralPath $Out -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $prev.PSObject.Properties) { $result[$p.Name] = $p.Value }
}

foreach ($chapter in $Chapters) {
    if ($loaded -contains $chapter) { Write-Host "$chapter is the running chapter, skipped (use export_live_items.ps1)"; continue }
    Write-Host "== $chapter"
    try {
        $root = Get-ChapterFolder $chapter
        if (-not $root) { Write-Host "   not found"; continue }

        Invoke-Folder $root.address 'set_Standby' $true
        Invoke-Folder $root.address 'activate' $null
        Start-Sleep -Seconds 3

        $itemFolders = @((Get-ChapterFolder $chapter).children | Where-Object { $_.name -match 'Item' })
        foreach ($f in $itemFolders) {
            Invoke-Folder $f.address 'set_Standby' $true
            Invoke-Folder $f.address 'activate' $null
        }
        Start-Sleep -Seconds $WaitSeconds

        $cores = Get-Json "$Base/api/itemcores?folder=MainGame/$chapter"
        Write-Host "   item folders: $(($itemFolders.name) -join ', ')  ->  $($cores.count) items"
        $result[$chapter] = @($cores.items | ForEach-Object {
            [ordered]@{
                static_id   = $_.staticId
                item_id     = $_.itemId
                amount      = $_.amount
                difficulty  = $_.difficulty
                x           = [math]::Round([double]$_.position.x, 2)
                y           = [math]::Round([double]$_.position.y, 2)
                z           = [math]::Round([double]$_.position.z, 2)
                game_object = $_.gameObject
                folder_path = $_.folderPath
            }
        })
        [IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Depth 5), $Utf8)

        foreach ($f in $itemFolders) { Invoke-Folder $f.address 'deactivate' $null; Invoke-Folder $f.address 'set_Standby' $false }
        Invoke-Folder $root.address 'deactivate' $null
        Invoke-Folder $root.address 'set_Standby' $false
        Start-Sleep -Seconds 3
    } catch {
        Write-Host "   STOP: $($_.Exception.Message) (game may have crashed; results so far are in $Out)"
        break
    }
}

"Chapters exported: $($result.Count)  ->  $Out"
