param([string]$ReadyPath,[string]$ResultPath)
Add-Type -AssemblyName PresentationFramework
$f=New-Object Windows.Window
$f.Title='DSH desktop control test'; $f.Width=640; $f.Height=420
$f.WindowStyle='None'; $f.ShowActivated=$false
$f.Left=0; $f.Top=0; $f.Width=[Windows.SystemParameters]::PrimaryScreenWidth; $f.Height=[Windows.SystemParameters]::PrimaryScreenHeight
$p=New-Object Windows.Controls.StackPanel
$p.Margin='40'
$label=New-Object Windows.Controls.TextBlock
$label.Text='Background first. Visible control when needed.'; $label.FontSize=20; $label.Margin='0,0,0,24'
$t=New-Object Windows.Controls.TextBox
$t.Name='TestInput'; $t.Height=40; $t.FontSize=18
$b=New-Object Windows.Controls.Button
$b.Content='Verify control'; $b.Height=44; $b.Margin='0,24,0,0'
$b.Add_Click({ [IO.File]::WriteAllText($ResultPath,$t.Text) })
$null=$p.Children.Add($label); $null=$p.Children.Add($t); $null=$p.Children.Add($b)
$f.Content=$p
$f.Add_SourceInitialized({ $handle=([Windows.Interop.WindowInteropHelper]::new($f)).Handle; [IO.File]::WriteAllText($ReadyPath,[string]$handle) })
$null=$f.ShowDialog()
