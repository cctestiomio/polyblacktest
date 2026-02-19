<# patch-mojibake-ui.ps1
   Fixes common mojibake sequences like:
   â€œ â€ â€“ â‰ˆ Â¢ Â· â— â—‹ â–² â–¼
   across the tracker + backtest pages/components.

   Usage:
     .\patch-mojibake-ui.ps1
     .\patch-mojibake-ui.ps1 -DryRun
#>

param(
  [string]$RepoRoot = (Get-Location).Path,
  [switch]$DryRun
)

$paths = @(
  "src\components\LiveTracker.js",
  "src\components\BacktestEngine.js",
  "src\app\backtest\page.js",
  "src\app\page.js"
) | ForEach-Object { Join-Path $RepoRoot $_ }

# From -> To (use mostly ASCII-safe replacements; keep a few symbols users expect)
$repl = [ordered]@{
  # Quotes / apostrophes
  "â€œ" = '"'
  "â€" = '"'
  "â€˜" = "'"
  "â€™" = "'"

  # Dashes / ellipsis / approx
  "â€“" = "-"
  "â€”" = "-"
  "â€¦" = "..."
  "â‰ˆ" = "~="

  # NBSP artifacts
  "Â "  = " "   # non-breaking space shown as Â 

  # Bullets / middot artifacts
  "Â·"  = "·"   # if this still looks weird for you, change to " - "

  # Cents artifacts
  "Â¢"  = "¢"   # if this still looks weird for you, change to "c"

  # Icons in LiveTracker strings
  "â—" = "●"
  "â—‹" = "○"
  "â–²" = "▲"
  "â–¼" = "▼"

  # Common check/cross mojibake (in case it appears)
  "âœ“" = "✓"
  "âœ—" = "✗"
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$changedAny = $false

foreach ($p in $paths) {
  if (-not (Test-Path $p)) { continue }

  $content  = Get-Content -Path $p -Raw -Encoding UTF8
  $original = $content

  foreach ($k in $repl.Keys) {
    $content = $content.Replace($k, $repl[$k])
  }

  if ($content -ne $original) {
    $changedAny = $true
    if ($DryRun) {
      Write-Host "DRY RUN: Would patch $p"
      continue
    }

    $backup = "$p.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -Path $p -Destination $backup -Force
    Write-Utf8NoBom -Path $p -Text $content

    Write-Host "Patched: $p"
    Write-Host "Backup : $backup"
  }
}

if (-not $changedAny) {
  Write-Host "No mojibake patterns found in target files."
}
