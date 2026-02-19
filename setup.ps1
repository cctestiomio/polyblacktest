<# patch-livetracker-chartformat.ps1
   Fixes invalid ${v}s / ${v}c / ${v}s elapsed usages in JSX formatters in:
   src/components/LiveTracker.js
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

# XAxis / YAxis tickFormatter: v => ${v}s  /  v => ${v}c
$content = [regex]::Replace(
  $content,
  'tickFormatter=\{\s*v\s*=>\s*\$\{\s*v\s*\}\s*s\s*\}',
  'tickFormatter={v => `${v}s`}'
)
$content = [regex]::Replace(
  $content,
  'tickFormatter=\{\s*v\s*=>\s*\$\{\s*v\s*\}\s*c\s*\}',
  'tickFormatter={v => `${v}c`}'
)

# Tooltip formatter: (v, n) => [v != null ? ${v}c : "---", n]
$content = [regex]::Replace(
  $content,
  'formatter=\{\s*\(\s*v\s*,\s*n\s*\)\s*=>\s*\[\s*v\s*!=\s*null\s*\?\s*\$\{\s*v\s*\}\s*c\s*:\s*("|\x27)---\1\s*,\s*n\s*\]\s*\}',
  'formatter={(v, n) => [v != null ? `${v}c` : "---", n]}'
)

# Tooltip labelFormatter: v => ${v}s elapsed
$content = [regex]::Replace(
  $content,
  'labelFormatter=\{\s*v\s*=>\s*\$\{\s*v\s*\}\s*s\s*elapsed\s*\}',
  'labelFormatter={v => `${v}s elapsed`}'
)

if ($content -eq $original) {
  Write-Host "No changes made (patterns not found or already fixed)."
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
