@echo off
rem Builds the compiler from its AL sources (src/main.al) with itself, on Windows.
rem
rem   build.bat            seed compiler -> stage 1 -> stage 2 -> stage 3; stages 2 and 3 must be
rem                        byte-identical (the compiler reproduces itself); installs build\alc.exe,
rem                        and build\alc: the same compiler for Linux (built by stage 2); then
rem                        builds the test runner tests\run.al with it: build\altest.exe and
rem                        build\altest
rem   build.bat --quick    seed compiler -> build\alc.exe only (no self-check, no build\alc), and
rem                        build\altest.exe
rem   build.bat --reseed   after a full build, also replaces the seeds with the new compilers
rem   build.bat --runner   only builds the test runner build\altest.exe with build\alc.exe
rem                        (tests\run.bat does this before every run)
rem
rem A test run in progress keeps build\altest.exe and build\alc.exe open, and Windows writes no
rem file of a running program. So each is built under another name and installed: one whose
rem bytes did not change (unchanged sources) is left as it is; a changed one replaces it, and a
rem running one is renamed away first (Windows allows that), as build\NAME.old*.exe, which a
rem later build removes once nothing runs it.
rem The seed is bootstrap\alc.exe, a committed build of an earlier version of this same compiler
rem (override with ALC_SEED=path\to\alc.exe). No other tool takes part in building the compiler.
rem build.sh is the same script for Linux; both produce byte-identical compilers.
setlocal
cd /d "%~dp0"
set "SEED=%ALC_SEED%"
if "%SEED%"=="" set "SEED=bootstrap\alc.exe"
set "MODE="

:args
if "%~1"=="" goto run
if "%~1"=="--quick" (
  set "MODE=quick"
) else if "%~1"=="--reseed" (
  set "MODE=reseed"
) else if "%~1"=="--runner" (
  set "MODE=runner"
) else (
  echo usage: build.bat [--quick ^| --reseed ^| --runner]
  exit /b 2
)
shift
goto args

:run
if not exist build mkdir build
if "%MODE%"=="runner" (
  call :runner build\altest.exe
  if errorlevel 1 goto norunner
  exit /b 0
)
if not exist "%SEED%" (
  echo build: no seed compiler at %SEED%
  exit /b 1
)
rem the sources name the standard library relative to src/, so build from the repository root
"%SEED%" build --target windows src/main.al -o build\alc-stage1.exe
if errorlevel 1 (
  echo build: the seed compiler failed
  exit /b 1
)
if "%MODE%"=="quick" (
  call :install build\alc-stage1.exe build\alc.exe
  if errorlevel 1 exit /b 1
  call :runner build\altest.exe
  if errorlevel 1 goto norunner
  echo build: build\alc.exe ^(quick, not self-checked^)
  exit /b 0
)
build\alc-stage1.exe build --target windows src/main.al -o build\alc-stage2.exe
if errorlevel 1 (
  echo build: stage 1 failed to compile the compiler
  exit /b 1
)
build\alc-stage2.exe build --target windows src/main.al -o build\alc-stage3.exe
if errorlevel 1 (
  echo build: stage 2 failed to compile the compiler
  exit /b 1
)
rem the Linux compiler, from the same stage
build\alc-stage2.exe build --target linux src/main.al -o build\alc.new
if errorlevel 1 (
  echo build: stage 2 failed to compile the compiler for Linux
  exit /b 1
)
rem fc /b: 0 = identical, 1 = different, 2 = could not compare (Wine's fc does not support /b)
set "SAME=checked"
fc /b build\alc-stage2.exe build\alc-stage3.exe >nul
if errorlevel 2 (
  set "SAME=not compared"
  echo build: warning: fc could not compare stage 2 and stage 3
) else if errorlevel 1 (
  echo build: FAIL: stage 2 and stage 3 differ ^(the compiler does not reproduce itself^)
  exit /b 1
)
call :install build\alc-stage2.exe build\alc.exe
if errorlevel 1 exit /b 1
call :install build\alc.new build\alc
if errorlevel 1 exit /b 1
del build\alc-stage1.exe build\alc-stage3.exe
rem the test runner (tests\run.bat starts it), built by the new compiler
call :runner build\altest.exe
if errorlevel 1 goto norunner
call :runner build\altest --target linux
if errorlevel 1 goto norunner
if "%SAME%"=="checked" (
  echo build: build\alc.exe, self-compiled, stages 2 and 3 identical; build\alc ^(Linux^)
) else (
  echo build: build\alc.exe, self-compiled ^(stages 2 and 3 not compared^); build\alc ^(Linux^)
)
if "%MODE%"=="reseed" (
  if not "%SAME%"=="checked" (
    echo build: FAIL: refusing to --reseed when stage 2 and stage 3 were not compared
    exit /b 1
  )
  if not exist bootstrap mkdir bootstrap
  copy /y build\alc.exe bootstrap\alc.exe >nul
  copy /y build\alc bootstrap\alc >nul
  echo build: bootstrap\alc.exe and bootstrap\alc updated
)
exit /b 0

:norunner
echo build: FAIL: build\alc.exe does not compile the test runner tests\run.al
exit /b 1

rem the test runner %1 (build\altest.exe, build\altest), built by build\alc.exe with the options
rem %2 %3 and installed; errorlevel 1 if it cannot be built or installed
:runner
build\alc.exe build %2 %3 tests/run.al -o "%~dpn1.new%~x1"
if errorlevel 1 exit /b 1
call :install "%~dpn1.new%~x1" "%~1"
exit /b %errorlevel%

rem moves the new file %1 to %2 as described at the top (the same bytes: %1 is removed and %2
rem stays as it is); errorlevel 1 if %2 cannot be replaced
:install
del "%~dpn2.old*%~x2" >nul 2>&1
fc /b "%~1" "%~2" >nul 2>&1
if errorlevel 1 goto install_new
del "%~1"
exit /b 0
:install_new
move /y "%~1" "%~2" >nul 2>&1
if not errorlevel 1 exit /b 0
move /y "%~2" "%~dpn2.old%RANDOM%%~x2" >nul 2>&1
move /y "%~1" "%~2" >nul
if errorlevel 1 (
  echo build: FAIL: cannot replace %~2 ^(the new file is %~1^)
  exit /b 1
)
exit /b 0
