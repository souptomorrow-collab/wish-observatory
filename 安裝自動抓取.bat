@echo off
schtasks /Create /F /TN "WishObservatoryFetch" /SC MINUTE /MO 30 /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%~dp0get-wishes.ps1\" -Silent"
if %errorlevel%==0 (
  echo OK: auto-fetch installed, runs every 30 minutes in background.
) else (
  echo FAILED: could not create scheduled task.
)
pause
