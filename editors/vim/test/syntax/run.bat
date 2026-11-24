@echo off
rem Runs the syntax tests (run.vim) under each given Vim or Neovim executable
rem (default: vim and nvim from PATH). A name containing "nvim" is run as Neovim.
rem   editors\vim\test\syntax\run.bat
rem   editors\vim\test\syntax\run.bat "C:\Program Files\Vim\vim92\vim.exe" nvim
rem Exit status: 0 when every run passed.
setlocal enableextensions
set "SCRIPT=%~dp0run.vim"
set STATUS=0
if "%~1"=="" (
    call :run vim
    call :run nvim
) else (
    for %%E in (%*) do call :run %%E
)
exit /b %STATUS%

:run
set "EXE=%~1"
set "LOG=%TEMP%\al_syntax_test_%RANDOM%%RANDOM%.txt"
echo == %EXE%
echo %~n1 | findstr /i "nvim" >nul
if errorlevel 1 (
    "%EXE%" -es -N -u NONE -i NONE --cmd "let g:al_test_log='%LOG%'" -S "%SCRIPT%"
) else (
    "%EXE%" --headless -u NONE -i NONE --cmd "let g:al_test_log='%LOG%'" -S "%SCRIPT%"
)
if errorlevel 1 set STATUS=1
if exist "%LOG%" (
    type "%LOG%"
    del "%LOG%"
) else (
    echo no results ^(did %EXE% start?^)
    set STATUS=1
)
exit /b 0
