#Requires -Version 5.1
param([string]$Code, [string]$Path)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    . (Join-Path $PSScriptRoot 'scaffold-common.ps1')
    $cli=Join-Path (Split-Path -Parent $Code) 'resources\app\out\cli.js'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'VS Code CLI 文件不存在，请修复 VS Code 安装。' }
    # This is the same Node entry point used by code.cmd, with no cmd.exe expansion.
    $result=Invoke-CapturedProcess -Exe $Code -Arguments @($cli,'-n','--',$Path) -Environment @{ELECTRON_RUN_AS_NODE='1'} -TimeoutSeconds 45
    [Console]::Out.Write($result.Output)
    [Console]::Error.Write($result.Error)
    exit $result.ExitCode
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
