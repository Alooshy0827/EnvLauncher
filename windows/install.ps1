#Requires -Version 5.1
<#
    install.ps1 —— 安装 EnvLauncher（环境启动器）

    做三件事：
      1. 把 new-c / new-py 等文件复制到 %USERPROFILE%\bin
      2. 把这个目录加进你的用户 PATH（这样在终端任何位置都能用 new-c）
      3. 在桌面创建「环境启动器」快捷方式（可选）

    用法：右键本文件 → “使用 PowerShell 运行”
      或在 PowerShell 里：  powershell -ExecutionPolicy Bypass -File install.ps1
#>

$ErrorActionPreference = 'Stop'

$SourceDir = $PSScriptRoot
$BinDir    = Join-Path $env:USERPROFILE 'bin'

$Bold  = "$([char]27)[1m"
$Green = "$([char]27)[32m"
$Yellow= "$([char]27)[33m"
$Dim   = "$([char]27)[2m"
$Reset = "$([char]27)[0m"

function Write-Step  { param([string]$t) Write-Host "$Green  ✓$Reset $t" }
function Write-Warn  { param([string]$t) Write-Host "$Yellow  !$Reset $t" }

Write-Host ''
Write-Host "$Bold 环境启动器 安装程序$Reset"
Write-Host "$Dim  源目录: $SourceDir$Reset"
Write-Host "$Dim  目标  : $BinDir$Reset"
Write-Host ''

# ── 1. 复制文件 ──
if (-not (Test-Path -LiteralPath $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

# 自动收录目录下所有脚本 —— 以后新增环境脚手架不用改这个文件
$files = @(Get-ChildItem -LiteralPath $SourceDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty Name)
$files += 'EnvLauncher.cmd','vscode.png'

$copied = 0
foreach ($f in $files) {
    $src = Join-Path $SourceDir $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $BinDir $f) -Force
        $copied++
    }
    else {
        Write-Warn "缺少文件: $f"
    }
}
Write-Step "已复制 $copied 个文件到 $BinDir"

# ── 2. 加入用户 PATH ──
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }

if ($userPath.Split(';') -contains $BinDir) {
    Write-Step 'PATH 中已包含该目录，跳过'
}
else {
    $newPath = if ($userPath.TrimEnd(';')) { "$($userPath.TrimEnd(';'));$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Step "已把 $BinDir 加入用户 PATH"
    Write-Warn '新 PATH 需要重开终端才生效'
}

# ── 3. 桌面快捷方式 ──
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop -and (Test-Path -LiteralPath $desktop)) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $desktop '环境启动器.lnk'))
        $lnk.TargetPath       = Join-Path $BinDir 'EnvLauncher.cmd'
        $lnk.WorkingDirectory = $BinDir
        $lnk.Description      = '选择一个环境，自动在 VS Code 新窗口打开'
        $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,13"
        $lnk.Save()
        Write-Step '已在桌面创建快捷方式'
    }
    catch {
        Write-Warn "桌面快捷方式创建失败: $($_.Exception.Message)"
    }
}

# ── 4. 执行策略提示 ──
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq 'Restricted' -or $policy -eq 'Undefined') {
    Write-Host ''
    Write-Warn "当前执行策略是 $policy，.ps1 脚本可能被拦截。"
    Write-Host "     建议运行一次：$Bold Set-ExecutionPolicy -Scope CurrentUser RemoteSigned$Reset"
}

# ── 完成 ──
Write-Host ''
Write-Host "$Green$Bold 安装完成$Reset"
Write-Host ''
Write-Host ' 现在可以：'
Write-Host "   • 双击桌面的「环境启动器」图标启动面板"
Write-Host '   • 在 PowerShell 中用 new-c 项目名 -Root D:\Projects 指定保存位置'
Write-Host ''
Write-Host "$Dim 提示：如果 new-c 提示找不到命令，重开一个终端窗口即可。$Reset"
Write-Host ''
