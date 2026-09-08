# Build MD5-unique APK list; optional size gate for MITM install.
param(
  [Parameter(Mandatory = $true)][string]$ApkDir,
  [string]$OutList = "",
  [string]$OutSkipped = "",
  [string]$OutReport = "",
  # APKs at or above this size (MB) are excluded from MITM list (static-only / skip install)
  [double]$MaxMb = 80
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Resolve-Env.ps1")
if (-not $OutList) { $OutList = Join-Path $SkillOut "apk_unique_list.txt" }
if (-not $OutSkipped) { $OutSkipped = Join-Path $SkillOut "apk_too_large.txt" }
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

$ok = [System.Collections.Generic.List[string]]::new()
$skip = [System.Collections.Generic.List[string]]::new()
$rows = foreach ($e in $unique.Values) {
  $tooLarge = $e.MB -ge $MaxMb
  if ($tooLarge) { [void]$skip.Add($e.Path) } else { [void]$ok.Add($e.Path) }
  [pscustomobject]@{
    apk = $e.Name
    mb = $e.MB
    bytes = $e.Bytes
    decision = $(if ($tooLarge) { "too_large_skip_mitm" } else { "ok_mitm" })
    path = $e.Path
  }
}

$ok | Set-Content -LiteralPath $OutList -Encoding UTF8
$skip | Set-Content -LiteralPath $OutSkipped -Encoding UTF8
$rows | Sort-Object mb -Descending | Export-Csv -LiteralPath $OutReport -NoTypeInformation -Encoding UTF8

Write-Host "unique=$($unique.Count) MaxMb=$MaxMb"
Write-Host "ok_mitm=$($ok.Count) -> $OutList"
Write-Host "too_large=$($skip.Count) -> $OutSkipped"
Write-Host "report -> $OutReport"
$rows | Sort-Object mb -Descending | Format-Table apk, mb, decision -AutoSize
