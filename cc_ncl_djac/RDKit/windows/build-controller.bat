@echo off
setlocal
set "RDKIT_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%RDKIT_CSC%" set "RDKIT_CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%RDKIT_CSC%" (
    echo The .NET Framework C# compiler is unavailable. Use the supplied SessionControl.exe.
    pause
    exit /b 1
)
"%RDKIT_CSC%" /nologo /target:winexe /platform:anycpu /optimize+ /warn:4 /win32manifest:"%~dp0SessionControl.manifest" /reference:System.Management.dll /reference:System.Windows.Forms.dll /reference:System.Xml.dll /out:"%~dp0SessionControl.exe" "%~dp0SessionControl.cs" "%~dp0SessionCleanup.cs"
if errorlevel 1 (
    echo Build failed. Check the errors above and any machine application restrictions.
    pause
    exit /b 1
)
echo SessionControl.exe rebuilt. No administrator permissions were requested.
pause
