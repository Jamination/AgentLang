@echo off
rem Conformance test runner on Windows. The runner itself is the AL program tests\run.al (its
rem top describes the tests, the options and the targets); this script builds it with
rem build\alc.exe as build\altest.exe and starts it in the repository root.
rem Usage: tests\run.bat [-j N] [-v] [--target windows|linux] [path\to\alc.exe] [filter]
rem One word alone is the filter unless it names a file: tests\run.bat -j 4 shaderc. The
rem arguments go to the runner unchanged.
rem On Linux: tests/run.sh.
setlocal
cd /d "%~dp0.."
if not exist build\alc.exe (
  echo tests\run.bat: no build\alc.exe: run build.bat first
  exit /b 2
)
build\alc.exe build tests/run.al -o build\altest.exe
if errorlevel 1 (
  echo tests\run.bat: build\alc.exe cannot build the test runner tests\run.al
  exit /b 2
)
build\altest.exe %*
exit /b %errorlevel%
