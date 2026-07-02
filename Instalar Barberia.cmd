@echo off
setlocal
title Instalador Capitan Gold
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar Barberia.ps1" %*
if errorlevel 1 pause
