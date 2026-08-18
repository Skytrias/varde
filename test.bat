@echo off
setlocal

where odin >nul 2>nul
if errorlevel 1 (
  echo Odin compiler not found on PATH.
  exit /b 2
)

odin test .
if errorlevel 1 exit /b %errorlevel%

odin test src\doc_format
if errorlevel 1 exit /b %errorlevel%

odin test src\extractor
if errorlevel 1 exit /b %errorlevel%

echo All Varde tests passed.
