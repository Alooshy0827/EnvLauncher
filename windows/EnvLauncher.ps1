#Requires -Version 5.1
param([switch]$List)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'launcher-core.ps1')
if ($List) { Get-Scaffolds | Format-Table Id,Label,Path; exit 0 }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'theme.ps1')

$script:StateDirectory=$env:ENVLAUNCHER_STATE_DIR
if (-not $script:StateDirectory) { $script:StateDirectory=Join-Path $env:LOCALAPPDATA 'EnvLauncher' }
$script:SettingsFile=Join-Path $script:StateDirectory 'settings.json'
$script:Settings=[pscustomobject]@{Root=(Join-Path $env:USERPROFILE 'VS Code');LastScaffold='';Recent=@()}
try {
    if (Test-Path -LiteralPath $script:SettingsFile) {
        $saved=Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.Root -is [string] -and $saved.LastScaffold -is [string]) { $script:Settings=$saved; $script:Settings.Recent=@($saved.Recent | Where-Object { $_ -is [string] }) }
    }
} catch {}
$script:Scaffolds=@(Get-Scaffolds)
$script:ActiveTask=$null; $script:Checks=New-Object Collections.ArrayList
$script:CheckGeneration=0; $script:LastLog=$null

$form=New-Object Windows.Forms.Form
$form.Text='环境启动器'; $form.ClientSize=New-Object Drawing.Size(860,590)
$form.StartPosition='CenterScreen'; $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
$form.Font=New-Object Drawing.Font('Segoe UI',9)
$form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96); $form.AutoScaleMode='Dpi'
function Add-Label {
    param([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[switch]$Bold)
    $control=New-Object Windows.Forms.Label; $control.Text=$Text
    $control.SetBounds($X,$Y,$W,$H)
    if ($Bold) { $control.Font=New-Object Drawing.Font($form.Font.FontFamily,15,[Drawing.FontStyle]::Bold) }
    $form.Controls.Add($control); return $control
}
function Add-Button {
    param([string]$Text,[int]$X,[int]$Y,[int]$W,[scriptblock]$Click)
    $control=New-Object Windows.Forms.Button; $control.Text=$Text; $control.SetBounds($X,$Y,$W,32)
    $control.Add_Click($Click); $form.Controls.Add($control); return $control
}
$editorIcon=New-Object Windows.Forms.PictureBox
$editorIcon.SetBounds(20,23,64,64); $editorIcon.SizeMode='Zoom'
$editorIcon.AccessibleName='Visual Studio Code'; $editorIcon.TabStop=$false
$editorIcon.Image=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'vscode.png'))
$form.Controls.Add($editorIcon)
[void](Add-Label '新建项目' 96 25 294 28 -Bold)
[void](Add-Label '选好环境，直接开始写代码。' 96 60 294 24)
[void](Add-Label '环境' 28 108 360 22)
$environment=New-Object Windows.Forms.ComboBox; $environment.DropDownStyle='DropDownList'; $environment.SetBounds(28,134,362,28)
foreach ($scaffold in $script:Scaffolds) { [void]$environment.Items.Add($scaffold.Label) }
if ($script:Scaffolds.Count) {
    $environment.SelectedIndex=0
    for ($i=0;$i -lt $script:Scaffolds.Count;$i++) { if ($script:Scaffolds[$i].Id -eq $script:Settings.LastScaffold) { $environment.SelectedIndex=$i } }
}
$form.Controls.Add($environment)
[void](Add-Label '项目名称' 28 181 360 22)
$name=New-Object Windows.Forms.TextBox; $name.SetBounds(28,208,362,28); $form.Controls.Add($name)
[void](Add-Label '保存到' 28 253 360 22)
$location=New-Object Windows.Forms.TextBox; $location.SetBounds(28,280,276,28); $location.Text=$script:Settings.Root; $form.Controls.Add($location)
$browse=Add-Button '选择…' 312 277 78 {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    try { $dialog.SelectedPath=$location.Text; if ($dialog.ShowDialog() -eq 'OK') { $location.Text=$dialog.SelectedPath } } finally { $dialog.Dispose() }
}
$preview=Add-Label '' 28 320 362 44; $preview.ForeColor=[Drawing.SystemColors]::GrayText
$tooltip=New-Object Windows.Forms.ToolTip
$toolchain=Add-Label '' 28 375 362 98; $toolchain.ForeColor=[Drawing.SystemColors]::GrayText
$create=Add-Button '创建并打开' 252 482 138 { Start-Creation }
$form.AcceptButton=$create
$line=New-Object Windows.Forms.Label; $line.BorderStyle='Fixed3D'; $line.SetBounds(417,28,2,490); $form.Controls.Add($line)
[void](Add-Label '最近项目' 446 25 386 28 -Bold)
$search=New-Object Windows.Forms.TextBox; $search.SetBounds(446,68,386,28); $form.Controls.Add($search)
[void](Add-Label '搜索名称或路径' 446 99 386 20)
$recent=New-Object Windows.Forms.ListView; $recent.SetBounds(446,126,386,333)
$recent.View='Details'; $recent.FullRowSelect=$true; $recent.MultiSelect=$false; $recent.HideSelection=$false
[void]$recent.Columns.Add('项目',140); [void]$recent.Columns.Add('位置',218); $form.Controls.Add($recent)
$empty=Add-Label '最近打开的项目将显示在这里。' 461 174 352 45
$openFolder=Add-Button '打开文件夹…' 446 482 124 {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    try { if ($dialog.ShowDialog() -eq 'OK') { Open-Project $dialog.SelectedPath } } finally { $dialog.Dispose() }
}
$openWorkspace=Add-Button '打开工作区…' 577 482 124 {
    $dialog=New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter='VS Code 工作区 (*.code-workspace)|*.code-workspace'
    try { if ($dialog.ShowDialog() -eq 'OK') { Open-Project $dialog.FileName } } finally { $dialog.Dispose() }
}
$openRecent=Add-Button '打开' 708 482 124 { Open-SelectedRecent }
$footer=New-Object Windows.Forms.Label; $footer.BorderStyle='Fixed3D'; $footer.SetBounds(28,531,804,2); $form.Controls.Add($footer)
$status=Add-Label '文件准备完成后会在 VS Code 新窗口打开。' 28 545 642 36
$status.Font=New-Object Drawing.Font($form.Font.FontFamily,10.5)
$logButton=Add-Button '查看日志' 736 541 96 { if ($script:LastLog) { Start-Process -FilePath notepad.exe -ArgumentList (ConvertTo-NativeArgument $script:LastLog) } }
$logButton.Enabled=$false
$progress=New-Object Windows.Forms.ProgressBar; $progress.SetBounds(28,577,804,5); $progress.Style='Marquee'; $progress.Visible=$false; $form.Controls.Add($progress)

function Show-Failure { param([string]$Text) [void][Windows.Forms.MessageBox]::Show($form,$Text,'操作未完成','OK','Warning') }
function Save-Settings {
    try {
        [void][IO.Directory]::CreateDirectory($script:StateDirectory)
        $temporary=$script:SettingsFile+'.'+[guid]::NewGuid().ToString()+'.tmp'
        Write-ProjectJson $temporary $script:Settings
        Move-Item -LiteralPath $temporary -Destination $script:SettingsFile -Force
    } catch { $status.Text='项目可用，但无法保存最近记录：'+$_.Exception.Message }
}
function Refresh-Recent {
    $recent.Items.Clear()
    foreach ($path in @($script:Settings.Recent)) {
        if ($search.Text -and $path.IndexOf($search.Text,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $item=New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileName($path.TrimEnd('\','/')))
        [void]$item.SubItems.Add($path); $item.Tag=$path; [void]$recent.Items.Add($item)
    }
    $empty.Text=if ($search.Text) { '没有匹配的最近项目。' } else { '最近打开的项目将显示在这里。' }
    $empty.Visible=$recent.Items.Count -eq 0
}
function Record-Recent {
    param([string]$Path)
    $script:Settings.Recent=@($Path)+@($script:Settings.Recent | Where-Object { $_ -ne $Path })
    $script:Settings.Recent=@($script:Settings.Recent | Select-Object -First 30)
    Save-Settings; Refresh-Recent
}
function Update-Preview {
    $preview.Text=$location.Text.TrimEnd('\','/')+'\'+$name.Text
    $tooltip.SetToolTip($preview,$preview.Text)
    $create.Enabled=-not $script:ActiveTask -and (Test-ProjectName $name.Text) -and [IO.Path]::IsPathRooted($location.Text) -and $environment.SelectedIndex -ge 0
    if ($name.Text -and -not (Test-ProjectName $name.Text)) { $status.Text='请使用有效名称，避开路径分隔符、保留名称，以及开头的空格和结尾的空格/句点。' }
    elseif (-not $script:ActiveTask) { $status.Text='文件准备完成后会在 VS Code 新窗口打开。' }
}
function Set-Busy {
    param([bool]$Busy)
    foreach ($control in @($environment,$name,$location,$browse,$openFolder,$openWorkspace,$openRecent,$recent,$search)) { $control.Enabled=-not $Busy }
    $progress.Visible=$Busy
    if ($Busy) { $create.Enabled=$false } else { Update-Preview }
}
function Refresh-Toolchain {
    $script:CheckGeneration++
    if ($environment.SelectedIndex -lt 0) { $toolchain.Text='未发现脚手架，请重新安装应用。'; return }
    $scaffold=$script:Scaffolds[$environment.SelectedIndex]
    if ($scaffold.Protocol -lt 2) { $toolchain.Text='自定义脚手架：'+$scaffold.Path+"`n保存位置通过 ENVLAUNCHER_ROOT 传入。"; return }
    $toolchain.Text='正在检测工具链…'
    try {
        $job=Start-LauncherProcess -Script $scaffold.Path -Arguments @('-Check')
        $job | Add-Member -NotePropertyName Generation -NotePropertyValue $script:CheckGeneration
        [void]$script:Checks.Add($job)
    } catch { $toolchain.Text='工具链检测失败：'+$_.Exception.Message }
}
function Start-Creation {
    if ($script:ActiveTask -or -not (Test-ProjectName $name.Text)) { return }
    try {
        if (-not [IO.Path]::IsPathRooted($location.Text)) { throw '请选择有效的绝对保存路径。' }
        $root=[IO.Path]::GetFullPath($location.Text)
        $target=Join-Path $root $name.Text
        if (Test-Path -LiteralPath $target) { throw "项目已存在：$target`n请换一个名称，或打开已有项目。" }
        $code=Get-VSCodeCommand
        if (-not $code) { throw '没有找到 VS Code。请先安装 VS Code，或将 code 命令加入 PATH。' }
        $scaffold=$script:Scaffolds[$environment.SelectedIndex]
        $arguments=@($name.Text)
        $childEnvironment=@{ENVLAUNCHER_ROOT=$root}
        if ($scaffold.Protocol -ge 2) {
            # powershell.exe -File reparses leading dashes even in quoted values.
            # Pass the name as a child-only environment value to preserve it literally.
            $arguments=@('-Root',$root); $childEnvironment.ENVLAUNCHER_NAME=$name.Text
        }
        $job=Start-LauncherProcess -Script $scaffold.Path -Arguments $arguments -Environment $childEnvironment
        $script:Settings.Root=$root; $script:Settings.LastScaffold=$scaffold.Id
        $script:ActiveTask=[pscustomobject]@{Kind='Create';Job=$job;Path=$target;Code=$code;Protocol=$scaffold.Protocol}
        Set-Busy $true; $status.Text='正在创建 '+$name.Text+'…窗口会保持打开。'
    } catch { Show-Failure $_.Exception.Message }
}
function Start-Open {
    param([string]$Path,[string]$Code)
    $job=Start-LauncherProcess -Script (Join-Path $PSScriptRoot 'open-vscode.ps1') -Arguments @('-Code',$Code,'-Path',$Path)
    $script:ActiveTask=[pscustomobject]@{Kind='Open';Job=$job;Path=$Path;Code=$Code;Protocol=0}
    Set-Busy $true; $status.Text='正在打开项目…'
}
function Open-Project {
    param([string]$Path)
    if ($script:ActiveTask) { return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { throw "项目路径已移动或删除：$Path" }
        $code=Get-VSCodeCommand
        if (-not $code) { throw '没有找到 VS Code，请先安装 VS Code。' }
        Start-Open $Path $code
    } catch { Show-Failure $_.Exception.Message }
}
function Open-SelectedRecent { if ($recent.SelectedItems.Count -gt 0) { Open-Project ([string]$recent.SelectedItems[0].Tag) } }
$recent.Add_DoubleClick({ Open-SelectedRecent })
$name.Add_TextChanged({ Update-Preview }); $location.Add_TextChanged({ Update-Preview })
$search.Add_TextChanged({ Refresh-Recent }); $environment.Add_SelectedIndexChanged({ Refresh-Toolchain })

$timer=New-Object Windows.Forms.Timer; $timer.Interval=120
$script:LastThemeCheck=[DateTime]::MinValue
$timer.Add_Tick({
    if (([DateTime]::UtcNow-$script:LastThemeCheck).TotalSeconds -ge 1) {
        $script:LastThemeCheck=[DateTime]::UtcNow
        Set-LauncherTheme -Form $form -SecondaryControls @($preview,$toolchain,$empty,$status) -Separators @($line,$footer) -InputOverlays @($empty)
    }
    foreach ($check in @($script:Checks.ToArray())) {
        if (-not $check.Process.HasExited) { continue }
        try {
            $output=$check.Output.GetAwaiter().GetResult()+$check.Error.GetAwaiter().GetResult()
            if ($check.Generation -eq $script:CheckGeneration) { $toolchain.Text=$output.Trim() }
        } catch { $toolchain.Text='检测未完成，创建时会记录详细日志。' }
        finally { $check.Process.Dispose(); [void]$script:Checks.Remove($check) }
    }
    if (-not $script:ActiveTask -or -not $script:ActiveTask.Job.Process.HasExited) { return }
    $task=$script:ActiveTask; $script:ActiveTask=$null
    try {
        $exitCode=$task.Job.Process.ExitCode
        $output=$task.Job.Output.GetAwaiter().GetResult()+$task.Job.Error.GetAwaiter().GetResult()
        [void][IO.Directory]::CreateDirectory((Join-Path $script:StateDirectory 'Logs'))
        $script:LastLog=Join-Path $script:StateDirectory ('Logs\'+[guid]::NewGuid().ToString()+'.log')
        Write-ProjectText $script:LastLog ("退出码：$exitCode`n"+$output)
        $logButton.Enabled=$true
        Set-Busy $false
        if ($task.Kind -eq 'Create') {
            if (-not (Test-CompletedProject -Path $task.Path -ExitCode $exitCode -Protocol $task.Protocol)) {
                $status.Text='创建失败；可修改后重试。点击“查看日志”了解原因。'
                if ($output.Length -gt 1400) { $output=$output.Substring($output.Length-1400) }
                Show-Failure ("脚手架退出码：$exitCode`n项目未完整生成。`n"+$output)
            } else {
                Record-Recent $task.Path
                Start-Open $task.Path $task.Code
            }
        } elseif ($exitCode -ne 0) {
            $status.Text='项目已保留，但无法打开 VS Code。点击“查看日志”了解原因。'
            Show-Failure $status.Text
        } else {
            Record-Recent $task.Path
            $status.Text='已打开：'+[IO.Path]::GetFileName($task.Path)
            if (Test-Path -LiteralPath (Join-Path $task.Path '!缺少工具链.md')) { $status.Text='项目已打开。工具链需要处理，请查看项目内的 !缺少工具链.md。' }
        }
    } catch { Set-Busy $false; Show-Failure $_.Exception.Message }
    finally { $task.Job.Process.Dispose() }
})
$form.Add_FormClosing({ param($sender,$eventArgs) if ($script:ActiveTask) { $eventArgs.Cancel=$true; $status.Text='正在处理项目，请等待完成后关闭。' } })
$form.Add_Shown({ Set-LauncherTheme -Form $form -SecondaryControls @($preview,$toolchain,$empty,$status) -Separators @($line,$footer) -InputOverlays @($empty) -Force; Refresh-Recent; Update-Preview; Refresh-Toolchain; $timer.Start(); $name.Focus() })
Enable-LauncherThemedDrawing -EnvironmentCombo $environment -RecentList $recent
Set-LauncherTheme -Form $form -SecondaryControls @($preview,$toolchain,$empty,$status) -Separators @($line,$footer) -InputOverlays @($empty) -Force
try { [void]$form.ShowDialog() }
finally {
    $timer.Stop(); $timer.Dispose()
    foreach ($check in $script:Checks) { try { if (-not $check.Process.HasExited) { $check.Process.Kill() } } catch {}; $check.Process.Dispose() }
    $tooltip.Dispose(); $editorIcon.Image.Dispose(); $form.Dispose()
}
