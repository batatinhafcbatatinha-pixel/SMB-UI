@echo off
REM ==============================================================================
REM Executa o Flutter no Android gravando logs limpos em flutter_logs.md
REM ==============================================================================

cd /d "%~dp0"
dart run tool/run_with_md_logs.dart %*
pause
