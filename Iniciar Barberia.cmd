@echo off
setlocal
cd /d "%~dp0"
title Barberia Control

if not exist "tools\start-barberia.ps1" (
  echo No se encontro tools\start-barberia.ps1
  echo Verifica que este archivo este en la carpeta de la demo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start-barberia.ps1" %*
