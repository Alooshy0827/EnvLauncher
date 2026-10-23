#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'scaffold-common.ps1')

function Get-Scaffolds {
    $directories=@((Join-Path $env:USERPROFILE 'bin')) + @($env:PATH -split [IO.Path]::PathSeparator) + @($PSScriptRoot)
    if ($env:ENVLAUNCHER_SCRIPTS) { $directories=@($env:ENVLAUNCHER_SCRIPTS) + $directories }
    $found=@{}
    foreach ($directory in $directories) {
        if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter 'new-*.ps1' -File -ErrorAction SilentlyContinue)) {
            $label=$file.BaseName.Substring(4); $protocol=1
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -TotalCount 20 -Encoding UTF8)) {
                if ($line -match '^\s*#\s*@label\s+(.+?)\s*$') { $label=$Matches[1] }
                if ($line -match '^\s*#\s*@protocol\s+2\s*$') { $protocol=2 }
            }
            if ($found.ContainsKey($file.BaseName) -and $found[$file.BaseName].Protocol -ge $protocol) { continue }
            $found[$file.BaseName]=[pscustomobject]@{Id=$file.BaseName;Label=$label;Path=$file.FullName;Protocol=$protocol}
        }
    }
    return @($found.Values | Sort-Object Label)
}
function Get-VSCodeCommand {
    # Resolve the native executable/CLI pair instead of passing user paths through code.cmd.
    $candidates=New-Object Collections.Generic.List[string]
    $command=Get-Command code -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $parent=Split-Path -Parent $command.Source
        if ([IO.Path]::GetExtension($command.Source) -in @('.cmd','.bat')) { $parent=Split-Path -Parent $parent }
        $candidates.Add($parent)
    }
    foreach ($root in @($env:LOCALAPPDATA,$env:ProgramFiles,${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        foreach ($relative in @('Programs\Microsoft VS Code','Microsoft VS Code')) { $candidates.Add((Join-Path $root $relative)) }
    }
    foreach ($root in $candidates) {
        $exe=Join-Path $root 'Code.exe'
        $cli=Join-Path $root 'resources\app\out\cli.js'
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath $cli -PathType Leaf)) { return $exe }
    }
    return $null
}

function Test-CompletedProject {
    param([string]$Path, [int]$ExitCode, [int]$Protocol=2)
    if ($ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if ($Protocol -lt 2) { return $true }
    try {
        $manifest=Get-Content -LiteralPath (Join-Path $Path '.envlauncher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1 -or @($manifest.requiredFiles).Count -eq 0) { return $false }
        $prefix=[IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        foreach ($relative in $manifest.requiredFiles) {
            $file=[IO.Path]::GetFullPath((Join-Path $Path $relative))
            if (-not $file.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Start-LauncherProcess {
    param([string]$Script, [string[]]$Arguments=@(), [hashtable]$Environment=@{})
    $powershell=Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) { $powershell=Join-Path $PSHOME 'pwsh' }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$powershell
    $nativeArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script)+$Arguments
    $info.Arguments=(($nativeArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $info.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key]=$Environment[$key] }
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try { [void]$process.Start() } catch { $process.Dispose(); throw }
    return [pscustomobject]@{Process=$process;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}
}
