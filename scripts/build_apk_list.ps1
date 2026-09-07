# Build MD5-unique APK list for analyze_one_by_one.ps1
param(
  [Parameter(Mandatory = $true)][string]$ApkDir,
  [string]$OutList = ""
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
if (-not $OutList) { $OutList = Join-Path $SkillOut "apk_unique_list.txt" }
New-Item -ItemType Directory -Force -Path (Split-Path $OutList -Parent) | Out-Null
$unique = [ordered]@{}
Get-ChildItem -LiteralPath $ApkDir -Filter *.apk -File | ForEach-Object {
  $h = (Get-FileHash $_.FullName -Algorithm MD5).Hash
  if (-not $unique.Contains($h)) { $unique[$h] = $_.FullName }
}
$unique.Values | Set-Content -LiteralPath $OutList -Encoding UTF8
Write-Host "unique=$($unique.Count) -> $OutList"
