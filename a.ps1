param(
  [string]$RepoRoot = "",
  [switch]$DryRun
)

function Find-RepoRoot([string]$StartDir) {
  $dir = (Resolve-Path $StartDir).Path
  while ($true) {
    if (Test-Path (Join-Path $dir "package.json")) { return $dir }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir -or [string]::IsNullOrWhiteSpace($parent)) { return $null }
    $dir = $parent
  }
}

function Backup-File([string]$Path) {
  if ($DryRun) { return $null }
  $bak = "$Path.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item -Path $Path -Destination $bak -Force
  return $bak
}

function Read-TextUtf8([string]$Path) {
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextUtf8NoBom([string]$Path, [string]$Text) {
  if ($DryRun) { Write-Host "DRY RUN: Would write $Path"; return }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# Resolve repo root
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json)." }
Write-Host "RepoRoot: $RepoRoot"

$btPage = Join-Path $RepoRoot "src/app/backtest/page.js"
if (-not (Test-Path $btPage)) {
  throw "src/app/backtest/page.js not found"
}

$text = Read-TextUtf8 $btPage
$orig = $text

# Ensure React import has useEffect
$text = [regex]::Replace(
  $text,
  'import\s*\{\s*([^}]*)\}\s*from\s*["'']react["''];',
  {
    param($m)
    $inside = $m.Groups[1].Value
    if ($inside -match '(^|,)\s*useEffect\s*(,|$)') { return $m.Value }
    return 'import { ' + $inside.Trim() + ', useEffect } from "react";'
  }
)

# Inject combined auto-click effect if not already present
if ($text -notmatch 'PM_AUTOLOAD_BROWSER_AND_RUN') {
  $effect = @'
  // PM_AUTOLOAD_BROWSER_AND_RUN: auto-click "Load from This Browser" then "Run Backtest"
  useEffect(() => {
    const t1 = setTimeout(() => {
      try {
        const loadBtn = document.querySelector('button[data-auto-load="browser"]');
        if (loadBtn) loadBtn.click();
      } catch {}
    }, 3000);

    const t2 = setTimeout(() => {
      try {
        const runBtn = Array.from(document.querySelectorAll("button"))
          .find(b => /Run Backtest/i.test(b.textContent || ""));
        if (runBtn) runBtn.click();
      } catch {}
    }, 4500);

    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, []);

'@

  $text = [regex]::Replace(
    $text,
    '(export\s+default\s+function\s+[A-Za-z0-9_]+\s*\([^)]*\)\s*\{\s*)',
    ('$1' + $effect),
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
}

if ($text -ne $orig) {
  $bak = Backup-File $btPage
  Write-Host "Patched backtest/page.js (auto-click load + run)"
  Write-Host "Backup: $bak"
  Write-TextUtf8NoBom $btPage $text
} else {
  Write-Host "No changes applied (pattern not found or already patched)."
}

Write-Host "Done."
