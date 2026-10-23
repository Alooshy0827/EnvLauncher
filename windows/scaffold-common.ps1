#Requires -Version 5.1
# Shared scaffolding and subprocess handling. Saved as UTF-8 with BOM for Windows PowerShell.
function Test-ProjectName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -eq $Name.Trim() -and
        $Name -notmatch '[\x00-\x1f\x7f\\/:*?"<>|]' -and $Name -notmatch '[. ]$' -and
        $Name -notmatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)')
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # CommandLineToArgvW quoting, including trailing backslashes before the closing quote.
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-CapturedProcess {
    param([string]$Exe, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 180, [hashtable]$Environment = @{}, [string]$WorkingDirectory = '')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = $Environment[$key] }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "执行超时（$TimeoutSeconds 秒）：$Exe"
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = $stderr.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Find-WorkingTool {
    param([string[]]$Names, [string[]]$VersionArgs = @('--version'), [string]$Pattern = '\S')
    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        try {
            $result = Invoke-CapturedProcess -Exe $command.Source -Arguments $VersionArgs -TimeoutSeconds 5
            if ($result.ExitCode -eq 0 -and ($result.Output + $result.Error) -match $Pattern) { return $command.Source }
        } catch {}
    }
    return $null
}

function Get-CppToolchain {
    param([switch]$Cpp)
    $compilerNames = if ($Cpp) { @('g++') } else { @('gcc') }
    $compiler = Find-WorkingTool -Names $compilerNames
    if ($compiler) {
        return @{ Kind='gcc'; Compiler=$compiler; Debugger=(Find-WorkingTool -Names @('gdb')); Mode='gdb'; IntelliSense='windows-gcc-x64' }
    }
    # Locate any supported Visual Studio edition, including standalone Build Tools.
    $vswhere = $null
    if (${env:ProgramFiles(x86)}) { $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
    if ($vswhere -and (Test-Path -LiteralPath $vswhere)) {
        try {
            $result = Invoke-CapturedProcess -Exe $vswhere -Arguments @('-utf8','-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath') -TimeoutSeconds 10
            $installation = $result.Output.Trim()
            if ($result.ExitCode -eq 0 -and $installation) {
                $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
                if (Test-Path -LiteralPath $vcvars) {
                    $versionFile=Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
                    $compiler='cl.exe'
                    if (Test-Path -LiteralPath $versionFile) {
                        $version=(Get-Content -LiteralPath $versionFile -Raw).Trim()
                        $candidate=Join-Path $installation ('VC\Tools\MSVC\'+$version+'\bin\Hostx64\x64\cl.exe')
                        if (Test-Path -LiteralPath $candidate) { $compiler=$candidate }
                    }
                    return @{ Kind='msvc'; Compiler=$compiler; Vcvars=$vcvars; IntelliSense='windows-msvc-x64' }
                }
            }
        } catch {}
    }
    $compilerNames = if ($Cpp) { @('clang++') } else { @('clang') }
    $compiler = Find-WorkingTool -Names $compilerNames
    if ($compiler) {
        # LLVM's lldb executable does not implement the MI protocol required by cppdbg.
        return @{ Kind='clang'; Compiler=$compiler; Debugger=(Find-WorkingTool -Names @('gdb')); Mode='gdb'; IntelliSense='windows-clang-x64' }
    }
    return @{ Kind='none'; Compiler=($(if ($Cpp) { 'g++' } else { 'gcc' })); IntelliSense='windows-gcc-x64'; Mode='gdb'; Debugger=$null }
}

function Write-ProjectText {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Write-ProjectJson {
    param([string]$Path, $Value)
    Write-ProjectText -Path $Path -Text ($Value | ConvertTo-Json -Depth 16)
}

function New-EnvironmentProject {
    param([ValidateSet('c','cpp','py','java')][string]$Language, [string]$Name, [string]$Root, [switch]$Check)
    $ErrorActionPreference = 'Stop'
    $tool = $null; $pythonArgs = @(); $chain = $null
    $extension = 'ms-vscode.cpptools'
    switch ($Language) {
        { $_ -in @('c','cpp') } { $chain = Get-CppToolchain -Cpp:($Language -eq 'cpp'); if ($chain.Kind -ne 'none') { $tool = $chain.Compiler } }
        py {
            $extension = 'ms-python.python'
            $tool = Find-WorkingTool -Names @('py') -VersionArgs @('-3','--version') -Pattern '^Python 3\.'
            if ($tool) { $pythonArgs = @('-3') } else { $tool = Find-WorkingTool -Names @('python','python3') -Pattern '^Python 3\.' }
        }
        java { $extension='vscjava.vscode-java-pack'; $tool=Find-WorkingTool -Names @('javac') -VersionArgs @('-version') -Pattern 'javac\s+\d' }
    }
    if ($Check) {
        if ($tool) { Write-Output "工具链已找到：$tool" } else { Write-Output '缺少工具链；仍可创建项目，安装后再运行。' }
        if ($chain -and $chain.Kind -ne 'msvc' -and -not $chain.Debugger) { Write-Output '未找到 GDB；可以编译，调试前请安装匹配的调试器。' }
        Write-Output "VS Code 扩展：$extension"
        return
    }
    if (-not (Test-ProjectName $Name)) { throw '项目名不能为空，不能包含控制字符、路径分隔符、Windows 保留字符/名称，或以空格开头、空格/句点结尾。' }
    if (-not $Root) { $Root = Join-Path $env:USERPROFILE 'VS Code' }
    if ($Root -match '[\x00-\x1f\x7f]') { throw '保存位置不能包含控制字符。' }
    $Root = [IO.Path]::GetFullPath($Root)
    $dir = Join-Path $Root $Name
    [void][IO.Directory]::CreateDirectory($Root)
    # On Windows use atomic CreateDirectoryW, which fails if another process owns the path.
    # The portable test runner uses a sibling lock because kernel32 is unavailable there.
    $lock = $null; $owned = $false; $completed = $false
    $lockPath = Join-Path $Root ('.envlauncher-' + $Name + '.lock')
    try {
        if ($env:OS -eq 'Windows_NT') {
            if (-not ('EnvLauncherDirectory' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EnvLauncherDirectory {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CreateDirectory(string path, IntPtr securityAttributes);
}
'@
            }
            if (-not [EnvLauncherDirectory]::CreateDirectory($dir,[IntPtr]::Zero)) {
                throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
            }
        } else {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            if (Test-Path -LiteralPath $dir) { throw "项目已存在：$dir" }
            [void][IO.Directory]::CreateDirectory($dir)
        }
        $owned = $true
        [void][IO.Directory]::CreateDirectory((Join-Path $dir '.vscode'))
        $recommendations = @($extension)
        if ($Language -eq 'py') { $recommendations += 'ms-python.debugpy' }
        Write-ProjectJson (Join-Path $dir '.vscode/extensions.json') @{ recommendations=$recommendations }
        Write-ProjectText (Join-Path $dir '.gitignore') ".venv/`n__pycache__/`n*.py[cod]`nbuild/`nbin/"
        $warning = ''; $source = ''; $configuration = $null
        switch ($Language) {
            { $_ -in @('c','cpp') } {
                [void][IO.Directory]::CreateDirectory((Join-Path $dir 'src'))
                [void][IO.Directory]::CreateDirectory((Join-Path $dir 'build'))
                $standard = '-std=c17'; $source='src/main.c'
                $code = "#include <stdio.h>`n`nint main(void)`n{`n    puts(`"Hello, C!`");`n    return 0;`n}"
                if ($Language -eq 'cpp') {
                    $source='src/main.cpp'; $standard='-std=c++17'
                    $code = "#include <iostream>`n`nint main()`n{`n    std::cout << `"Hello, C++!`" << std::endl;`n    return 0;`n}"
                }
                Write-ProjectText (Join-Path $dir $source) $code
                Write-ProjectJson (Join-Path $dir '.vscode/c_cpp_properties.json') @{ version=4; configurations=@(@{ name='Windows'; includePath=@('${workspaceFolder}/src/**'); compilerPath=($chain.Compiler -replace '\\','/'); cStandard='c17'; cppStandard='c++17'; intelliSenseMode=$chain.IntelliSense }) }
                # Relative paths keep MinGW's ANSI command-line parser away from Unicode project directories.
                $build = [ordered]@{ label='编译'; type='process'; command=$chain.Compiler; args=@($standard,'-Wall','-Wextra','-g','-O0','-o','build/main.exe',$source); options=@{cwd='${workspaceFolder}'}; problemMatcher=@('$gcc'); group=@{kind='build';isDefault=$true} }
                $configuration = [ordered]@{name='调试 (F5)';type='cppdbg';request='launch';program='${workspaceFolder}/build/main.exe';cwd='${workspaceFolder}';externalConsole=$true;MIMode='gdb';preLaunchTask='编译'}
                if ($chain.Kind -eq 'msvc') {
                    Write-ProjectJson (Join-Path $dir '.vscode/settings.json') @{ 'envlauncher.vcvars'=$chain.Vcvars }
                    # A process task avoids cmd/PowerShell interpolation of user project paths.
                    $build.command='powershell.exe'
                    $build.args=@('-NoProfile','-ExecutionPolicy','Bypass','-File','${workspaceFolder}/.vscode/build.ps1')
                    $build.problemMatcher=@('$msCompile')
                    $msvcScript = @'
$ErrorActionPreference = 'Stop'
$settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json
$vcvars = $settings.'envlauncher.vcvars'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $env:ComSpec
$info.Arguments = '/d /u /s /c ""' + $vcvars + '" >nul && set"'
$info.UseShellExecute = $false; $info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
$info.StandardOutputEncoding = [Text.Encoding]::Unicode
$info.StandardErrorEncoding = [Text.Encoding]::Unicode
$process = New-Object Diagnostics.Process; $process.StartInfo = $info
try {
    [void]$process.Start()
    $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'MSVC 开发环境加载超时。' }
    if ($process.ExitCode -ne 0) { throw ('无法加载 MSVC 开发环境：' + $errors.GetAwaiter().GetResult()) }
    $environmentLines = $output.GetAwaiter().GetResult() -split "`r?`n"
} finally { $process.Dispose() }
foreach ($line in $environmentLines) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
$project = Split-Path -Parent $PSScriptRoot
$source = Join-Path $project '__SOURCE__'
$output = Join-Path $project 'build/main.exe'
$object = Join-Path $project 'build/main.obj'
& cl.exe /nologo __STANDARD__ /W4 /Zi /utf-8 "/Fe:$output" "/Fo:$object" $source
exit $LASTEXITCODE
'@
                    $msvcStandard = if ($Language -eq 'cpp') { '/std:c++17 /EHsc' } else { '/std:c17' }
                    # Windows PowerShell must read this generated script with a BOM, too.
                    [IO.File]::WriteAllText((Join-Path $dir '.vscode/build.ps1'), $msvcScript.Replace('__SOURCE__',$source).Replace('__STANDARD__',$msvcStandard), (New-Object Text.UTF8Encoding($true)))
                    $configuration.Remove('MIMode'); $configuration.Remove('externalConsole'); $configuration.type='cppvsdbg'
                } elseif ($chain.Debugger) { $configuration.miDebuggerPath=$chain.Debugger }
                if ($chain.Kind -eq 'none') { $warning='没有找到可用的 C/C++ 编译器。请安装 MinGW-w64（含 GCC 和 GDB）或 Visual Studio C++ Build Tools，然后重启 VS Code。' }
                elseif ($chain.Kind -ne 'msvc' -and -not $chain.Debugger) { $warning='编译器已找到，但没有找到可用的 GDB。编译任务可用；F5 调试前请安装匹配的调试器并在 launch.json 中设置 miDebuggerPath。' }
                Write-ProjectJson (Join-Path $dir '.vscode/tasks.json') @{ version='2.0.0'; tasks=@($build,@{label='运行';type='process';command='${workspaceFolder}/build/main.exe';dependsOn='编译';problemMatcher=@()}) }
            }
            py {
                $source='main.py'
                Write-ProjectText (Join-Path $dir $source) "def main():`n    print(`"你好，Python！`")`n`n`nif __name__ == `"__main__`":`n    main()"
                Write-ProjectJson (Join-Path $dir '.vscode/settings.json') @{ 'python.defaultInterpreterPath'='${workspaceFolder}/.venv/Scripts/python.exe'; 'python.terminal.activateEnvironment'=$true }
                $configuration=@{name='调试 (F5)';type='debugpy';request='launch';program='${workspaceFolder}/main.py';console='integratedTerminal'}
                if (-not $tool) { $warning='没有找到可用的 Python 3。请安装 Python 3，然后在项目目录运行 python -m venv .venv。' }
                else {
                    Write-Output '正在创建 Python 虚拟环境…'
                    $result=Invoke-CapturedProcess -Exe $tool -Arguments ($pythonArgs + @('-m','venv',(Join-Path $dir '.venv'))) -TimeoutSeconds 120
                    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dir '.venv/Scripts/python.exe'))) {
                        Write-ProjectText (Join-Path $dir '.venv-create.log') ($result.Output + $result.Error)
                        $warning='Python 已找到，但虚拟环境创建失败。具体错误见 .venv-create.log。修复后在本目录运行 python -m venv .venv。'
                    }
                }
            }
            java {
                $source='src/Main.java'
                [void][IO.Directory]::CreateDirectory((Join-Path $dir 'src')); [void][IO.Directory]::CreateDirectory((Join-Path $dir 'bin'))
                Write-ProjectText (Join-Path $dir $source) "public class Main {`n    public static void main(String[] args) {`n        System.out.println(`"Hello, Java!`");`n    }`n}"
                Write-ProjectJson (Join-Path $dir '.vscode/settings.json') @{ 'java.project.sourcePaths'=@('src'); 'java.project.outputPath'='bin'; 'java.configuration.updateBuildConfiguration'='automatic' }
                $javac = if ($tool) { $tool } else { 'javac' }
                Write-ProjectJson (Join-Path $dir '.vscode/tasks.json') @{version='2.0.0';tasks=@(@{label='编译';type='process';command=$javac;args=@('-encoding','UTF-8','-d','bin','src/Main.java');options=@{cwd='${workspaceFolder}'};problemMatcher=@('$javac');group=@{kind='build';isDefault=$true}},@{label='运行';type='process';command='java';args=@('-cp','bin','Main');options=@{cwd='${workspaceFolder}'};dependsOn='编译';problemMatcher=@()})}
                $configuration=@{name='调试 (F5)';type='java';request='launch';mainClass='Main';cwd='${workspaceFolder}'}
                if (-not $tool) { $warning='没有找到可用的 JDK（javac）。请从 https://adoptium.net/ 安装 JDK，然后重启 VS Code。' }
            }
        }
        Write-ProjectJson (Join-Path $dir '.vscode/launch.json') @{version='0.2.0';configurations=@($configuration)}
        if ($warning) { Write-ProjectText (Join-Path $dir '!缺少工具链.md') "# 工具链需要处理`n`n$warning`n`n修复后即可使用现有项目，无需重建。确认可以运行后可删除本提示。" }
        Write-ProjectText (Join-Path $dir 'README.md') "# $Name`n`n在 $source 中编写代码。安装 VS Code 推荐的扩展后按 F5 调试。`n`nC/C++ 和 Java 的编译任务默认编译入口文件；多文件项目请按需扩展 tasks.json。Python 使用 .venv。"
        Write-ProjectJson (Join-Path $dir '.envlauncher.json') @{schemaVersion=1;language=$Language;requiredFiles=@($source,'.vscode/launch.json','.vscode/extensions.json','README.md')}
        $completed=$true
        Write-Output "项目已创建：$dir"
        if ($warning) { Write-Output $warning }
    }
    finally {
        if ($owned -and -not $completed) { Remove-Item -LiteralPath $dir -Recurse -Force }
        if ($lock) { $lock.Dispose(); Remove-Item -LiteralPath $lockPath -Force }
    }
}
