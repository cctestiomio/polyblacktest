<# patch-livetracker-classname.ps1
   Fixes broken JSX like:
     <span className={ ext-xs font-semibold }>
   into:
     <span className="text-xs font-semibold">
   (also fixes "ext-" -> "text-" inside those unquoted class lists)
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

# Replace className={ <tailwind classes> } (unquoted) -> className="<tailwind classes>"
# Safety rules:
# - must contain at least 2 tokens (space)
# - must contain at least one hyphen (tailwind-ish)
# - must NOT already contain quotes/backticks/$ (avoid touching real JS expressions)
$pattern = 'className\s*=\s*\{\s*([A-Za-z0-9:\/\.\-\s]+)\s*\}'

$content = [regex]::Replace($content, $pattern, {
  param($m)
  $cls = $m.Groups[1].Value.Trim()

  if ($cls -match '["''`$]') { return $m.Value }
  if ($cls -notmatch '\s')   { return $m.Value }
  if ($cls -notmatch '-')    { return $m.Value }

  # Fix common typo: ext-xs -> text-xs, ext-sm -> text-sm, etc.
  $cls2 = ($cls -replace '\bext-', 'text-')

  return 'className="' + $cls2 + '"'
})

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
