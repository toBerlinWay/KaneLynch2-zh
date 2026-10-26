@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\kl2fix.ps1" install %*
pause
