$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$form = [System.Windows.Forms.Form]::new()
$form.Text = 'LifeNarrator OCR image fixture'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [System.Drawing.Size]::new(1000, 650)
$image = [System.Drawing.Bitmap]::new(1000, 650)
$graphics = [System.Drawing.Graphics]::FromImage($image)
$font = [System.Drawing.Font]::new('Segoe UI', 26)
try {
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.DrawString('LifeNarrator visible English paragraph', $font, [System.Drawing.Brushes]::Black, 70, 180)
    $graphics.DrawString('Only pixels are drawn in this window.', $font, [System.Drawing.Brushes]::Black, 70, 260)
    $graphics.DrawString('No accessibility text is provided.', $font, [System.Drawing.Brushes]::Black, 70, 340)
} finally { $graphics.Dispose(); $font.Dispose() }
$form.BackgroundImage = $image
try { [System.Windows.Forms.Application]::Run($form) }
finally { $image.Dispose(); $form.Dispose() }
