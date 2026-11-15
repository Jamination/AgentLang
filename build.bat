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
rem
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
) else (
  echo usage: build.bat [--quick ^| --reseed]
  exit /b 2
)
shift
goto args

:run
if not exist build mkdir build
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
  move /y build\alc-stage1.exe build\alc.exe >nul
  build\alc.exe build tests/run.al -o build\altest.exe
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
copy /y build\alc-stage2.exe build\alc.exe >nul
move /y build\alc.new build\alc >nul
del build\alc-stage1.exe build\alc-stage2.exe build\alc-stage3.exe
rem the test runner (tests\run.bat starts it), built by the new compiler
build\alc.exe build tests/run.al -o build\altest.exe
if errorlevel 1 goto norunner
build\alc.exe build --target linux tests/run.al -o build\altest
if errorlevel 1 goto norunner
if "%SAME%"=="checked" (
  echo build: build\alc.exe, self-compiled, stages 2 and 3 identical; build\alc ^(Linux^)
) else (
  echo build: build\alc.exe, self-compiled ^(stages 2 and 3 not compared^); build\alc ^(Linux^)
)
if "%MODE%"=="reseed" (
  if not exist bootstrap mkdir bootstrap
  copy /y build\alc.exe bootstrap\alc.exe >nul
  copy /y build\alc bootstrap\alc >nul
  echo build: bootstrap\alc.exe and bootstrap\alc updated
)
exit /b 0

:norunner
echo build: FAIL: build\alc.exe does not compile the test runner tests\run.al
exit /b 1
