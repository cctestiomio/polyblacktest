@echo off
setlocal

set "REPO=C:\Users\Sithu\Desktop\polymarket-btc-backtest"
cd /d "%REPO%" || exit /b 1

powershell -NoProfile -ExecutionPolicy Bypass -File ".\a.ps1" || exit /b 1

git add -A || exit /b 1

git diff --cached --quiet
if %errorlevel%==0 (
  echo Nothing to commit.
  git push
  exit /b 0
)

git commit -m "update" || exit /b 1
git push || exit /b 1

echo Done.
endlocal
