@echo off
setlocal
cd /d "%~dp0"
title Configurar ngrok - Capitan Gold

if not exist "tools\start-barberia.ps1" (
  echo No se encontro tools\start-barberia.ps1
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start-barberia.ps1" -ConfigureNgrok -NoPause
echo.
pause
