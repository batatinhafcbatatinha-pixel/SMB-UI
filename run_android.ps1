<#
.SYNOPSIS
    Inicia o Flutter no Emulador Android com gravação contínua e limpeza de logs em Markdown.
.DESCRIPTION
    Executa o script tool/run_with_md_logs.dart que limpa o arquivo flutter_logs.md
    e grava em tempo real todas as saídas do Flutter no formato Markdown.
.EXAMPLE
    .\run_android.ps1
    .\run_android.ps1 --profile
    .\run_android.ps1 -d emulator-5554
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArgs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "🚀 Iniciando Flutter Android Runner com Logs Markdown..." -ForegroundColor Cyan

dart run tool/run_with_md_logs.dart $FlutterArgs
