param([string]$ReadyPath, [string]$ResultPath)
# Test-only classic Win32 (WinForms) window. It is never launched by the plugin itself.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object Windows.Forms.Form
$form.Text = 'Background input fixture'
$form.Width = 520
$form.Height = 260
$form.StartPosition = 'Manual'
$form.Left = 120
$form.Top = 120
$form.ShowInTaskbar = $false
$text = New-Object Windows.Forms.TextBox
$text.Left = 20
$text.Top = 20
$text.Width = 440
$text.Text = ''
$text.add_TextChanged({ [IO.File]::WriteAllText($ResultPath, $text.Text) })
$button = New-Object Windows.Forms.Button
$button.Text = 'Verify'
$button.Left = 20
$button.Top = 70
$button.Width = 120
$button.add_Click({ [IO.File]::WriteAllText("$ResultPath.button", 'clicked') })
$form.Controls.Add($text)
$form.Controls.Add($button)
$form.Show()
[IO.File]::WriteAllText($ReadyPath, [string]$form.Handle)
[Windows.Forms.Application]::Run($form)
