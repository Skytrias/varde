@echo off
setlocal

where odin >nul 2>nul
if errorlevel 1 (
  echo Odin compiler not found on PATH.
  exit /b 2
)

if not exist dist mkdir dist
odin build cli -o:speed -out:dist\varde.exe
if errorlevel 1 exit /b %errorlevel%

echo Built dist\varde.exe
