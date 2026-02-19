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

# --- Resolve repo root ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json). Run from repo root." }
Write-Host "RepoRoot: $RepoRoot"

# --------------------------------------------------
# 1) Clean PowerShell garbage out of backtest/page.js
# --------------------------------------------------
$btPage = Join-Path $RepoRoot "src/app/backtest/page.js"
if (Test-Path $btPage) {
  $text = Read-TextUtf8 $btPage
  $orig = $text

  # Remove any top-of-file PowerShell block that contains param($m) / $inside / -match
  $text = [regex]::Replace(
    $text,
    '^(?:.*param\(\$m\).*\r?\n.*\$inside\s*=\s*\$m\.Groups\[1\]\.Value.*\r?\n.*-match\s*''\(\^|\,\)\\s\*useEffect\\s\*\(,|\$\)''.*\r?\n.*return\s*''import\s*\{.*useEffect.*?;''.*\r?\n\s*)',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )

  if ($text -ne $orig) {
    $bak = Backup-File $btPage
    Write-Host "Cleaned PowerShell noise from: $btPage"
    Write-Host "Backup: $bak"
    Write-TextUtf8NoBom $btPage $text
  } else {
    Write-Host "No PowerShell noise detected in: $btPage"
  }
} else {
  Write-Host "WARNING: backtest/page.js not found at $btPage"
}

# --------------------------------------------------
# 2) Remove "Start price" column from BacktestEngine
# --------------------------------------------------
$engine = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue |
  Select-Object -First 1

if ($engine) {
  $t = Read-TextUtf8 $engine.FullName
  $orig = $t

  # Remove header cell
  $t = [regex]::Replace(
    $t,
    '<th className="text-right pr-4">Start price</th>\s*',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )

  # Remove body cell that renders avgStartPriceLabel
  $t = [regex]::Replace(
    $t,
    '<td className="text-right pr-4">\{r\.avgStartPriceLabel\}</td>\s*',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )

  if ($t -ne $orig) {
    $bak2 = Backup-File $engine.FullName
    Write-Host "Removed Start price column in: $($engine.FullName)"
    Write-Host "Backup: $bak2"
    Write-TextUtf8NoBom $engine.FullName $t
  } else {
    Write-Host "No Start price column pattern found in: $($engine.FullName)"
  }
} else {
  Write-Host "WARNING: BacktestEngine.js not found."
}

Write-Host "Done."
