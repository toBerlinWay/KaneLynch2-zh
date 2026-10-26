@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\kl2patch.ps1" install %*
pause
