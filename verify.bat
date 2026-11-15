@echo off
rem Verification on Windows: the compiler builds itself from the seed (build.bat: stages 2 and
rem 3 byte-identical), the conformance tests run on this machine (tests\run.bat: every program
rem built by build\alc.exe in three modes and run, `alc run`, `alc test`, diagnostics), and the
rem same programs are built and type-checked for Linux (tests\run.bat --target linux).
rem Prints VERIFY: PASS or VERIFY: FAIL as its last line; the exit code is 0 only for PASS.
rem
rem The full verification is verify.sh on Linux: it adds what needs clang, readelf and bash
rem (f32 results against C, static-executable checks, the command-line tests, the benchmarks
rem against clang -O2) and what is the same on every host (documentation, version).
setlocal
cd /d "%~dp0"
set "FAIL=0"
echo == build: the compiler compiles itself ==
rem (by full path: with NoDefaultCurrentDirectoryInExePath set, cmd does not look in .)
call "%~dp0build.bat"
if errorlevel 1 (
  echo FAIL: compiler did not build
  echo VERIFY: FAIL
  exit /b 1
)
echo == conformance tests (language, standard library, system, bindings) ==
call "%~dp0tests\run.bat"
if errorlevel 1 set "FAIL=1"
echo == the same programs for Linux: built and type-checked, not run ==
call "%~dp0tests\run.bat" --target linux
if errorlevel 1 set "FAIL=1"
if "%FAIL%"=="0" (
  echo VERIFY: PASS
) else (
  echo VERIFY: FAIL
)
exit /b %FAIL%
