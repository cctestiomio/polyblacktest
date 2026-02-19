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

# --- Find LiveTracker.js ---
$files = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "LiveTracker.js" -ErrorAction SilentlyContinue
if (-not $files -or $files.Count -eq 0) { throw "No LiveTracker.js found." }

Write-Host "LiveTracker.js files found:"
$files | ForEach-Object { Write-Host " - $($_.FullName)" }

foreach ($f in $files) {
  $t = Read-TextUtf8 $f.FullName
  $orig = $t

  # 1) Add refs: resTimeoutRef + clockTickFnRef
  if ($t -notmatch 'resTimeoutRef') {
    $t = [regex]::Replace(
      $t,
      'const\s+tickRef\s*=\s*useRef\(null\);\s*',
      '$0const resTimeoutRef = useRef(null);' + "`n" + 'const clockTickFnRef = useRef(null);' + "`n",
      "Singleline"
    )
  }

  # 2) Clear resolution timeout in stopAll
  if ($t -match 'const\s+stopAll\s*=\s*useCallback' -and $t -notmatch 'clearTimeout\(resTimeoutRef\.current\)') {
    $t = [regex]::Replace(
      $t,
      'clearInterval\(tickRef\.current\);\s*clearInterval\(cdRef\.current\);\s*',
      'clearInterval(tickRef.current);' + "`n" + '    clearInterval(cdRef.current);' + "`n" +
      '    clearTimeout(resTimeoutRef.current);' + "`n" +
      '    resTimeoutRef.current = null;' + "`n",
      "Singleline"
    )
  }

  # 3) In WS onmessage: after updating prices, if rem<=0 trigger clockTick via ref
  if ($t -notmatch 'clockTickFnRef\.current\(\)') {
    $t = [regex]::Replace(
      $t,
      'setCurDown\(pricesRef\.current\.down\);\s*',
      '$0' +
      '          const st = slugTsRef.current;' + "`n" +
      '          if (st != null && getSecondsRemaining(st) <= 0 && clockTickFnRef.current) {' + "`n" +
      '            clockTickFnRef.current();' + "`n" +
      '          }' + "`n",
      "Singleline"
    )
  }

  # 4) After clockTick useCallback: keep clockTickFnRef updated, and add scheduleResolution()
  if ($t -notmatch 'scheduleResolution') {
    $t = [regex]::Replace(
      $t,
      '\},\s*\[doSave,\s*openWs\]\);\s*',
      '$0' + "`n" +
      '  useEffect(() => { clockTickFnRef.current = clockTick; }, [clockTick]);' + "`n`n" +
      '  const scheduleResolution = useCallback((slugTs) => {' + "`n" +
      '    clearTimeout(resTimeoutRef.current);' + "`n" +
      '    resTimeoutRef.current = null;' + "`n" +
      '    if (slugTs == null) return;' + "`n" +
      '    const ms = (getResolutionTs(slugTs) * 1000) - Date.now();' + "`n" +
      '    const wait = Math.max(0, ms + 25);' + "`n" +
      '    resTimeoutRef.current = setTimeout(() => {' + "`n" +
      '      if (slugTsRef.current !== slugTs) return;' + "`n" +
      '      if (savedRef.current) return;' + "`n" +
      '      if (clockTickFnRef.current) clockTickFnRef.current();' + "`n" +
      '    }, wait);' + "`n" +
      '  }, []);' + "`n`n",
      "Singleline"
    )
  }

  # 5) In startTracking: schedule resolution timeout right after slugTsRef is set
  if ($t -match 'slugTsRef\.current\s*=\s*slugTs;' -and $t -notmatch 'scheduleResolution\(slugTs\)') {
    $t = [regex]::Replace(
      $t,
      'slugTsRef\.current\s*=\s*slugTs;\s*',
      '$0' + "`n" + '    scheduleResolution(slugTs);' + "`n",
      "Singleline"
    )
  }

  # 6) Add scheduleResolution to startTracking deps (best effort)
  if ($t -match '\}\s*,\s*\[stopAll,\s*openWs,\s*clockTick\]\s*\)\s*;' -and $t -notmatch 'openWs,\s*clockTick,\s*scheduleResolution') {
    $t = [regex]::Replace(
      $t,
      '\}\s*,\s*\[stopAll,\s*openWs,\s*clockTick\]\s*\)\s*;',
      '}, [stopAll, openWs, clockTick, scheduleResolution]);',
      "Singleline"
    )
  }

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

Write-Host "Done. Restart dev server (Ctrl+C then npm run dev). If still stale, delete .next\ and restart."
