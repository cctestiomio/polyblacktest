<# patch-livetracker-stats.ps1
   Fixes invalid JSX in LiveTracker.js like:
     value={curUp != null ? ${(curUp*100).toFixed(1)}c : "---"}
   -> value={curUp != null ? (curUp*100).toFixed(1) + "c" : "---"}
#>

param(
  [string]$RepoRoot = (Get-Location).Path,
  [switch]$DryRun
)

$target = Join-Path $RepoRoot "src\components\LiveTracker.js"

if (-not (Test-Path $target)) {
  Write-Error "Cannot find: $target`nRun from repo root or pass -RepoRoot <path>."
  exit 1
}

$content  = Get-Content -Path $target -Raw -Encoding UTF8
$original = $content

# UP price StatCard value fix
$patternUp = 'value=\{\s*curUp\s*!=\s*null\s*\?\s*\$\{\s*\(\s*curUp\s*\*\s*100\s*\)\s*\.toFixed\(\s*1\s*\)\s*\}\s*c\s*:\s*("|\x27)---\1\s*\}'
$replaceUp = 'value={curUp != null ? (curUp*100).toFixed(1) + "c" : "---"}'
$content = [regex]::Replace($content, $patternUp, $replaceUp)

# DOWN price StatCard value fix
$patternDown = 'value=\{\s*curDown\s*!=\s*null\s*\?\s*\$\{\s*\(\s*curDown\s*\*\s*100\s*\)\s*\.toFixed\(\s*1\s*\)\s*\}\s*c\s*:\s*("|\x27)---\1\s*\}'
$replaceDown = 'value={curDown != null ? (curDown*100).toFixed(1) + "c" : "---"}'
$content = [regex]::Replace($content, $patternDown, $replaceDown)

if ($content -eq $original) {
  Write-Host "No changes made (pattern not found or already fixed)."
  exit 0
}

if ($DryRun) {
  Write-Host "DRY RUN: Would patch $target"
  exit 0
}

$backup = "$target.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -Path $target -Destination $backup -Force
Set-Content -Path $target -Value $content -Encoding UTF8 -NoNewline

Write-Host "Patched: $target"
Write-Host "Backup : $backup"
