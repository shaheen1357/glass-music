@echo off
REM Remove the drawer helper service. RUN AS ADMINISTRATOR from this folder.
setlocal
cd /d "%~dp0"
set SVC=CoccinelleDrawer

if not exist "%~dp0nssm.exe" (
    echo nssm.exe not found in this folder.
    exit /b 1
)
"%~dp0nssm.exe" stop %SVC%
"%~dp0nssm.exe" remove %SVC% confirm
echo Service "%SVC%" removed.
