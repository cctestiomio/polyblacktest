param(
  [string]$RepoRoot = "",
  [ValidateSet("6xl","7xl")]
  [string]$Width = "6xl",
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

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json). Run from repo root." }
Write-Host "RepoRoot: $RepoRoot"

# Find the page.js that contains STORAGE_KEY = "pm_sessions"
$pageFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "page.js" -ErrorAction SilentlyContinue |
  Where-Object {
    try {
      (Read-TextUtf8 $_.FullName) -match 'STORAGE_KEY\s*=\s*"pm_sessions"'
    } catch { $false }
  }

if (-not $pageFiles -or $pageFiles.Count -eq 0) { throw "Could not find the Live/tracker page.js (pm_sessions) in repo." }

foreach ($f in $pageFiles) {
  $t = Read-TextUtf8 $f.FullName
  $orig = $t

  $from = "max-w-5xl"
  $to = "max-w-$Width"

  if ($t -notmatch $from) {
    Write-Host "WARNING: $($f.FullName) does not contain '$from' (nothing to change)."
    continue
  }

  $t = $t.Replace($from, $to)

  if ($t -ne $orig) {
    $bak = Backup-File $f.FullName
    Write-Host "Patched: $($f.FullName)"
    if (-not $DryRun) {
      Write-Host "Backup : $bak"
      Write-TextUtf8NoBom $f.FullName $t
    }
  } else {
    Write-Host "No changes needed: $($f.FullName)"
  }
}

Write-Host "Done. Restart dev server if needed."
