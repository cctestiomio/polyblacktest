@echo off
setlocal

cd /d "C:\Users\Sithu\Documents\fasscript\polyblacktest" || (
  echo Failed to cd to repo folder
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File ".\a.ps1" && git add -A && git commit -m "update" && git push

echo.
echo ExitCode=%errorlevel%
pause
endlocal
