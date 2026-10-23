#Requires -Version 5.1
# @label C++
# @protocol 2
param([Parameter(Position=0)][string]$Name=$env:ENVLAUNCHER_NAME, [string]$Root=$env:ENVLAUNCHER_ROOT, [switch]$Check)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    . (Join-Path $PSScriptRoot 'scaffold-common.ps1')
    New-EnvironmentProject -Language cpp -Name $Name -Root $Root -Check:$Check
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
