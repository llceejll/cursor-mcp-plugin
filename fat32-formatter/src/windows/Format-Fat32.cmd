@echo off
rem Starts Format-Fat32.ps1 without changing any PowerShell settings.
rem Double-click this file. Windows will ask for administrator permission.
title FAT32 Flash Drive Formatter (offline)
set "PS1=%~dp0Format-Fat32.ps1"
if not exist "%PS1%" (
    echo Format-Fat32.ps1 was not found next to this file.
    echo.
    echo If your copy is named Format-Fat32.ps1.txt, remove the ".txt" from the end
    echo of the name, then double-click this file again.
    echo.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Pause %*
set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo The tool ended with code %RC%. Read the messages above, then press a key to close.
    pause
)
exit /b %RC%
