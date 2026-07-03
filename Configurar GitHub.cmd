@echo off
setlocal
cd /d "%~dp0"
title Configurar respaldos GitHub - Capitan Gold
chcp 65001 >nul

if not exist "tools\configure-github.ps1" (
  echo No se encontro tools\configure-github.ps1
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\configure-github.ps1" -AppRoot "%~dp0"
set "RESULTADO=%ERRORLEVEL%"
echo.
pause
exit /b %RESULTADO%
