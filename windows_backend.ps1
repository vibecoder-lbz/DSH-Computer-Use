param([Parameter(Mandatory=$true)][string]$RequestPath, [Parameter(Mandatory=$true)][string]$ResponsePath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Emit($value) {
    $json = ConvertTo-Json -InputObject $value -Depth 20 -Compress
    [IO.File]::WriteAllText($ResponsePath, $json, [Text.UTF8Encoding]::new($false))
}
try {
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $p = $request.params
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DesktopNative {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct Mouse { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] public struct Union { [FieldOffset(0)] public Mouse mouse; }
 [StructLayout(LayoutKind.Sequential)] public struct Input { public uint type; public Union u; }
 [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, Input[] inputs, int size);
 public static void Click() {
   Input[] a=new Input[2]; a[0].u.mouse.flags=2; a[1].u.mouse.flags=4;
   if(SendInput(2,a,Marshal.SizeOf(typeof(Input)))!=2) throw new Exception("SendInput failed; check elevation and desktop session");
 }
}
'@
    [void][DesktopNative]::SetProcessDPIAware()
    function WindowRoot {
        if (!$p.hwnd -or ![DesktopNative]::IsWindow([IntPtr][long]$p.hwnd)) { throw 'Invalid window handle; call windows again' }
        return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$p.hwnd)
    }
    function WindowRect {
        $null = WindowRoot
        $r = New-Object DesktopNative+Rect
        if (![DesktopNative]::GetWindowRect([IntPtr][long]$p.hwnd, [ref]$r)) { throw 'Cannot read window rectangle' }
        if ([DesktopNative]::IsIconic([IntPtr][long]$p.hwnd)) { throw 'Window is minimized; restore it before screenshot/click' }
        return $r
    }
    function Matches($element, $selector) {
        $c = $element.Current
        if ($selector.ref -and (($element.GetRuntimeId() -join '.') -cne $selector.ref)) { return $false }
        if ($selector.name -and $c.Name -cne $selector.name) { return $false }
        if ($selector.automation_id -and $c.AutomationId -cne $selector.automation_id) { return $false }
        if ($selector.control_type -and $c.ControlType.ProgrammaticName -cne $selector.control_type) { return $false }
        return $true
    }
    function FindControls {
        $root = WindowRoot
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        $found = [Collections.Generic.List[object]]::new()
        if (Matches $root $p.selector) { $found.Add($root) }
        foreach ($el in $all) {
            try { if (Matches $el $p.selector) { $found.Add($el) } } catch [System.Windows.Automation.ElementNotAvailableException] {}
            if ($found.Count -gt 1) { break }
        }
        return ,$found
    }
    $result = switch ($request.action) {
        'apps' {
            $items = @{}
            foreach ($base in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                foreach ($app in @(Get-ItemProperty -Path $base -ErrorAction SilentlyContinue)) {
                    if (!$app.DisplayName) { continue }
                    if ($p.query -and $app.DisplayName.IndexOf($p.query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                    $key = "$($app.DisplayName)|$($app.DisplayVersion)|$($app.InstallLocation)"
                    $items[$key] = @{ name=$app.DisplayName; version=$app.DisplayVersion; publisher=$app.Publisher; install_location=$app.InstallLocation; display_icon=$app.DisplayIcon }
                }
            }
            $limit = 100; if ($p.limit) { $limit = $p.limit }
            $sorted = @($items.Values | Sort-Object { $_.name })
            @{ total=$sorted.Count; truncated=($sorted.Count -gt $limit); apps=@($sorted | Select-Object -First $limit); coverage='Uninstall registry entries; portable apps and some Store apps may be absent' }
        }
        'windows' {
            $children = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            $rows = @(); foreach ($el in $children) {
                try { $c=$el.Current; if ($c.NativeWindowHandle -ne 0 -and !$c.IsOffscreen) {
                    $rows += @{ hwnd=[long]$c.NativeWindowHandle; title=$c.Name; pid=$c.ProcessId; control_type=$c.ControlType.ProgrammaticName }
                } } catch [System.Windows.Automation.ElementNotAvailableException] {}
            }
            @{ windows=$rows }
        }
        'inspect' {
            $root = WindowRoot
            $limit=150; if ($p.limit) { $limit=$p.limit }
            $depth=5; if ($null -ne $p.depth) { $depth=$p.depth }
            $queue = [Collections.Generic.Queue[object]]::new()
            $queue.Enqueue(@{element=$root; depth=0; parent=$null})
            $rows=[Collections.Generic.List[object]]::new(); $depthLimited=$false
            $walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
            while ($queue.Count -gt 0 -and $rows.Count -lt $limit) {
                $entry=$queue.Dequeue(); $el=$entry.element
                try {
                    $c=$el.Current; $ref=$el.GetRuntimeId() -join '.'; $b=$c.BoundingRectangle
                    $patterns=@($el.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName })
                    $rows.Add(@{ref=$ref; parent=$entry.parent; depth=$entry.depth; name=$c.Name; automation_id=$c.AutomationId; control_type=$c.ControlType.ProgrammaticName; enabled=$c.IsEnabled; offscreen=$c.IsOffscreen; bounds=@{x=$b.X;y=$b.Y;width=$b.Width;height=$b.Height}; patterns=$patterns})
                    if ($entry.depth -ge $depth) { if ($null -ne $walker.GetFirstChild($el)) { $depthLimited=$true }; continue }
                    $child=$walker.GetFirstChild($el)
                    while ($null -ne $child) {
                        $queue.Enqueue(@{element=$child;depth=($entry.depth+1);parent=$ref})
                        if ($queue.Count -ge $limit) { $depthLimited=$true; break }
                        $child=$walker.GetNextSibling($child)
                    }
                } catch [System.Windows.Automation.ElementNotAvailableException] {}
            }
            @{hwnd=$p.hwnd; controls=@($rows.ToArray()); truncated=($queue.Count -gt 0 -or $depthLimited)}
        }
        'launch' {
            $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=$p.path; $info.Arguments=$p.arguments; $info.UseShellExecute=$false
            $proc=[Diagnostics.Process]::Start($info)
            @{pid=$proc.Id; path=$p.path; verification='Call windows and inspect to confirm the application is ready'}
        }
        { $_ -in 'invoke','set_value','select','wait' } {
            $timer=[Diagnostics.Stopwatch]::StartNew(); $timeout=1
            if ($request.action -eq 'wait') { $timeout=5000; if ($p.timeout_ms) { $timeout=$p.timeout_ms } }
            do {
                $matches=FindControls
                if ($matches.Count -gt 1) { throw 'Selector is ambiguous; use ref or more selector fields' }
                if ($matches.Count -eq 1) { break }
                if ($timer.ElapsedMilliseconds -ge $timeout) { throw 'No matching control; inspect the current window' }
                Start-Sleep -Milliseconds 150
            } while ($true)
            $el=$matches[0]
            $controlRef=$el.GetRuntimeId() -join '.'
            if ($request.action -ne 'wait' -and !$el.Current.IsEnabled) { throw 'Control is disabled' }
            switch ($request.action) {
                'invoke' { $pattern=$el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $pattern.Invoke() }
                'set_value' { $pattern=$el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); if ($pattern.Current.IsReadOnly) { throw 'Control is read-only' }; $pattern.SetValue($p.value) }
                'select' { $pattern=$el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern); $pattern.Select() }
            }
            @{action=$request.action; ref=$controlRef; verification='Re-inspect or take a screenshot to confirm the intended result'}
        }
        'click' {
            $r=WindowRect
            if ($p.x -ge ($r.Right-$r.Left) -or $p.y -ge ($r.Bottom-$r.Top)) { throw 'Coordinates are outside the window' }
            if ([DesktopNative]::GetForegroundWindow() -ne [IntPtr][long]$p.hwnd) {
                [void][DesktopNative]::SetForegroundWindow([IntPtr][long]$p.hwnd)
            }
            Start-Sleep -Milliseconds 100
            if ([DesktopNative]::GetForegroundWindow() -ne [IntPtr][long]$p.hwnd) { throw 'Window lost focus; click cancelled' }
            $r=WindowRect
            $sx=$r.Left+$p.x; $sy=$r.Top+$p.y
            if (![DesktopNative]::SetCursorPos($sx,$sy)) { throw 'Cannot move pointer' }
            [DesktopNative]::Click()
            @{clicked=$true; screen_x=$sx; screen_y=$sy; verification='Inspect or screenshot the result'}
        }
        'screenshot' {
            if ($p.hwnd) { $r=WindowRect; $x=$r.Left; $y=$r.Top; $w=$r.Right-$x; $h=$r.Bottom-$y }
            else { $x=[DesktopNative]::GetSystemMetrics(76); $y=[DesktopNative]::GetSystemMetrics(77); $w=[DesktopNative]::GetSystemMetrics(78); $h=[DesktopNative]::GetSystemMetrics(79) }
            if ($w -le 0 -or $h -le 0) { throw 'Invalid capture dimensions' }
            $bitmap=[Drawing.Bitmap]::new($w,$h); $graphics=[Drawing.Graphics]::FromImage($bitmap)
            try { $graphics.CopyFromScreen($x,$y,0,0,[Drawing.Size]::new($w,$h)); $bitmap.Save($p.path,[Drawing.Imaging.ImageFormat]::Png) }
            finally { $graphics.Dispose(); $bitmap.Dispose() }
            @{path=$p.path; width=$w; height=$h; screen_origin=@{x=$x;y=$y}; capture='Visible screen pixels; overlapping windows are included'}
        }
        'compare' {
            $a=[Drawing.Bitmap]::new($p.before); $b=$null
            try {
                $b=[Drawing.Bitmap]::new($p.after)
                if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) { throw 'Images must have the same dimensions' }
                $stride=4; if ($p.stride) { $stride=$p.stride }; $threshold=20; if ($null -ne $p.threshold) { $threshold=$p.threshold }
                $count=0; $changed=0
                for ($y=0; $y -lt $a.Height; $y+=$stride) { for ($x=0; $x -lt $a.Width; $x+=$stride) {
                    $ca=$a.GetPixel($x,$y); $cb=$b.GetPixel($x,$y)
                    $delta=[Math]::Max([Math]::Abs([int]$ca.R-[int]$cb.R),[Math]::Max([Math]::Abs([int]$ca.G-[int]$cb.G),[Math]::Abs([int]$ca.B-[int]$cb.B)))
                    if ($delta -gt $threshold) { $changed++ }; $count++
                } }
                @{changed_ratio=($changed/[double]$count); changed_samples=$changed; samples=$count; stride=$stride; threshold=$threshold; interpretation='Pixel changes only; verify task-specific text, controls, or screenshot content'}
            } finally { $a.Dispose(); if ($null -ne $b) { $b.Dispose() } }
        }
        default { throw 'Unknown backend action' }
    }
    Emit @{ok=$true; result=$result}
} catch {
    Emit @{ok=$false; error=$_.Exception.Message}
    exit 1
}
