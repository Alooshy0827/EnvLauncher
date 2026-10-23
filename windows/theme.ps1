#Requires -Version 5.1
# Application appearance follows the user's app color mode; no system setting is changed.
function Resolve-LauncherThemeMode {
    param($AppsUseLightTheme, [bool]$HighContrast=$false)
    if ($HighContrast) { return 'HighContrast' }
    if ($null -ne $AppsUseLightTheme -and $AppsUseLightTheme -eq 0) { return 'Dark' }
    return 'Light'
}
function Get-LauncherThemeMode {
    if ($env:OS -ne 'Windows_NT') { return 'Light' }
    if ([Windows.Forms.SystemInformation]::HighContrast) { return 'HighContrast' }
    try {
        $preference=Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        return Resolve-LauncherThemeMode -AppsUseLightTheme $preference
    } catch {}
    return 'Light'
}
function Get-LauncherThemePalette {
    param([ValidateSet('Light','Dark','HighContrast')][string]$Mode)
    if ($Mode -eq 'Dark') {
        return @{Background='#202020';Text='#dedede';Secondary='#a8a8a8';Input='#292929';Button='#303030';Border='#484848';Hover='#3a3a3a';Pressed='#444444';Selection='#3d434c';SelectionText='#dedede';Header='#282828'}
    }
    if ($Mode -eq 'HighContrast') {
        return @{Background=[Drawing.SystemColors]::Control;Text=[Drawing.SystemColors]::ControlText;Secondary=[Drawing.SystemColors]::ControlText;Input=[Drawing.SystemColors]::Window;Button=[Drawing.SystemColors]::Control;Border=[Drawing.SystemColors]::WindowText;Hover=[Drawing.SystemColors]::Control;Pressed=[Drawing.SystemColors]::Control;Selection=[Drawing.SystemColors]::Highlight;SelectionText=[Drawing.SystemColors]::HighlightText;Header=[Drawing.SystemColors]::Control}
    }
    return @{Background='#f0f0f0';Text='#222222';Secondary='#666666';Input='#ffffff';Button='#e8e8e8';Border='#bdbdbd';Hover='#dddddd';Pressed='#d0d0d0';Selection='#d8d8d8';SelectionText='#222222';Header='#e8e8e8'}
}
function Set-LauncherTheme {
    param($Form, [object[]]$SecondaryControls=@(), [object[]]$Separators=@(), [object[]]$InputOverlays=@(), [switch]$Force)
    $mode=Get-LauncherThemeMode
    if (-not $Force -and $script:LauncherThemeMode -eq $mode -and $mode -ne 'HighContrast') { return }
    $script:LauncherThemeMode=$mode
    $palette=Get-LauncherThemePalette $mode
    $script:LauncherThemeColors=@{}
    foreach ($key in $palette.Keys) {
        $value=$palette[$key]
        $script:LauncherThemeColors[$key]=if ($value -is [Drawing.Color]) { $value } else { [Drawing.ColorTranslator]::FromHtml($value) }
    }
    $colors=$script:LauncherThemeColors
    $Form.SuspendLayout()
    try {
        $Form.BackColor=$colors.Background; $Form.ForeColor=$colors.Text
        $pending=New-Object Collections.Queue
        foreach ($control in $Form.Controls) { $pending.Enqueue($control) }
        while ($pending.Count) {
            $control=$pending.Dequeue()
            $control.ForeColor=$colors.Text; $control.BackColor=$colors.Background
            if ($control -is [Windows.Forms.TextBox] -or $control -is [Windows.Forms.ComboBox] -or $control -is [Windows.Forms.ListView]) { $control.BackColor=$colors.Input }
            if ($control -is [Windows.Forms.Button]) {
                $control.UseVisualStyleBackColor=$false; $control.FlatStyle='Flat'
                $control.BackColor=$colors.Button; $control.FlatAppearance.BorderColor=$colors.Border
                $control.FlatAppearance.MouseOverBackColor=$colors.Hover; $control.FlatAppearance.MouseDownBackColor=$colors.Pressed
            }
            foreach ($child in $control.Controls) { $pending.Enqueue($child) }
        }
        foreach ($control in $SecondaryControls) { $control.ForeColor=$colors.Secondary }
        foreach ($control in $InputOverlays) { $control.BackColor=$colors.Input }
        foreach ($control in $Separators) { $control.BorderStyle='None'; $control.BackColor=$colors.Border }
        if ($env:OS -eq 'Windows_NT' -and $Form.IsHandleCreated) {
            # Documented DWM opt-in. Older Windows versions can reject the attribute safely.
            try {
                if (-not ('EnvLauncherWindowTheme' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EnvLauncherWindowTheme {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
'@
                }
                $dark=if ($mode -eq 'Dark') { 1 } else { 0 }
                [void][EnvLauncherWindowTheme]::DwmSetWindowAttribute($Form.Handle,20,[ref]$dark,4)
            } catch {}
        }
    } finally { $Form.ResumeLayout(); $Form.Invalidate($true) }
}
function Enable-LauncherThemedDrawing {
    param($EnvironmentCombo,$RecentList)
    # Native WinForms popup rows and ListView headers otherwise retain a light background.
    $EnvironmentCombo.DrawMode='OwnerDrawFixed'; $EnvironmentCombo.FlatStyle='Flat'
    $EnvironmentCombo.Add_DrawItem({
        param($sender,$eventArgs)
        if ($eventArgs.Index -lt 0 -or -not $script:LauncherThemeColors) { return }
        $colors=$script:LauncherThemeColors
        $selected=($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
        $background=if ($selected) { $colors.Selection } else { $colors.Input }
        $foreground=if ($selected) { $colors.SelectionText } else { $colors.Text }
        $brush=New-Object Drawing.SolidBrush($background)
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,[string]$sender.Items[$eventArgs.Index],$eventArgs.Font,$eventArgs.Bounds,$foreground,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        $eventArgs.DrawFocusRectangle()
    })
    $RecentList.OwnerDraw=$true
    $RecentList.Add_DrawColumnHeader({
        param($sender,$eventArgs)
        if (-not $script:LauncherThemeColors) { $eventArgs.DrawDefault=$true; return }
        $colors=$script:LauncherThemeColors
        $brush=New-Object Drawing.SolidBrush($colors.Header)
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
        $bounds=[Drawing.Rectangle]::Inflate($eventArgs.Bounds,-6,0)
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$eventArgs.Header.Text,$sender.Font,$bounds,$colors.Text,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
    })
    $RecentList.Add_DrawItem({
        param($sender,$eventArgs)
        if (-not $script:LauncherThemeColors) { $eventArgs.DrawDefault=$true; return }
        $colors=$script:LauncherThemeColors
        $background=if ($eventArgs.Item.Selected) { $colors.Selection } else { $colors.Input }
        $brush=New-Object Drawing.SolidBrush($background)
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
    })
    $RecentList.Add_DrawSubItem({
        param($sender,$eventArgs)
        if (-not $script:LauncherThemeColors) { $eventArgs.DrawDefault=$true; return }
        $colors=$script:LauncherThemeColors
        $selected=$eventArgs.Item.Selected
        $background=if ($selected) { $colors.Selection } else { $colors.Input }
        $foreground=if ($selected) { $colors.SelectionText } else { $colors.Text }
        $brush=New-Object Drawing.SolidBrush($background)
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
        $bounds=[Drawing.Rectangle]::Inflate($eventArgs.Bounds,-6,0)
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$eventArgs.SubItem.Text,$sender.Font,$bounds,$foreground,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
    })
}
