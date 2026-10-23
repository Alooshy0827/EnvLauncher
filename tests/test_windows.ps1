#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'windows/launcher-core.ps1')
function Assert { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
$base=Join-Path ([IO.Path]::GetTempPath()) ('envlauncher-'+[guid]::NewGuid().ToString())
$root=Join-Path $base "中文 ' & 百分号% [目录]"
[void][IO.Directory]::CreateDirectory($base)
$originalWriter=${function:Write-ProjectText}
try {
    foreach ($file in Get-ChildItem (Join-Path $repo 'windows/*.ps1')) {
        $bytes=[IO.File]::ReadAllBytes($file.FullName)
        Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('Missing BOM: '+$file.Name)
        $parseErrors=$null; $tokens=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0) (($parseErrors | Out-String)+$file.Name)
    }
    . (Join-Path $repo 'windows/theme.ps1')
    Assert ((Resolve-LauncherThemeMode -AppsUseLightTheme 0) -eq 'Dark') 'Dark app preference ignored'
    Assert ((Resolve-LauncherThemeMode -AppsUseLightTheme 1) -eq 'Light') 'Light app preference ignored'
    Assert ((Resolve-LauncherThemeMode -AppsUseLightTheme $null) -eq 'Light') 'Missing preference must have a safe fallback'
    Assert ((Resolve-LauncherThemeMode -AppsUseLightTheme 0 -HighContrast $true) -eq 'HighContrast') 'High contrast must take priority'
    function Get-RelativeLuminance {
        param([string]$Hex)
        $components=@()
        foreach ($offset in @(1,3,5)) {
            $channel=[Convert]::ToInt32($Hex.Substring($offset,2),16)/255.0
            $components+=if ($channel -le 0.04045) { $channel/12.92 } else { [Math]::Pow(($channel+0.055)/1.055,2.4) }
        }
        return $components[0]*0.2126+$components[1]*0.7152+$components[2]*0.0722
    }
    foreach ($mode in @('Light','Dark')) {
        $palette=Get-LauncherThemePalette $mode
        $background=Get-RelativeLuminance $palette.Background
        $secondary=Get-RelativeLuminance $palette.Secondary
        $contrast=([Math]::Max($background,$secondary)+0.05)/([Math]::Min($background,$secondary)+0.05)
        Assert ($contrast -ge 4.5) ('Secondary text is hard to read in '+$mode)
        Assert ($palette.Secondary -match '^#([0-9a-f]{2})\1\1$') 'Footer must use a neutral gray'
    }
    Write-Output 'PASS system appearance selection, high contrast priority and readable neutral footer colors'
    foreach ($name in @('', '.', '..', '../escape','back\slash','CON','nul.txt','LPT1.c','has"quote','trailing.','trailing ',' leading',"line`nbreak")) {
        Assert (-not (Test-ProjectName $name)) ('Invalid name accepted: '+$name)
    }
    Assert (Test-ProjectName "中文 空格 & 百分号% [x] ' 引号") 'Valid name rejected'
    foreach ($language in @('c','cpp','py','java')) {
        $name=$language+' 中文 空格 & 百分号% [x]'
        $scriptPath=Join-Path $repo ('windows/new-'+$language+'.ps1')
        $check=Start-LauncherProcess -Script $scriptPath -Arguments @('-Check','-Root',$root)
        $check.Process.WaitForExit()
        Assert ($check.Process.ExitCode -eq 0) ($check.Error.GetAwaiter().GetResult())
        Assert (-not (Test-Path -LiteralPath (Join-Path $root $name))) 'Preflight wrote a project'
        $check.Process.Dispose()
        $job=Start-LauncherProcess -Script $scriptPath -Arguments @($name,'-Root',$root)
        $job.Process.WaitForExit()
        $output=$job.Output.GetAwaiter().GetResult()+$job.Error.GetAwaiter().GetResult()
        $project=Join-Path $root $name
        Assert ($job.Process.ExitCode -eq 0) $output
        Assert (Test-CompletedProject $project $job.Process.ExitCode) ('Incomplete project: '+$output)
        Assert ($output.Contains($project)) 'Captured project path lost Unicode characters'
        foreach ($json in Get-ChildItem -LiteralPath (Join-Path $project '.vscode') -Filter '*.json') {
            [void](Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        Assert (-not (Test-CompletedProject $project 17)) 'Nonzero exit accepted as success'
        if ($env:OS -eq 'Windows_NT') {
            if ($language -in @('c','cpp','java')) {
                $tasks=Get-Content -LiteralPath (Join-Path $project '.vscode/tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $build=$tasks.tasks[0]
                $arguments=@($build.args | ForEach-Object { $_.Replace('${workspaceFolder}',$project) })
                $workingDirectory=$build.options.cwd.Replace('${workspaceFolder}',$project)
                $result=Invoke-CapturedProcess -Exe $build.command -Arguments $arguments -WorkingDirectory $workingDirectory
                Assert ($result.ExitCode -eq 0) ($result.Output+$result.Error)
                if ($language -eq 'java') {
                    $run=$tasks.tasks[1]
                    $arguments=@($run.args | ForEach-Object { $_.Replace('${workspaceFolder}',$project) })
                    $result=Invoke-CapturedProcess -Exe $run.command -Arguments $arguments -WorkingDirectory $workingDirectory
                } else {
                    $result=Invoke-CapturedProcess -Exe (Join-Path $project 'build/main.exe')
                }
                Assert ($result.ExitCode -eq 0) $result.Error
            } elseif ($language -eq 'py') {
                $result=Invoke-CapturedProcess -Exe (Join-Path $project '.venv/Scripts/python.exe') -Arguments @((Join-Path $project 'main.py')) -Environment @{PYTHONIOENCODING='utf-8'}
                Assert ($result.ExitCode -eq 0) $result.Error

            }
        }
        $job.Process.Dispose()
        Write-Output ('PASS template: '+$language)
    }
    $dash=Start-LauncherProcess -Script (Join-Path $repo 'windows/new-c.ps1') -Arguments @('-Root',$root) -Environment @{ENVLAUNCHER_NAME='-Check'}
    $dash.Process.WaitForExit()
    Assert ($dash.Process.ExitCode -eq 0 -and (Test-CompletedProject (Join-Path $root '-Check') 0)) 'A leading dash changed the project name into an option'
    $dash.Process.Dispose()
    $existing=Join-Path $root 'existing'; [void][IO.Directory]::CreateDirectory($existing)
    Write-ProjectText (Join-Path $existing 'sentinel') 'keep'
    $duplicateFailed=$false
    try { New-EnvironmentProject -Language c -Name existing -Root $root } catch { $duplicateFailed=$true }
    Assert $duplicateFailed 'Existing project was accepted'
    Assert ((Get-ChildItem -LiteralPath $existing).Count -eq 1) 'Existing project changed'
    Assert (-not (Test-CompletedProject $existing 0)) 'Directory without manifest accepted'
    $originalChain=${function:Get-CppToolchain}
    try {
        function Get-CppToolchain { param([switch]$Cpp) return @{Kind='none';Compiler='gcc';Debugger=$null;IntelliSense='windows-gcc-x64'} }
        New-EnvironmentProject -Language c -Name missing-compiler -Root $root | Out-Null
        Assert (Test-Path -LiteralPath (Join-Path $root 'missing-compiler/!缺少工具链.md')) 'Missing compiler notice not written'
        function Get-CppToolchain { param([switch]$Cpp) return @{Kind='msvc';Compiler='cl.exe';Vcvars='C:\Program Files\Build Tools\VC\Auxiliary\Build\vcvars64.bat';IntelliSense='windows-msvc-x64'} }
        foreach ($language in @('c','cpp')) {
            New-EnvironmentProject -Language $language -Name ('msvc-'+$language) -Root $root | Out-Null
            $generated=Join-Path $root ('msvc-'+$language+'/.vscode/build.ps1')
            $e=$null; $t=$null
            [void][Management.Automation.Language.Parser]::ParseFile($generated,[ref]$t,[ref]$e)
            Assert ($e.Count -eq 0) ($e | Out-String)
            $bytes=[IO.File]::ReadAllBytes($generated)
            Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Generated MSVC script missing BOM'
            $launch=Get-Content -LiteralPath (Join-Path $root ('msvc-'+$language+'/.vscode/launch.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert ($launch.configurations[0].type -eq 'cppvsdbg') 'Incorrect MSVC debug adapter'
        }
    } finally { ${function:Get-CppToolchain}=$originalChain }
    $script:FailureWriter=$originalWriter
    function Write-ProjectText { param([string]$Path,[string]$Text) if ($Path -like '*main.c') { throw 'simulated write failure' }; & $script:FailureWriter $Path $Text }
    $failed=$false
    try { New-EnvironmentProject -Language c -Name partial -Root $root } catch { $failed=$true }
    Assert $failed 'Write failure did not fail'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'partial'))) 'Failed project was not cleaned'
    ${function:Write-ProjectText}=$originalWriter
    $argumentsFixture=Join-Path $base 'arguments.ps1'
    Write-ProjectText $argumentsFixture 'param([string]$Literal) [Console]::SetOut([IO.StreamWriter]::new([Console]::OpenStandardOutput(),[Text.UTF8Encoding]::new($false))); [Console]::Out.Write($Literal); [Console]::Out.Flush()'
    $shell=Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $shell)) { $shell=Join-Path $PSHOME 'pwsh' }
    foreach ($literal in @('C:\folder\', 'space and & literal %TEMP% [x]', 'embedded"quote', "中文 ' 单引号")) {
        $roundtrip=Invoke-CapturedProcess -Exe $shell -Arguments @('-NoProfile','-File',$argumentsFixture,'-Literal',$literal)
        Assert ($roundtrip.ExitCode -eq 0 -and $roundtrip.Output -ceq $literal) ('Native argument changed: '+$literal)
    }
    $fixture=Join-Path $base 'failing.ps1'
    Write-ProjectText $fixture '[Console]::Out.Write(("o" * 262144)); [Console]::Error.Write(("e" * 262144)); exit 17'
    $shell=Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $shell)) { $shell=Join-Path $PSHOME 'pwsh' }
    $result=Invoke-CapturedProcess -Exe $shell -Arguments @('-NoProfile','-File',$fixture) -TimeoutSeconds 20
    Assert ($result.ExitCode -eq 17 -and $result.Output.Length -eq 262144 -and $result.Error.Length -eq 262144) 'Exit code or captured streams lost'
    Write-Output 'PASS validation, existing project protection, rollback, exit codes, and large output capture'
} finally {
    ${function:Write-ProjectText}=$originalWriter
    Remove-Item -LiteralPath $base -Recurse -Force
}
