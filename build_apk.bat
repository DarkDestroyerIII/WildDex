@echo off
setlocal

cd /d "%~dp0"

set "JAVA_HOME=C:\Program Files\Java\jdk-17"
set "PATH=%JAVA_HOME%\bin;%PATH%"

echo.
echo Building WildDex Android APK...
echo Project: %CD%
echo.

call flutter clean
if errorlevel 1 goto fail

call flutter pub get
if errorlevel 1 goto fail

call flutter build apk --debug
if errorlevel 1 goto fail

set "STAMP=%DATE:~-4%%DATE:~4,2%%DATE:~7,2%-%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%"
set "STAMP=%STAMP: =0%"
set "COPY_TARGET=%~dp0..\WildDex-%STAMP%-debug.apk"

copy /Y "build\app\outputs\flutter-apk\app-debug.apk" "%COPY_TARGET%" >nul
if errorlevel 1 goto fail

copy /Y "build\app\outputs\flutter-apk\app-debug.apk" "%~dp0..\COPY_THIS_TO_PHONE_WildDex.apk" >nul
if errorlevel 1 echo Could not refresh COPY_THIS_TO_PHONE_WildDex.apk because Windows has it open.

echo.
echo Build complete.
echo APK:
echo %CD%\build\app\outputs\flutter-apk\app-debug.apk
echo.
echo Easy copy:
echo %COPY_TARGET%
echo %~dp0..\COPY_THIS_TO_PHONE_WildDex.apk
echo.
pause
exit /b 0

:fail
echo.
echo Build failed. Check the error above.
echo.
pause
exit /b 1
