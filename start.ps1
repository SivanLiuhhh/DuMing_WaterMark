$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

Add-Type @"
using System.Runtime.InteropServices;
public class DPIHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[DPIHelper]::SetProcessDPIAware() | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$APP_TITLE = "渡明水印工具 V1.0.0"

# ---------- 依赖检查 ----------
$depsOk = $false
try {
    py -3 -c "import PIL" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $depsOk = $true }
} catch { }
if (-not $depsOk) {
    py -3 -m pip install --quiet --disable-pip-version-check --no-warn-script-location -r requirements.txt
    if ($LASTEXITCODE -ne 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "依赖安装失败，请检查网络或手动运行：`npy -3 -m pip install -r requirements.txt",
            "启动失败", "OK", "Error") | Out-Null
        exit 1
    }
}

$fontNormal = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontBold   = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$fontButton = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
$fontSmall  = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$fontMono   = New-Object System.Drawing.Font("Consolas", 10)

$script:selectedPaths = [System.Collections.ArrayList]::new()
$script:settings = $null
$script:tmpShadowColor = "#000000"

if ($args.Count -ge 1) {
    foreach ($a in $args) {
        if (Test-Path -LiteralPath $a) {
            [void]$script:selectedPaths.Add((Resolve-Path -LiteralPath $a).Path)
        }
    }
}

function Get-FirstImageRatio {
    foreach ($p in $script:selectedPaths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            try {
                $img = [System.Drawing.Image]::FromFile($p)
                $r = [double]$img.Width / [double]$img.Height
                $img.Dispose()
                return $r
            } catch { }
        } elseif (Test-Path -LiteralPath $p -PathType Container) {
            $first = Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|tif|tiff)$' } |
                Select-Object -First 1
            if ($null -ne $first) {
                try {
                    $img = [System.Drawing.Image]::FromFile($first.FullName)
                    $r = [double]$img.Width / [double]$img.Height
                    $img.Dispose()
                    return $r
                } catch { }
            }
        }
    }
    return 1.5
}

# 关键修复：函数内所有 void 方法用 [void] 抑制输出，返回用 ,$path 保证单个对象
function Get-RoundedPath($x, $y, $w, $h, $r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Min($r, [Math]::Min($w, $h) / 2)
    if ($r -le 0.5) {
        [void]$path.AddRectangle([System.Drawing.RectangleF]::new($x, $y, $w, $h))
        return ,$path
    }
    $d = $r * 2
    [void]$path.AddArc($x, $y, $d, $d, 180, 90)
    [void]$path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    [void]$path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    [void]$path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    [void]$path.CloseFigure()
    return ,$path
}

function Render-Preview {
    param(
        $graphics, $panelSize,
        [double]$canvasRatio, [double]$imgRatio,
        [double]$imgScale, [double]$imgOffsetY,
        [bool]$roundedOn, [double]$radiusRatio,
        [bool]$shadowOn, [string]$shadowColorHex, [double]$shadowOpacity
    )

    $g = $graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)

    $pw = $panelSize.Width
    $ph = $panelSize.Height
    $margin = 12
    $availW = $pw - $margin * 2
    $availH = $ph - $margin * 2
    if ($availW -le 10 -or $availH -le 10) { return }

    if ($availW / $availH -gt $canvasRatio) {
        $canvasH = $availH
        $canvasW = $canvasH * $canvasRatio
    } else {
        $canvasW = $availW
        $canvasH = $canvasW / $canvasRatio
    }
    $canvasX = ($pw - $canvasW) / 2
    $canvasY = ($ph - $canvasH) / 2

    if ($canvasRatio -ge $imgRatio) {
        $imgH = $canvasH
        $imgW = $imgH * $imgRatio
    } else {
        $imgW = $canvasW
        $imgH = $imgW / $imgRatio
    }
    $imgW *= $imgScale
    $imgH *= $imgScale
    $imgX = $canvasX + ($canvasW - $imgW) / 2
    $imgY = $canvasY + ($canvasH - $imgH) / 2 + $canvasH * $imgOffsetY

    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 235, 235))
    $bgPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 150, 150), 1)
    $g.FillRectangle($bgBrush, $canvasX, $canvasY, $canvasW, $canvasH)
    $g.DrawRectangle($bgPen, $canvasX, $canvasY, $canvasW, $canvasH)

    $imgRect    = New-Object System.Drawing.RectangleF($imgX, $imgY, $imgW, $imgH)
    $canvasRect = New-Object System.Drawing.RectangleF($canvasX, $canvasY, $canvasW, $canvasH)
    $clip = [System.Drawing.RectangleF]::Intersect($imgRect, $canvasRect)

    $imgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 160, 230))
    $imgPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 110, 200), 2)

    if ($clip.Width -gt 0 -and $clip.Height -gt 0) {
        if ($shadowOn) {
            try {
                $sColor = [System.Drawing.ColorTranslator]::FromHtml($shadowColorHex)
                $sAlpha = [int](255 * $shadowOpacity)
                $sPen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::FromArgb($sAlpha, $sColor), 6)
                $g.DrawRectangle($sPen, $clip.X - 2, $clip.Y - 2, $clip.Width + 4, $clip.Height + 4)
                $sPen.Dispose()
            } catch { }
        }

        $inCanvas = ($imgW -le $canvasW + 1) -and ($imgH -le $canvasH + 1) -and
                    ($imgX -ge $canvasX - 1) -and ($imgY -ge $canvasY - 1)

        if ($roundedOn -and $inCanvas) {
            $previewRadius = [Math]::Min($imgW, $imgH) * $radiusRatio
            $path = Get-RoundedPath $clip.X $clip.Y $clip.Width $clip.Height $previewRadius
            try {
                $g.FillPath($imgBrush, $path)
                $g.DrawPath($imgPen, $path)
            } finally {
                $path.Dispose()
            }
        } else {
            $g.FillRectangle($imgBrush, $clip.X, $clip.Y, $clip.Width, $clip.Height)
            $g.DrawRectangle($imgPen, $clip.X, $clip.Y, $clip.Width, $clip.Height)
        }
    }

    $outOfBounds = ($imgW -gt $canvasW + 1) -or ($imgH -gt $canvasH + 1) -or
                   ($imgX -lt $canvasX - 1) -or ($imgY -lt $canvasY - 1)
    if ($outOfBounds) {
        $dashPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 80, 80), 1)
        $dashPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $g.DrawRectangle($dashPen, $imgX, $imgY, $imgW, $imgH)
        $dashPen.Dispose()
    }

    $bgBrush.Dispose(); $bgPen.Dispose()
    $imgBrush.Dispose(); $imgPen.Dispose()
}

$SETTINGS_FILE = Join-Path $PSScriptRoot "ui_settings.json"

function Load-Settings {
    $defaults = @{
        ratio = "16:9"
        watermark_position = "bottom"
        font_size_ratio = 0.030
        blur = 60
        image_scale = 1.0
        image_offset_y = 0.0
        use_watermark_template = $false
        watermark_template = "{camera}`n{focal} | {shutter} | {aperture} | {iso}"
        rounded_corners = $false
        rounded_radius_ratio = 0.02
        shadow_enabled = $false
        shadow_color = "#000000"
        shadow_opacity = 0.40
        shadow_blur_ratio = 0.015
        custom_camera_enabled = $false
        custom_camera = ""
        include_camera = $true
        include_focal_length = $false
        include_shutter = $true
        include_aperture = $true
        include_iso = $true
    }

    if (Test-Path -LiteralPath $SETTINGS_FILE) {
        try {
            $loaded = Get-Content -LiteralPath $SETTINGS_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($defaults.Keys)) {
                if ($null -ne $loaded.PSObject.Properties[$k]) {
                    $defaults[$k] = $loaded.$k
                }
            }
        } catch { }
    }

    try { $defaults.font_size_ratio = [Math]::Min(0.100, [Math]::Max(0.010, [double]$defaults.font_size_ratio)) }
    catch { $defaults.font_size_ratio = 0.030 }
    try { $defaults.blur = [Math]::Min(200, [Math]::Max(0, [int]$defaults.blur)) }
    catch { $defaults.blur = 60 }
    try { $defaults.image_scale = [Math]::Min(2.0, [Math]::Max(0.3, [double]$defaults.image_scale)) }
    catch { $defaults.image_scale = 1.0 }
    try { $defaults.image_offset_y = [Math]::Min(0.9, [Math]::Max(-0.9, [double]$defaults.image_offset_y)) }
    catch { $defaults.image_offset_y = 0.0 }
    try { $defaults.rounded_radius_ratio = [Math]::Min(0.15, [Math]::Max(0.001, [double]$defaults.rounded_radius_ratio)) }
    catch { $defaults.rounded_radius_ratio = 0.02 }
    try { $defaults.shadow_opacity = [Math]::Min(1.0, [Math]::Max(0.0, [double]$defaults.shadow_opacity)) }
    catch { $defaults.shadow_opacity = 0.40 }
    try { $defaults.shadow_blur_ratio = [Math]::Min(0.03, [Math]::Max(0.005, [double]$defaults.shadow_blur_ratio)) }
    catch { $defaults.shadow_blur_ratio = 0.015 }

    if ($defaults.watermark_position -notin @("bottom", "top", "center")) {
        $defaults.watermark_position = "bottom"
    }
    if ($defaults.ratio -notin @("16:9", "4:3", "3:2", "1:1", "4:5", "9:16", "3:4", "2:3")) {
        $defaults.ratio = "16:9"
    }
    if (-not ($defaults.shadow_color -match '^#[0-9A-Fa-f]{6}$')) {
        $defaults.shadow_color = "#000000"
    }

    $defaults.use_watermark_template = [bool]$defaults.use_watermark_template
    $defaults.watermark_template = [string]$defaults.watermark_template
    $defaults.rounded_corners = [bool]$defaults.rounded_corners
    $defaults.shadow_enabled = [bool]$defaults.shadow_enabled
    $defaults.custom_camera_enabled = [bool]$defaults.custom_camera_enabled
    $defaults.custom_camera = [string]$defaults.custom_camera
    $defaults.include_camera       = [bool]$defaults.include_camera
    $defaults.include_focal_length = [bool]$defaults.include_focal_length
    $defaults.include_shutter      = [bool]$defaults.include_shutter
    $defaults.include_aperture     = [bool]$defaults.include_aperture
    $defaults.include_iso          = [bool]$defaults.include_iso

    return $defaults
}

function Save-Settings($s) {
    try {
        $json = $s | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($SETTINGS_FILE, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Show-ConfigForm($s) {
    $prevRatio       = $s.ratio
    $prevPosMap      = @{ bottom = "底部"; top = "顶部"; center = "居中" }
    $prevPos         = $prevPosMap[$s.watermark_position]
    if (-not $prevPos) { $prevPos = "底部" }
    $prevFontSize    = [double]$s.font_size_ratio
    $prevBlur        = [int]$s.blur
    $prevScalePct    = [int]([Math]::Round([double]$s.image_scale * 100))
    $prevOffsetPct   = [int]([Math]::Round([double]$s.image_offset_y * 100))
    $prevCustom      = [string]$s.custom_camera
    $prevCustomOn    = [bool]$s.custom_camera_enabled
    $prevChkCam      = [bool]$s.include_camera
    $prevChkFocal    = [bool]$s.include_focal_length
    $prevChkShutter  = [bool]$s.include_shutter
    $prevChkAper     = [bool]$s.include_aperture
    $prevChkIso      = [bool]$s.include_iso
    $prevUseTpl      = [bool]$s.use_watermark_template
    $prevTpl         = [string]$s.watermark_template
    $prevRounded     = [bool]$s.rounded_corners
    $prevRadiusVal   = [int]([Math]::Round([double]$s.rounded_radius_ratio * 1000))
    $prevRadiusVal   = [Math]::Max(5, [Math]::Min(80, $prevRadiusVal))
    $prevShadowOn    = [bool]$s.shadow_enabled
    $prevShadowColor = [string]$s.shadow_color
    $prevOpacityVal  = [int]([Math]::Round([double]$s.shadow_opacity * 100))
    $prevOpacityVal  = [Math]::Max(10, [Math]::Min(90, $prevOpacityVal))
    $prevShadowBlur  = [int]([Math]::Round([double]$s.shadow_blur_ratio * 1000))
    $prevShadowBlur  = [Math]::Max(5, [Math]::Min(30, $prevShadowBlur))

    $script:tmpShadowColor = $prevShadowColor

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $APP_TITLE
    $form.ClientSize = New-Object System.Drawing.Size(1100, 1400)
    $form.MinimumSize = New-Object System.Drawing.Size(1080, 1240)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MaximizeBox = $true
    $form.MinimizeBox = $true
    $form.BackColor = [System.Drawing.Color]::White
    $form.Font = $fontNormal
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.Padding = New-Object System.Windows.Forms.Padding(10)

    $groupX = 20
    $groupW = 840
    $innerX = 15
    $innerW = $groupW - $innerX * 2

    # ============ 输出设置 ============
    $grpOutput = New-Object System.Windows.Forms.GroupBox
    $grpOutput.Text = "输出设置"
    $grpOutput.Location = New-Object System.Drawing.Point($groupX, 20)
    $grpOutput.Size = New-Object System.Drawing.Size($groupW, 195)
    $grpOutput.Anchor = "Top, Left"
    $grpOutput.Font = $fontBold
    $form.Controls.Add($grpOutput)

    $flowRow1 = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowRow1.Location = New-Object System.Drawing.Point($innerX, 48)
    $flowRow1.Size = New-Object System.Drawing.Size($innerW, 46)
    $flowRow1.FlowDirection = "LeftToRight"
    $flowRow1.WrapContents = $false
    $grpOutput.Controls.Add($flowRow1)

    function New-FlowLabel([string]$text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.AutoSize = $true
        $l.Font = $fontNormal
        $l.Margin = New-Object System.Windows.Forms.Padding(0, 12, 8, 0)
        return $l
    }
    function New-FlowCombo([int]$width) {
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = "DropDownList"
        $c.Width = $width
        $c.Font = $fontNormal
        $c.Margin = New-Object System.Windows.Forms.Padding(0, 8, 30, 0)
        return $c
    }

    $flowRow1.Controls.Add((New-FlowLabel "比例:"))
    $cmbRatio = New-FlowCombo 130
    foreach ($r in @("16:9", "4:3", "3:2", "1:1", "4:5", "9:16", "3:4", "2:3")) {
        [void]$cmbRatio.Items.Add($r)
    }
    if ($cmbRatio.Items.Contains($prevRatio)) { $cmbRatio.SelectedItem = $prevRatio }
    else { $cmbRatio.SelectedIndex = 0 }
    $flowRow1.Controls.Add($cmbRatio)

    $flowRow1.Controls.Add((New-FlowLabel "位置:"))
    $cmbPos = New-FlowCombo 110
    foreach ($p in @("底部", "顶部", "居中")) { [void]$cmbPos.Items.Add($p) }
    if ($cmbPos.Items.Contains($prevPos)) { $cmbPos.SelectedItem = $prevPos }
    else { $cmbPos.SelectedIndex = 0 }
    $flowRow1.Controls.Add($cmbPos)

    $flowRow1.Controls.Add((New-FlowLabel "字号:"))
    $numFont = New-Object System.Windows.Forms.NumericUpDown
    $numFont.Minimum = 0.010
    $numFont.Maximum = 0.100
    $numFont.Increment = 0.005
    $numFont.DecimalPlaces = 3
    $numFont.Value = [decimal]$prevFontSize
    $numFont.Width = 90
    $numFont.Font = $fontNormal
    $numFont.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $flowRow1.Controls.Add($numFont)

    $lblBlur = New-Object System.Windows.Forms.Label
    $lblBlur.Text = "模糊:"
    $lblBlur.Location = New-Object System.Drawing.Point(20, 142)
    $lblBlur.AutoSize = $true
    $lblBlur.Font = $fontNormal
    $grpOutput.Controls.Add($lblBlur)

    $trkBlur = New-Object System.Windows.Forms.TrackBar
    $trkBlur.TickStyle = [System.Windows.Forms.TickStyle]::None
    $trkBlur.Height = 28
    $trkBlur.Minimum = 0
    $trkBlur.Maximum = 200
    $trkBlur.Value = $prevBlur
    $trkBlur.TickFrequency = 20
    $trkBlur.Location = New-Object System.Drawing.Point(90, 135)
    $trkBlur.Size = New-Object System.Drawing.Size(($innerW - 140), 28)
    $grpOutput.Controls.Add($trkBlur)

    $lblBlurValue = New-Object System.Windows.Forms.Label
    $lblBlurValue.Text = "$($trkBlur.Value)"
    $lblBlurValue.Location = New-Object System.Drawing.Point(($groupW - 100), 142)
    $lblBlurValue.Size = New-Object System.Drawing.Size(80, 28)
    $lblBlurValue.TextAlign = "MiddleRight"
    $lblBlurValue.Font = $fontNormal
    $grpOutput.Controls.Add($lblBlurValue)

    $trkBlur.Add_Scroll({ $lblBlurValue.Text = "$($trkBlur.Value)" })

    # ============ 照片效果（圆角 + 阴影 + 阴影面积） ============
    $grpEffects = New-Object System.Windows.Forms.GroupBox
    $grpEffects.Text = "照片效果"
    $grpEffects.Location = New-Object System.Drawing.Point($groupX, 230)
    $grpEffects.Size = New-Object System.Drawing.Size($groupW, 280)
    $grpEffects.Anchor = "Top, Left"
    $grpEffects.Font = $fontBold
    $form.Controls.Add($grpEffects)

    # --- 圆角行 ---
    $chkRounded = New-Object System.Windows.Forms.CheckBox
    $chkRounded.Text = "照片圆角"
    $chkRounded.Location = New-Object System.Drawing.Point(20, 52)
    $chkRounded.AutoSize = $true
    $chkRounded.Checked = $prevRounded
    $chkRounded.Font = $fontNormal
    $grpEffects.Controls.Add($chkRounded)

    $lblRadiusTitle = New-Object System.Windows.Forms.Label
    $lblRadiusTitle.Text = "半径:"
    $lblRadiusTitle.Location = New-Object System.Drawing.Point(180, 54)
    $lblRadiusTitle.AutoSize = $true
    $lblRadiusTitle.Font = $fontNormal
    $grpEffects.Controls.Add($lblRadiusTitle)

    $trkRadius = New-Object System.Windows.Forms.TrackBar
    $trkRadius.TickStyle = [System.Windows.Forms.TickStyle]::None
    $trkRadius.Height = 28
    $trkRadius.Minimum = 5
    $trkRadius.Maximum = 80
    $trkRadius.Value = $prevRadiusVal
    $trkRadius.TickFrequency = 5
    $trkRadius.Location = New-Object System.Drawing.Point(230, 46)
    $trkRadius.Size = New-Object System.Drawing.Size(500, 36)
    $grpEffects.Controls.Add($trkRadius)

    $lblRadiusValue = New-Object System.Windows.Forms.Label
    $lblRadiusValue.Text = ("{0:F1}%" -f ($trkRadius.Value / 10.0))
    $lblRadiusValue.Location = New-Object System.Drawing.Point(740, 54)
    $lblRadiusValue.Size = New-Object System.Drawing.Size(80, 28)
    $lblRadiusValue.TextAlign = "MiddleRight"
    $lblRadiusValue.Font = $fontNormal
    $grpEffects.Controls.Add($lblRadiusValue)

    $trkRadius.Add_Scroll({
        $lblRadiusValue.Text = ("{0:F1}%" -f ($trkRadius.Value / 10.0))
        $panelPreview.Invalidate()
    })

    # --- 阴影行 ---
    $chkShadow = New-Object System.Windows.Forms.CheckBox
    $chkShadow.Text = "照片阴影"
    $chkShadow.Location = New-Object System.Drawing.Point(20, 140)
    $chkShadow.AutoSize = $true
    $chkShadow.Checked = $prevShadowOn
    $chkShadow.Font = $fontNormal
    $grpEffects.Controls.Add($chkShadow)

    $lblShadowColorTitle = New-Object System.Windows.Forms.Label
    $lblShadowColorTitle.Text = "颜色:"
    $lblShadowColorTitle.Location = New-Object System.Drawing.Point(180, 142)
    $lblShadowColorTitle.AutoSize = $true
    $lblShadowColorTitle.Font = $fontNormal
    $grpEffects.Controls.Add($lblShadowColorTitle)

    $panelColorSwatch = New-Object System.Windows.Forms.Panel
    $panelColorSwatch.Location = New-Object System.Drawing.Point(255, 137)
    $panelColorSwatch.Size = New-Object System.Drawing.Size(40, 60)
    $panelColorSwatch.BorderStyle = "FixedSingle"
    try {
        $panelColorSwatch.BackColor = [System.Drawing.ColorTranslator]::FromHtml($prevShadowColor)
    } catch {
        $panelColorSwatch.BackColor = [System.Drawing.Color]::Black
    }
    $grpEffects.Controls.Add($panelColorSwatch)

    $btnPickColor = New-Object System.Windows.Forms.Button
    $btnPickColor.Text = "选择..."
    $btnPickColor.Location = New-Object System.Drawing.Point(286, 137)
    $btnPickColor.Size = New-Object System.Drawing.Size(95, 60)
    $btnPickColor.Font = $fontNormal
    $grpEffects.Controls.Add($btnPickColor)

    $btnPickColor.Add_Click({
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        try {
            $dlg.Color = [System.Drawing.ColorTranslator]::FromHtml($script:tmpShadowColor)
        } catch {
            $dlg.Color = [System.Drawing.Color]::Black
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:tmpShadowColor = "#{0:X2}{1:X2}{2:X2}" -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
            $panelColorSwatch.BackColor = $dlg.Color
            $panelPreview.Invalidate()
        }
    })

    $lblOpacityTitle = New-Object System.Windows.Forms.Label
    $lblOpacityTitle.Text = "不透明度:"
    $lblOpacityTitle.Location = New-Object System.Drawing.Point(380, 142)
    $lblOpacityTitle.AutoSize = $true
    $lblOpacityTitle.Font = $fontNormal
    $grpEffects.Controls.Add($lblOpacityTitle)

    $trkOpacity = New-Object System.Windows.Forms.TrackBar
    $trkOpacity.TickStyle = [System.Windows.Forms.TickStyle]::None
    $trkOpacity.Height = 28
    $trkOpacity.Minimum = 10
    $trkOpacity.Maximum = 90
    $trkOpacity.Value = $prevOpacityVal
    $trkOpacity.TickFrequency = 10
    $trkOpacity.Location = New-Object System.Drawing.Point(480, 133)
    $trkOpacity.Size = New-Object System.Drawing.Size(250, 36)
    $grpEffects.Controls.Add($trkOpacity)

    $lblOpacityValue = New-Object System.Windows.Forms.Label
    $lblOpacityValue.Text = "$($trkOpacity.Value)%"
    $lblOpacityValue.Location = New-Object System.Drawing.Point(740, 142)
    $lblOpacityValue.Size = New-Object System.Drawing.Size(80, 28)
    $lblOpacityValue.TextAlign = "MiddleRight"
    $lblOpacityValue.Font = $fontNormal
    $grpEffects.Controls.Add($lblOpacityValue)

    $trkOpacity.Add_Scroll({
        $lblOpacityValue.Text = "$($trkOpacity.Value)%"
        $panelPreview.Invalidate()
    })

    # --- 阴影面积行 ---
    $lblShadowBlurTitle = New-Object System.Windows.Forms.Label
    $lblShadowBlurTitle.Text = "阴影面积:"
    $lblShadowBlurTitle.Location = New-Object System.Drawing.Point(20, 227)
    $lblShadowBlurTitle.AutoSize = $true
    $lblShadowBlurTitle.Font = $fontNormal
    $grpEffects.Controls.Add($lblShadowBlurTitle)

    $trkShadowBlur = New-Object System.Windows.Forms.TrackBar
    $trkShadowBlur.TickStyle = [System.Windows.Forms.TickStyle]::None
    $trkShadowBlur.Height = 28
    $trkShadowBlur.Minimum = 5
    $trkShadowBlur.Maximum = 30
    $trkShadowBlur.Value = $prevShadowBlur
    $trkShadowBlur.TickFrequency = 5
    $trkShadowBlur.Location = New-Object System.Drawing.Point(110, 220)
    $trkShadowBlur.Size = New-Object System.Drawing.Size(620, 36)
    $grpEffects.Controls.Add($trkShadowBlur)

    $lblShadowBlurValue = New-Object System.Windows.Forms.Label
    $lblShadowBlurValue.Text = ("{0:F1}%" -f ($trkShadowBlur.Value / 10.0))
    $lblShadowBlurValue.Location = New-Object System.Drawing.Point(740, 227)
    $lblShadowBlurValue.Size = New-Object System.Drawing.Size(80, 28)
    $lblShadowBlurValue.TextAlign = "MiddleRight"
    $lblShadowBlurValue.Font = $fontNormal
    $grpEffects.Controls.Add($lblShadowBlurValue)

    $trkShadowBlur.Add_Scroll({
        $lblShadowBlurValue.Text = ("{0:F1}%" -f ($trkShadowBlur.Value / 10.0))
        $panelPreview.Invalidate()
    })

    # ============ 预览区（Y偏移远离 TrackBar 实际渲染底边） ============
    $previewX = 860
    $previewW = 260

    $grpPreview = New-Object System.Windows.Forms.GroupBox
    $grpPreview.Text = "预览"
    $grpPreview.Location = New-Object System.Drawing.Point($previewX, 20)
    $grpPreview.Size = New-Object System.Drawing.Size($previewW, 850)
    $grpPreview.Anchor = "Top, Right"
    $grpPreview.Font = $fontBold
    $form.Controls.Add($grpPreview)

    # Panel 底边 = 48 + 500 = 548
    $panelPreview = New-Object System.Windows.Forms.Panel
    $panelPreview.Location = New-Object System.Drawing.Point(12, 48)
    $panelPreview.Size = New-Object System.Drawing.Size(($previewW - 24), 500)
    $panelPreview.BackColor = [System.Drawing.Color]::White
    $panelPreview.BorderStyle = "FixedSingle"
    $panelPreview.Anchor = "Top, Left, Right"
    $grpPreview.Controls.Add($panelPreview)

    # ===== 图片大小 =====
    $lblScaleCaption = New-Object System.Windows.Forms.Label
    $lblScaleCaption.Text = "图片大小:"
    $lblScaleCaption.AutoSize = $true
    $lblScaleCaption.Font = $fontNormal
    $lblScaleCaption.Location = New-Object System.Drawing.Point(12, 562)
    $lblScaleCaption.Anchor = "Top, Left"
    $grpPreview.Controls.Add($lblScaleCaption)

    $lblScaleValue = New-Object System.Windows.Forms.Label
    $lblScaleValue.Text = "$prevScalePct%"
    $lblScaleValue.Size = New-Object System.Drawing.Size(110, 28)
    $lblScaleValue.TextAlign = "MiddleRight"
    $lblScaleValue.Font = $fontNormal
    $lblScaleValue.Location = New-Object System.Drawing.Point(($previewW - 125), 562)
    $lblScaleValue.Anchor = "Top, Right"
    $grpPreview.Controls.Add($lblScaleValue)

    # 图片大小 滑块 Y=606，实际渲染底边 = 606 + 45 = 651
    $trkScale = New-Object System.Windows.Forms.TrackBar
    $trkScale.TickStyle = [System.Windows.Forms.TickStyle]::None
    $trkScale.Minimum = 30
    $trkScale.Maximum = 200
    $trkScale.Value = [Math]::Min(200, [Math]::Max(30, $prevScalePct))
    $trkScale.TickFrequency = 20
    $trkScale.Location = New-Object System.Drawing.Point(12, 606)
    $trkScale.Size = New-Object System.Drawing.Size(($previewW - 24), 28)
    $trkScale.Anchor = "Top, Left, Right"
    $grpPreview.Controls.Add($trkScale)

    # ===== Y 偏移（Y=720，距 trkScale 实际底边 651 有 69px 缓冲） =====
    $lblOffsetCaption = New-Object System.Windows.Forms.Label
    $lblOffsetCaption.Text = "Y 偏移:"
    $lblOffsetCaption.AutoSize = $true
    $lblOffsetCaption.Font = $fontNormal
    $lblOffsetCaption.Location = New-Object System.Drawing.Point(12, 720)
    $lblOffsetCaption.Anchor = "Top, Left"
    $grpPreview.Controls.Add($lblOffsetCaption)

    $lblOffsetValue = New-Object System.Windows.Forms.Label
    $lblOffsetValue.Text = "$prevOffsetPct%"
    $lblOffsetValue.Size = New-Object System.Drawing.Size(110, 28)
    $lblOffsetValue.TextAlign = "MiddleRight"
    $lblOffsetValue.Font = $fontNormal
    $lblOffsetValue.Location = New-Object System.Drawing.Point(($previewW - 125), 720)
    $lblOffsetValue.Anchor = "Top, Right"
    $grpPreview.Controls.Add($lblOffsetValue)

    # Y 偏移 滑块 Y=764，实际渲染底边 = 764 + 45 = 809 < Group 850 ✓
    $trkOffset = New-Object System.Windows.Forms.TrackBar
    $trkOffset.TickStyle = [System.Windows.Forms.TickStyle]::None
    $trkOffset.Minimum = -90
    $trkOffset.Maximum = 90
    $trkOffset.Value = [Math]::Min(90, [Math]::Max(-90, $prevOffsetPct))
    $trkOffset.TickFrequency = 10
    $trkOffset.Location = New-Object System.Drawing.Point(12, 764)
    $trkOffset.Size = New-Object System.Drawing.Size(($previewW - 24), 28)
    $trkOffset.Anchor = "Top, Left, Right"
    $grpPreview.Controls.Add($trkOffset)

    $panelPreview.Add_Paint({
        param($sender, $e)
        try {
            if ($null -eq $cmbRatio.SelectedItem) { return }
            $ratioParts = $cmbRatio.SelectedItem.Split(':')
            $canvasRatio = [double]$ratioParts[0] / [double]$ratioParts[1]
            $imgRatio = Get-FirstImageRatio
            $imgScale = $trkScale.Value / 100.0
            $imgOffsetY = $trkOffset.Value / 100.0
            $radiusRatio = $trkRadius.Value / 1000.0
            $shadowOpacity = $trkOpacity.Value / 100.0
            Render-Preview $e.Graphics $sender.ClientSize `
                $canvasRatio $imgRatio $imgScale $imgOffsetY `
                $chkRounded.Checked $radiusRatio `
                $chkShadow.Checked $script:tmpShadowColor $shadowOpacity
        } catch { }
    })

    $cmbRatio.Add_SelectedIndexChanged({ $panelPreview.Invalidate() })
    $trkScale.Add_Scroll({
        $lblScaleValue.Text = "$($trkScale.Value)%"
        $panelPreview.Invalidate()
    })
    $trkOffset.Add_Scroll({
        $lblOffsetValue.Text = "$($trkOffset.Value)%"
        $panelPreview.Invalidate()
    })
    $chkRounded.Add_CheckedChanged({ $panelPreview.Invalidate() })
    $chkShadow.Add_CheckedChanged({ $panelPreview.Invalidate() })

    # ============ 相机信息 ============
    $grpCamera = New-Object System.Windows.Forms.GroupBox
    $grpCamera.Text = "相机信息"
    $grpCamera.Location = New-Object System.Drawing.Point($groupX, 525)
    $grpCamera.Size = New-Object System.Drawing.Size($groupW, 150)
    $grpCamera.Anchor = "Top, Left"
    $grpCamera.Font = $fontBold
    $form.Controls.Add($grpCamera)

    $chkCustomCamera = New-Object System.Windows.Forms.CheckBox
    $chkCustomCamera.Text = "自定义相机型号（勾选后覆盖 EXIF 中的 Make / Model）"
    $chkCustomCamera.Location = New-Object System.Drawing.Point(20, 52)
    $chkCustomCamera.AutoSize = $true
    $chkCustomCamera.Checked = $prevCustomOn
    $chkCustomCamera.Font = $fontNormal
    $grpCamera.Controls.Add($chkCustomCamera)

    $txtCustomCamera = New-Object System.Windows.Forms.TextBox
    $txtCustomCamera.Location = New-Object System.Drawing.Point(20, 92)
    $txtCustomCamera.Size = New-Object System.Drawing.Size(($groupW - 40), 32)
    $txtCustomCamera.Font = $fontNormal
    $txtCustomCamera.Text = $prevCustom
    $txtCustomCamera.Enabled = $prevCustomOn
    $grpCamera.Controls.Add($txtCustomCamera)

    $chkCustomCamera.Add_CheckedChanged({
        $txtCustomCamera.Enabled = $chkCustomCamera.Checked
        if ($chkCustomCamera.Checked) { $txtCustomCamera.Focus(); $txtCustomCamera.SelectAll() }
    })

    # ============ 水印显示内容 ============
    $grpContent = New-Object System.Windows.Forms.GroupBox
    $grpContent.Text = "水印显示内容"
    $grpContent.Location = New-Object System.Drawing.Point($groupX, 690)
    $grpContent.Size = New-Object System.Drawing.Size($groupW, 255)
    $grpContent.Anchor = "Top, Left"
    $grpContent.Font = $fontBold
    $form.Controls.Add($grpContent)

    $tblContent = New-Object System.Windows.Forms.TableLayoutPanel
    $tblContent.Location = New-Object System.Drawing.Point($innerX, 50)
    $tblContent.Size = New-Object System.Drawing.Size($innerW, 46)
    $tblContent.ColumnCount = 5
    $tblContent.RowCount = 1
    $tblContent.RowStyles.Clear()
    $tblContent.ColumnStyles.Clear()
    [void]$tblContent.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute, 46)))
    foreach ($i in 0..4) {
        [void]$tblContent.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
            [System.Windows.Forms.SizeType]::Percent, 20)))
    }
    $grpContent.Controls.Add($tblContent)

    function Add-CellCheckBox($tbl, [int]$col, [string]$text, [bool]$checked) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $text
        $cb.AutoSize = $true
        $cb.Checked = $checked
        $cb.Font = $fontNormal
        $cb.Anchor = "Left"
        $cb.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
        $tbl.Controls.Add($cb, $col, 0)
        return $cb
    }

    $chkCamera   = Add-CellCheckBox $tblContent 0 "相机"  $prevChkCam
    $chkFocal    = Add-CellCheckBox $tblContent 1 "焦距"  $prevChkFocal
    $chkShutter  = Add-CellCheckBox $tblContent 2 "快门"  $prevChkShutter
    $chkAperture = Add-CellCheckBox $tblContent 3 "光圈"  $prevChkAper
    $chkIso      = Add-CellCheckBox $tblContent 4 "ISO"   $prevChkIso

    $chkUseTemplate = New-Object System.Windows.Forms.CheckBox
    $chkUseTemplate.Text = "使用自定义模板（下方内容覆盖上方勾选）"
    $chkUseTemplate.Location = New-Object System.Drawing.Point(20, 105)
    $chkUseTemplate.AutoSize = $true
    $chkUseTemplate.Checked = $prevUseTpl
    $chkUseTemplate.Font = $fontNormal
    $grpContent.Controls.Add($chkUseTemplate)

    $txtTemplate = New-Object System.Windows.Forms.TextBox
    $txtTemplate.Location = New-Object System.Drawing.Point(20, 140)
    $txtTemplate.Size = New-Object System.Drawing.Size(($groupW - 40), 70)
    $txtTemplate.Multiline = $true
    $txtTemplate.AcceptsReturn = $true
    $txtTemplate.ScrollBars = "Vertical"
    $txtTemplate.Font = $fontMono
    $txtTemplate.Text = $prevTpl
    $txtTemplate.Enabled = $prevUseTpl
    $grpContent.Controls.Add($txtTemplate)

    $lblTplHint = New-Object System.Windows.Forms.Label
    $lblTplHint.Text = "占位符: {camera} {focal} {shutter} {aperture} {iso}   直接回车换行"
    $lblTplHint.AutoSize = $true
    $lblTplHint.ForeColor = [System.Drawing.Color]::Gray
    $lblTplHint.Font = $fontSmall
    $lblTplHint.Location = New-Object System.Drawing.Point(20, 218)
    $grpContent.Controls.Add($lblTplHint)

    $chkUseTemplate.Add_CheckedChanged({ $txtTemplate.Enabled = $chkUseTemplate.Checked })

    # ============ 处理对象 ============
    $grpTarget = New-Object System.Windows.Forms.GroupBox
    $grpTarget.Text = "处理对象（$($script:selectedPaths.Count) 个，双击列表项可移除）"
    $grpTarget.Location = New-Object System.Drawing.Point($groupX, 960)
    $grpTarget.Size = New-Object System.Drawing.Size($groupW, 340)
    $grpTarget.Anchor = "Top, Bottom, Left"
    $grpTarget.Font = $fontBold
    $form.Controls.Add($grpTarget)

    $lstTargets = New-Object System.Windows.Forms.ListBox
    $lstTargets.Location = New-Object System.Drawing.Point(20, 52)
    $lstTargets.Size = New-Object System.Drawing.Size(($groupW - 40), 190)
    $lstTargets.HorizontalScrollbar = $true
    $lstTargets.Font = $fontNormal
    $lstTargets.Anchor = "Top, Bottom, Left, Right"
    $grpTarget.Controls.Add($lstTargets)

    $btnChooseFiles = New-Object System.Windows.Forms.Button
    $btnChooseFiles.Text = "选择文件..."
    $btnChooseFiles.Location = New-Object System.Drawing.Point(20, 262)
    $btnChooseFiles.Size = New-Object System.Drawing.Size(170, 44)
    $btnChooseFiles.Font = $fontNormal
    $btnChooseFiles.Anchor = "Bottom, Left"
    $grpTarget.Controls.Add($btnChooseFiles)

    $btnChooseFolder = New-Object System.Windows.Forms.Button
    $btnChooseFolder.Text = "选择文件夹..."
    $btnChooseFolder.Location = New-Object System.Drawing.Point(200, 262)
    $btnChooseFolder.Size = New-Object System.Drawing.Size(170, 44)
    $btnChooseFolder.Font = $fontNormal
    $btnChooseFolder.Anchor = "Bottom, Left"
    $grpTarget.Controls.Add($btnChooseFolder)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "清空列表"
    $btnClear.Location = New-Object System.Drawing.Point(380, 262)
    $btnClear.Size = New-Object System.Drawing.Size(170, 44)
    $btnClear.Font = $fontNormal
    $btnClear.Anchor = "Bottom, Left"
    $grpTarget.Controls.Add($btnClear)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "（双击列表项可移除）"
    $lblHint.AutoSize = $true
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $lblHint.Font = $fontNormal
    $lblHint.Anchor = "Bottom, Right"
    $lblHint.Location = New-Object System.Drawing.Point(($groupW - 170), 275)
    $grpTarget.Controls.Add($lblHint)

    function Update-TargetsList {
        $lstTargets.BeginUpdate()
        $lstTargets.Items.Clear()
        foreach ($t in $script:selectedPaths) { [void]$lstTargets.Items.Add($t) }
        $lstTargets.EndUpdate()
        $grpTarget.Text = "处理对象（$($script:selectedPaths.Count) 个，双击列表项可移除）"
        $panelPreview.Invalidate()
    }
    Update-TargetsList

    $btnChooseFiles.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "选择要处理的照片（可多选）"
        $dlg.Filter = "图片文件|*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.heic;*.heif|所有文件|*.*"
        $dlg.InitialDirectory = $PSScriptRoot
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($f in $dlg.FileNames) {
                if (-not $script:selectedPaths.Contains($f)) { [void]$script:selectedPaths.Add($f) }
            }
            Update-TargetsList
        }
    })

    $btnChooseFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "请选择要批量处理的照片文件夹"
        $dlg.SelectedPath = $PSScriptRoot
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (-not $script:selectedPaths.Contains($dlg.SelectedPath)) {
                [void]$script:selectedPaths.Add($dlg.SelectedPath)
            }
            Update-TargetsList
        }
    })

    $btnClear.Add_Click({ $script:selectedPaths.Clear(); Update-TargetsList })

    $lstTargets.Add_DoubleClick({
        if ($lstTargets.SelectedIndex -ge 0) {
            $script:selectedPaths.RemoveAt($lstTargets.SelectedIndex)
            Update-TargetsList
        }
    })

    # ============ 底部按钮 ============
    $flowBottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowBottom.Location = New-Object System.Drawing.Point($groupX, 1320)
    $flowBottom.Size = New-Object System.Drawing.Size($groupW, 56)
    $flowBottom.FlowDirection = "RightToLeft"
    $flowBottom.WrapContents = $false
    $flowBottom.Anchor = "Bottom, Left"
    $form.Controls.Add($flowBottom)

    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = "开始处理"
    $btnStart.AutoSize = $true
    $btnStart.AutoSizeMode = "GrowAndShrink"
    $btnStart.MinimumSize = New-Object System.Drawing.Size(150, 48)
    $btnStart.Padding = New-Object System.Windows.Forms.Padding(20, 0, 20, 0)
    $btnStart.Font = $fontButton
    $btnStart.FlatStyle = "Flat"
    $btnStart.FlatAppearance.BorderSize = 0
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.UseVisualStyleBackColor = $false
    $btnStart.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $btnStart.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $flowBottom.Controls.Add($btnStart)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "退出"
    $btnCancel.AutoSize = $true
    $btnCancel.AutoSizeMode = "GrowAndShrink"
    $btnCancel.MinimumSize = New-Object System.Drawing.Size(110, 48)
    $btnCancel.Padding = New-Object System.Windows.Forms.Padding(15, 0, 15, 0)
    $btnCancel.Font = $fontNormal
    $btnCancel.FlatStyle = "Flat"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $flowBottom.Controls.Add($btnCancel)

    $form.AcceptButton = $btnStart
    $form.CancelButton = $btnCancel

    $form.Add_Load({
        $lblHint.Location = New-Object System.Drawing.Point(
            ($grpTarget.ClientSize.Width - $lblHint.Width - 20), 275)
    })

    $dialogResult = $form.ShowDialog()

    if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
        $form.Dispose()
        return $null
    }
    if ($script:selectedPaths.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("请先添加要处理的文件或文件夹。", "提示", "OK", "Information") | Out-Null
        $form.Dispose()
        return $null
    }

    $ratioParts = $cmbRatio.SelectedItem.Split(':')
    $positionMap = @{ "底部" = "bottom"; "顶部" = "top"; "居中" = "center" }
    $chosenPos = $positionMap[$cmbPos.SelectedItem]
    $customOn = [bool]$chkCustomCamera.Checked
    $useTpl = [bool]$chkUseTemplate.Checked

    $newSettings = @{
        ratio = $cmbRatio.SelectedItem
        watermark_position = $chosenPos
        font_size_ratio = [double]$numFont.Value
        blur = [int]$trkBlur.Value
        image_scale = [double]$trkScale.Value / 100.0
        image_offset_y = [double]$trkOffset.Value / 100.0
        use_watermark_template = $useTpl
        watermark_template = $txtTemplate.Text
        rounded_corners = [bool]$chkRounded.Checked
        rounded_radius_ratio = [double]$trkRadius.Value / 1000.0
        shadow_enabled = [bool]$chkShadow.Checked
        shadow_color = $script:tmpShadowColor
        shadow_opacity = [double]$trkOpacity.Value / 100.0
        shadow_blur_ratio = [double]$trkShadowBlur.Value / 1000.0
        custom_camera_enabled = $customOn
        custom_camera = if ($customOn) { $txtCustomCamera.Text.Trim() } else { "" }
        include_camera = [bool]$chkCamera.Checked
        include_focal_length = [bool]$chkFocal.Checked
        include_shutter = [bool]$chkShutter.Checked
        include_aperture = [bool]$chkAperture.Checked
        include_iso = [bool]$chkIso.Checked
    }

    $pythonCfg = [ordered]@{
        outputs = @($script:selectedPaths)
        ratio_w = [int]$ratioParts[0]
        ratio_h = [int]$ratioParts[1]
        blur = $newSettings.blur
        image_scale = $newSettings.image_scale
        image_offset_y = $newSettings.image_offset_y
        watermark_position = $newSettings.watermark_position
        font_size_ratio = $newSettings.font_size_ratio
        use_watermark_template = $newSettings.use_watermark_template
        watermark_template = $newSettings.watermark_template
        rounded_corners = $newSettings.rounded_corners
        rounded_radius_ratio = $newSettings.rounded_radius_ratio
        shadow_enabled = $newSettings.shadow_enabled
        shadow_color = $newSettings.shadow_color
        shadow_opacity = $newSettings.shadow_opacity
        shadow_blur_ratio = $newSettings.shadow_blur_ratio
        custom_camera = $newSettings.custom_camera
        include_camera = $newSettings.include_camera
        include_focal_length = $newSettings.include_focal_length
        include_shutter = $newSettings.include_shutter
        include_aperture = $newSettings.include_aperture
        include_iso = $newSettings.include_iso
    }

    $form.Dispose()
    return @{ settings = $newSettings; python = $pythonCfg }
}

$script:settings = Load-Settings

while ($true) {
    $r = Show-ConfigForm $script:settings

    if ($null -eq $r) { break }

    $script:settings = $r.settings
    Save-Settings $script:settings

    $configPath = Join-Path $PSScriptRoot "run_config.json"
    $json = $r.python | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    $cmdLine = "py -3 photo_batch_tool.py --config `"$configPath`" & echo. & echo === 处理结束 === & pause"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmdLine -PassThru -Wait

    if ($proc.ExitCode -eq 0) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "本批处理完成！`n`n是否继续处理下一批？",
            "完成", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { break }
    } else {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "处理过程中出现错误（退出码 $($proc.ExitCode)）。`n`n是否返回配置界面重试？",
            "错误", "YesNo", "Error")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { break }
    }
}