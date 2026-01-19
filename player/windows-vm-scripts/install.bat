@echo off
echo ========================================================
echo Mydia Player - Windows Environment Setup
echo ========================================================
echo.
echo Installing Chocolatey...
powershell -NoProfile -InputFormat None -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
SET "PATH=%PATH%;%ALLUSERSPROFILE%\chocolatey\bin"

echo.
echo Installing Git...
choco install git -y --params "/GitAndUnixToolsOnPath"

echo.
echo Installing Flutter...
choco install flutter -y

echo.
echo Installing Visual Studio Build Tools (C++)...
echo This may take a while...
choco install visualstudio2022buildtools -y --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart"

echo.
echo Environment setup complete!
echo You can now access the source code at C:\Users\Public\Desktop\Shared
echo.
echo To build the app:
echo 1. Open PowerShell
echo 2. cd C:\Users\Public\Desktop\Shared
echo 3. flutter pub get
echo 4. flutter build windows
pause
