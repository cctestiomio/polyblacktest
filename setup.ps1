<#  patch-livetracker.ps1
    Patches src/components/LiveTracker.js to fix:
    - broken fmtS() template literal
    - missing quotes in setErrorMsg(...) lines
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

# 1) Fix fmtS(s) { return ${pad(...)}:; }
$patternFmt = 'function\s+fmtS\s*\(\s*s\s*\)\s*\{\s*return\s*\$\{pad\(Math\.floor\(s\s*\/\s*60\)\)\}:\s*;\s*\}'
$replaceFmt = 'function fmtS(s) { const m = Math.floor(s / 60); const sec = Math.floor(s % 60); return `${pad(m)}:${pad(sec)}`; }'
$content = [regex]::Replace($content, $patternFmt, $replaceFmt)

# 2) Fix missing quotes in setErrorMsg(...)
$content = [regex]::Replace(
  $content,
  'setErrorMsg\(\s*Waiting for market creation:\s*\);',
  'setErrorMsg("Waiting for market creation...");'
)
$content = [regex]::Replace(
  $content,
  'setErrorMsg\(\s*Market not found:\s*\);',
  'setErrorMsg("Market not found");'
)

if ($content -eq $original) {
  Write-Host "No changes needed (patterns not found or already patched)."
  exit 0
}

if ($DryRun) {
  Write-Host "DRY RUN: Would patch $target"
  exit 0
}

$backup = "$target.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -Path $target -Destination $backup -Force

# Write back (keeps file as a single string; doesn't add an extra newline at EOF)
Set-Content -Path $target -Value $content -Encoding UTF8 -NoNewline

Write-Host "Patched: $target"
Write-Host "Backup : $backup"
