@echo off
setlocal

set "SCRIPT=%~dp0kompresor_PRO.ps1"

if not exist "%SCRIPT%" (
  echo Nie znaleziono: "%SCRIPT%"
  pause
  endlocal
  exit /b 1
)

REM uruchamia PS z ukrytą konsolą; GUI (WinForms) nadal powinno się pokazać
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"

endlocal
exit /b 0