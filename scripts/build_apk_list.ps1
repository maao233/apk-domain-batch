# Build MD5-unique APK list. Size is recorded for humans; never used to skip install.
param(
  [Parameter(Mandatory = $true)][string]$ApkDir,
  [string]$OutList = "",
  [string]$OutBySize = "",
  [string]$OutReport = ""
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
if (-not $OutList) { $OutList = Join-Path $SkillOut "apk_unique_list.txt" }
if (-not $OutBySize) { $OutBySize = Join-Path $SkillOut "apk_ok_mitm_bysize.txt" }
if (-not $OutReport) { $OutReport = Join-Path $SkillOut "apk_size_report.csv" }
New-Item -ItemType Directory -Force -Path (Split-Path $OutList -Parent) | Out-Null

$unique = [ordered]@{}
Get-ChildItem -LiteralPath $ApkDir -Filter *.apk -File | ForEach-Object {
  $h = (Get-FileHash $_.FullName -Algorithm MD5).Hash
  if (-not $unique.Contains($h)) {
    $unique[$h] = [pscustomobject]@{
      Path = $_.FullName
      Name = $_.Name
      Bytes = $_.Length
      MB = [math]::Round($_.Length / 1MB, 2)
    }
  }
}

$all = @($unique.Values)
$all | ForEach-Object { $_.Path } | Set-Content -LiteralPath $OutList -Encoding UTF8
$all | Sort-Object MB | ForEach-Object { $_.Path } | Set-Content -LiteralPath $OutBySize -Encoding UTF8

$rows = $all | ForEach-Object {
  [pscustomobject]@{
    apk = $_.Name
    mb = $_.MB
    bytes = $_.Bytes
    decision = "try_install"
    path = $_.Path
  }
}
$rows | Sort-Object mb -Descending | Export-Csv -LiteralPath $OutReport -NoTypeInformation -Encoding UTF8

Write-Host "unique=$($unique.Count) (no size skip; install all; reboot -> install_failed)"
Write-Host "list -> $OutList"
Write-Host "bysize -> $OutBySize"
Write-Host "report -> $OutReport"
$rows | Sort-Object mb -Descending | Format-Table apk, mb, decision -AutoSize
