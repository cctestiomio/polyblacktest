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

function Replace-RegexSingleline([string]$Text, [string]$Pattern, [string]$Replacement) {
  return [regex]::Replace($Text, $Pattern, $Replacement, [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

# --- Resolve repo root ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json). Run from repo root." }
Write-Host "RepoRoot: $RepoRoot"

# ------------------------------------------------------------
# Part 1: BacktestEngine defaults
# ------------------------------------------------------------
$engineFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue
if (-not $engineFiles -or $engineFiles.Count -eq 0) {
  Write-Host "WARNING: No BacktestEngine.js found."
} else {
  foreach ($f in $engineFiles) {
    $t = Read-TextUtf8 $f.FullName
    $orig = $t

    # Default enable "Group by Delta Bucket (PriceToBeat vs current)"
    # const [useDeltaBuckets, setUseDeltaBuckets] = useState(false);
    $t = Replace-RegexSingleline $t '(const\s*\[\s*useDeltaBuckets\s*,\s*setUseDeltaBuckets\s*\]\s*=\s*useState\()\s*(true|false)\s*(\)\s*;)' '${1}true${3}'

    # Default sortBy = "pl" (Realized P/L)
    $t = Replace-RegexSingleline $t '(const\s*\[\s*sortBy\s*,\s*setSortBy\s*\]\s*=\s*useState\()\s*"[^"]*"\s*(\)\s*;)' '${1}"pl"${2}'

    # Default Top N rows = 100
    $t = Replace-RegexSingleline $t '(const\s*\[\s*topN\s*,\s*setTopN\s*\]\s*=\s*useState\()\s*\d+\s*(\)\s*;)' '${1}100${2}'

    # Default Min samples per cell = 3
    $t = Replace-RegexSingleline $t '(const\s*\[\s*minSamples\s*,\s*setMinSamples\s*\]\s*=\s*useState\()\s*\d+\s*(\)\s*;)' '${1}3${2}'

    if ($t -ne $orig) {
      $bak = Backup-File $f.FullName
      Write-Host "Patched BacktestEngine defaults: $($f.FullName)"
      if (-not $DryRun) {
        Write-Host "Backup: $bak"
        Write-TextUtf8NoBom $f.FullName $t
      }
    } else {
      Write-Host "No BacktestEngine default changes applied: $($f.FullName)"
      Write-Host "  (If your BacktestEngine uses different variable names, tell me and I will adjust patterns.)"
    }
  }
}

# ------------------------------------------------------------
# Part 2: Auto-click "Load from this Browser" on backtest page
# ------------------------------------------------------------
# Strategy:
# - Find any .js/.jsx/.ts/.tsx containing the exact button text "Load from this Browser"
# - Add data-auto-load="browser" to that <button>
# - Ensure react import includes useEffect
# - Inject a useEffect at top of default-export component to click that button after 3000ms
$codeFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Include *.js,*.jsx,*.ts,*.tsx -ErrorAction SilentlyContinue
$targets = @()

foreach ($cf in $codeFiles) {
  try {
    $txt = Read-TextUtf8 $cf.FullName
    if ($txt -like '*Load from this Browser*') {
      $targets += $cf
    }
  } catch { }
}

if ($targets.Count -eq 0) {
  Write-Host 'WARNING: Could not find any file containing text "Load from this Browser".'
  Write-Host "If the label is different, tell me the exact button text and I will update the script."
} else {
  foreach ($f in $targets) {
    $t = Read-TextUtf8 $f.FullName
    $orig = $t

    # 2a) Add data attribute to the button that has that label (idempotent)
    if ($t -notmatch 'data-auto-load\s*=\s*"browser"') {
      $t = Replace-RegexSingleline $t '(<button\b[^>]*)(>)\s*Load from this Browser' '${1} data-auto-load="browser"${2}Load from this Browser'
    }

    # 2b) Ensure React import includes useEffect (only for named-import form)
    # import { useState, useCallback } from "react";
    if ($t -match 'import\s*\{\s*[^}]*\}\s*from\s*["'']react["'']\s*;') {
      $t = Replace-RegexSingleline $t 'import\s*\{\s*([^}]*)\s*\}\s*from\s*["'']react["'']\s*;' {
        param($m)
        $inside = $m.Groups[1].Value
        if ($inside -match '(^|,)\s*useEffect\s*(,|$)') { return $m.Value }
        return 'import { ' + $inside.Trim() + ', useEffect } from "react";'
      }
    } else {
      # If there is no named import from react, we won't try to rewrite it blindly.
      # We'll still inject the hook; if build fails, you can switch to named import.
    }

    # 2c) Inject effect near top of the default export component (idempotent marker)
    if ($t -notmatch 'PM_AUTOLOAD_BROWSER_BTN') {
      $inject = @'
  // PM_AUTOLOAD_BROWSER_BTN: auto-click "Load from this Browser" after 3s
  useEffect(() => {
    try {
      if (typeof window !== "undefined") {
        if (window.__pmAutoLoadBrowserRan) return;
        window.__pmAutoLoadBrowserRan = true;
      }
    } catch {}
    const t = setTimeout(() => {
      try {
        const btn = document.querySelector('button[data-auto-load="browser"]');
        if (btn) btn.click();
      } catch {}
    }, 3000);
    return () => clearTimeout(t);
  }, []);

'@

      # Insert right after: export default function X(...) {
      $t2 = Replace-RegexSingleline $t '(export\s+default\s+function\s+[A-Za-z0-9_]*\s*\([^)]*\)\s*\{\s*)' ('$1' + $inject)
      if ($t2 -ne $t) {
        $t = $t2
      } else {
        # Fallback: insert after "return (" is too late for hooks; do nothing if we can't find the function head.
        Write-Host "WARNING: Could not inject useEffect into $($f.FullName) (default-export function signature not found)."
      }
    }

    if ($t -ne $orig) {
      $bak = Backup-File $f.FullName
      Write-Host "Patched autoload button: $($f.FullName)"
      if (-not $DryRun) {
        Write-Host "Backup: $bak"
        Write-TextUtf8NoBom $f.FullName $t
      }
    } else {
      Write-Host "No autoload changes needed: $($f.FullName)"
    }
  }
}

Write-Host "Done. Restart dev server (Ctrl+C then npm run dev). If stale, delete .next\ and restart."
ppppppppp