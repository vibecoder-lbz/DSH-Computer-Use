param([Parameter(Mandatory=$true)][string]$RequestPath, [Parameter(Mandatory=$true)][string]$ResponsePath)
# One process per JSON request. The Host must impose a process timeout as UIA providers can hang.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script:clock=[Diagnostics.Stopwatch]::StartNew()
function Emit($value) { [IO.File]::WriteAllText($ResponsePath,(ConvertTo-Json -InputObject $value -Depth 22 -Compress),[Text.UTF8Encoding]::new($false)) }
function Budget { if ($script:clock.ElapsedMilliseconds -gt 35000) { throw 'Backend deadline exceeded; inspect actual state before retrying' } }
function Clip($value) { $text=[string]$value; if ($text.Length -gt 2000) { return $text.Substring(0,2000)+' [truncated]' }; return $text }
function IntRange($value,$default,$min,$max,$name) {
    if ($null -eq $value) { return $default }
    $number=0L
    if (![long]::TryParse([string]$value,[ref]$number) -or $number -lt $min -or $number -gt $max) { throw "$name must be an integer in [$min,$max]" }
    return [int]$number
}
try {
    $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $p=$request.params
    if (!$p) { $p=[pscustomobject]@{} }
    $action=[string]$request.action
    if ($action -eq 'foreground_act') {
        if ($p.operation -notin 'move','click','type','key','scroll','invoke','set_value','select') { throw 'Unsupported foreground operation' }
        $action=[string]$p.operation
    }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HybridNative {
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct Mouse { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] public struct Keyboard { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public Mouse mouse; [FieldOffset(0)] public Keyboard keyboard; }
 [StructLayout(LayoutKind.Sequential)] public struct Input { public uint type; public InputUnion u; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool attach);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point p);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flags);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr h,int index);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr h,uint msg,UIntPtr wp,string lp,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] data,int size);
 public static string ClassName(IntPtr h) { var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
 public static bool Pressed(int key) { return (GetAsyncKeyState(key)&0x8000)!=0; }
 public static bool Emergency() { return Pressed(0x11)&&Pressed(0x12)&&Pressed(0x1B); }
 public static bool Modifiers() { return Pressed(0x11)||Pressed(0x12)||Pressed(0x10)||Pressed(0x5B)||Pressed(0x5C); }
 static void Send(Input[] data) { if(SendInput((uint)data.Length,data,Marshal.SizeOf(typeof(Input)))!=data.Length) throw new Exception("SendInput failed; input state may be partial, inspect before retrying"); }
 static Input K(ushort key,bool up,bool unicode) { var a=new Input(); a.type=1; a.u.keyboard.vk=unicode?(ushort)0:key; a.u.keyboard.scan=unicode?key:(ushort)0; a.u.keyboard.flags=(uint)((up?2:0)|(unicode?4:0)); if(!unicode&&(key==0x21||key==0x22||key==0x23||key==0x24||key==0x25||key==0x26||key==0x27||key==0x28||key==0x2E)) a.u.keyboard.flags|=1; return a; }
 public static void Unicode(char value) { Send(new[]{K(value,false,true),K(value,true,true)}); }
 public static void Key(ushort key,bool ctrl) { if(ctrl) Send(new[]{K(0x11,false,false),K(key,false,false),K(key,true,false),K(0x11,true,false)}); else Send(new[]{K(key,false,false),K(key,true,false)}); }
 public static void MouseInput(string button,int delta,bool horizontal) {
   var a=new Input(); a.type=0;
   if(button=="wheel") { a.u.mouse.flags=horizontal?0x1000u:0x800u; a.u.mouse.data=unchecked((uint)delta); Send(new[]{a}); }
   else { uint down=button=="right"?8u:button=="middle"?32u:2u; var b=new Input(); a.u.mouse.flags=down; b.u.mouse.flags=down*2; Send(new[]{a,b}); }
 }
 public static long Message(IntPtr h,uint msg,string text) { UIntPtr result; if(SendMessageTimeout(h,msg,UIntPtr.Zero,text,0x22,1000,out result)==IntPtr.Zero) throw new Exception("Native control message failed/timed out; state may be unknown, inspect before retrying"); return unchecked((long)result.ToUInt64()); }
 public static void Focus(IntPtr h) {
   uint ignored; uint current=GetCurrentThreadId(); uint target=GetWindowThreadProcessId(h,out ignored); uint foreground=GetWindowThreadProcessId(GetForegroundWindow(),out ignored);
   bool a=false,b=false;
   try { if(foreground!=0&&foreground!=current) a=AttachThreadInput(current,foreground,true); if(target!=0&&target!=current&&target!=foreground) b=AttachThreadInput(current,target,true); if(IsIconic(h)) ShowWindow(h,9); SetForegroundWindow(h); }
   finally { if(b) AttachThreadInput(current,target,false); if(a) AttachThreadInput(current,foreground,false); }
 }
}
'@ | Out-Null
    [void][HybridNative]::SetProcessDPIAware()
    $foregroundBefore=[HybridNative]::GetForegroundWindow().ToInt64()
    $cursorBefore=New-Object HybridNative+Point
    [void][HybridNative]::GetCursorPos([ref]$cursorBefore)
    function Target {
        $id=0L
        if (![long]::TryParse([string]$p.hwnd,[ref]$id) -or $id -eq 0 -or ![HybridNative]::IsWindow([IntPtr]$id)) { throw 'Invalid hwnd; enumerate windows again' }
        return [IntPtr]$id
    }
    function Root { return [System.Windows.Automation.AutomationElement]::FromHandle((Target)) }
    function Bounds {
        $h=Target
        if ([HybridNative]::IsIconic($h)) { throw 'Window minimized; no implicit restore' }
        $r=New-Object HybridNative+Rect
        if (![HybridNative]::GetWindowRect($h,[ref]$r)) { throw 'Cannot read window bounds' }
        return $r
    }
    function Match($el,$selector) {
        $c=$el.Current
        if ($selector.ref -and ($el.GetRuntimeId() -join '.') -cne $selector.ref) { return $false }
        if ($selector.name -and $c.Name -cne $selector.name) { return $false }
        if ($selector.automation_id -and $c.AutomationId -cne $selector.automation_id) { return $false }
        if ($selector.control_type -and $c.ControlType.ProgrammaticName -cne $selector.control_type) { return $false }
        return $true
    }
    function FindOne {
        if (!$p.selector -or !@($p.selector.PSObject.Properties | Where-Object { $_.Name -in 'ref','name','automation_id','control_type' -and $_.Value }).Count) { throw 'Nonempty selector required (ref/name/automation_id/control_type)' }
        foreach ($field in $p.selector.PSObject.Properties) { if ($field.Name -notin 'ref','name','automation_id','control_type' -or ![string]$field.Value) { throw 'Invalid or empty selector field' } }
        $q=[Collections.Generic.Queue[object]]::new(); $q.Enqueue((Root)); $found=$null; $seen=0
        $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
        while ($q.Count -gt 0) {
            Budget
            if (++$seen -gt 5000) { throw 'Selector search exceeds 5000 controls; narrow the target window' }
            $el=$q.Dequeue()
            try {
                if (Match $el $p.selector) { if ($null -ne $found) { throw 'Selector ambiguous; use an exact ref' }; $found=$el }
                $child=$walker.GetFirstChild($el)
                while ($null -ne $child) { $q.Enqueue($child); if ($q.Count -gt 5000) { throw 'Control tree exceeds bounded search' }; $child=$walker.GetNextSibling($child) }
            } catch [System.Windows.Automation.ElementNotAvailableException] {}
        }
        return $found
    }
    function Capability($el,$operation) {
        if ($operation -notin 'invoke','set_value','select') { throw 'operation must be invoke, set_value or select' }
        $c=$el.Current; $native=[IntPtr][long]$c.NativeWindowHandle
        $patterns=@($el.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName })
        $class=''; if ($native -ne [IntPtr]::Zero) { $class=[HybridNative]::ClassName($native) }
        $supported=$false; $reason='No guaranteed background adapter; UIA writes may change focus'
        $method=$null
        if ($native -ne [IntPtr]::Zero -and [HybridNative]::GetAncestor($native,2) -ne [HybridNative]::GetAncestor((Target),2)) { $reason='Native control is outside the target window' }
        elseif (!$c.IsEnabled) { $reason='Control disabled' }
        elseif ($operation -eq 'set_value' -and $class -ceq 'Edit' -and (([HybridNative]::GetWindowLong($native,-16) -band 0x800) -eq 0)) { $supported=$true; $method='WM_SETTEXT'; $reason='Standard Win32 Edit message adapter (no UIA write or focus request)' }
        elseif ($operation -eq 'invoke' -and $class -ceq 'Button' -and (([HybridNative]::GetWindowLong($native,-16) -band 0xF) -in 0,1)) { $supported=$true; $method='BM_CLICK'; $reason='Standard Win32 push-button message adapter; application handler may open windows' }
        return @{supported=$supported; reason=$reason; takeover_required=(!$supported); operation=$operation; method=$method; native_hwnd=$native.ToInt64(); class_name=$class; patterns=$patterns; ref=($el.GetRuntimeId() -join '.')}
    }
    function StopPath { return [IO.Path]::Combine([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$p.statePath)),'stop') }
    function StopNow($reason) {
        if ($p.statePath) { try { [IO.File]::WriteAllText((StopPath),$reason,[Text.UTF8Encoding]::new($false)) } catch {} }
        throw $reason
    }
    function Lease([bool]$requireForeground=$true,[bool]$keyboard=$false) {
        Budget
        if (!$p.statePath -or ![IO.Path]::IsPathRooted([string]$p.statePath)) { throw 'An absolute statePath lease is required' }
        if (Test-Path -LiteralPath (StopPath)) { throw 'Takeover stopped: stop file exists' }
        if ([HybridNative]::Emergency()) { StopNow 'Emergency Ctrl+Alt+Esc pressed' }
        $state=Get-Content -LiteralPath $p.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.active -isnot [bool] -or $state.active -ne $true -or [long]$state.hwnd -ne (Target).ToInt64()) { throw 'Inactive or wrong-target lease' }
        $expiry=0L
        if (![long]::TryParse([string]$state.expiresAt,[ref]$expiry)) { $expiry=[DateTimeOffset]::Parse([string]$state.expiresAt).ToUnixTimeMilliseconds() }
        if ($expiry -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { StopNow 'Takeover lease expired' }
        if ($requireForeground -and [HybridNative]::GetForegroundWindow() -ne (Target)) { StopNow 'Foreground window changed; takeover stopped' }
        if ($keyboard -and [HybridNative]::Modifiers()) { StopNow 'User modifier key is held; keyboard input cancelled' }
        return $state
    }
    function Trail($point) {
        # Re-read before each atomic write; preserve Host fields and bound the trail.
        $state=Lease $true $false
        $entries=@($state.trail | Where-Object { $null -ne $_ }) + @(@{x=$point.X;y=$point.Y;t=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()})
        $entries=@($entries | Select-Object -Last 100)
        if ($state.PSObject.Properties['trail']) { $state.trail=$entries } else { $state | Add-Member -NotePropertyName trail -NotePropertyValue $entries }
        $destination=[IO.Path]::GetFullPath([string]$p.statePath)
        $temporary=$destination+'.native-'+[Guid]::NewGuid().ToString('N')+'.tmp'
        try {
            [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $state -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
            $null=Lease $true $false
            [IO.File]::Replace($temporary,$destination,$destination+'.bak')
            [IO.File]::Delete($destination+'.bak')
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    function Position {
        $point=New-Object HybridNative+Point
        if (![HybridNative]::GetCursorPos([ref]$point)) { throw 'Cannot read pointer' }
        return $point
    }
    function CheckPointer($expected) {
        $actual=Position
        if ([Math]::Abs($actual.X-$expected.X) -gt 8 -or [Math]::Abs($actual.Y-$expected.Y) -gt 8) { StopNow 'Pointer moved externally; takeover stopped without restoring pointer' }
    }
    function HitTarget($point) {
        if ([HybridNative]::GetAncestor([HybridNative]::WindowFromPoint($point),2) -ne [HybridNative]::GetAncestor((Target),2)) { StopNow 'Target point covered by another window/overlay; input cancelled' }
    }
    function SmoothMove {
        $null=Lease $true $false
        $r=Bounds
        $x=IntRange $p.x $null 0 ($r.Right-$r.Left-1) 'x'; $y=IntRange $p.y $null 0 ($r.Bottom-$r.Top-1) 'y'
        if ($null -eq $p.x -or $null -eq $p.y) { throw 'x and y required' }
        $start=Position; $last=$start
        for ($step=1; $step -le 20; $step++) {
            $null=Lease $true $false
            CheckPointer $last
            $currentBounds=Bounds
            if ($currentBounds.Left -ne $r.Left -or $currentBounds.Top -ne $r.Top -or $currentBounds.Right -ne $r.Right -or $currentBounds.Bottom -ne $r.Bottom) { StopNow 'Target window moved or resized; inspect before retrying' }
            $next=New-Object HybridNative+Point
            $next.X=[int][Math]::Round($start.X+(($r.Left+$x-$start.X)*$step/20.0)); $next.Y=[int][Math]::Round($start.Y+(($r.Top+$y-$start.Y)*$step/20.0))
            if (![HybridNative]::SetCursorPos($next.X,$next.Y)) { throw 'Cannot move pointer' }
            $last=$next; Trail $next
            Start-Sleep -Milliseconds 15
        }
        $null=Lease $true $false; CheckPointer $last
        return $last
    }
    $result=switch ($action) {
        'apps' {
            $limit=IntRange $p.limit 100 1 500 'limit'; $items=@{}
            foreach ($base in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                foreach ($app in @(Get-ItemProperty -Path $base -ErrorAction SilentlyContinue)) {
                    Budget
                    if (!$app.DisplayName -or ($p.query -and $app.DisplayName.IndexOf([string]$p.query,[StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
                    $items["$($app.DisplayName)|$($app.DisplayVersion)|$($app.InstallLocation)"]=@{name=(Clip $app.DisplayName);version=(Clip $app.DisplayVersion);publisher=(Clip $app.Publisher);install_location=(Clip $app.InstallLocation);display_icon=(Clip $app.DisplayIcon)}
                }
            }
            @{total=$items.Count;truncated=($items.Count -gt $limit);apps=@($items.Values | Sort-Object {$_.name} | Select-Object -First $limit);coverage='Uninstall registry; some portable/Store apps absent'}
        }
        'windows' {
            $limit=IntRange $p.limit 100 1 500 'limit'
            $children=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
            $rows=@();$truncated=$false
            foreach ($el in $children) { Budget; try { $c=$el.Current; if ($c.NativeWindowHandle -ne 0) { if ($rows.Count -ge $limit) {$truncated=$true;break}; $rows+=@{hwnd=[long]$c.NativeWindowHandle;title=(Clip $c.Name);pid=$c.ProcessId;control_type=$c.ControlType.ProgrammaticName;offscreen=$c.IsOffscreen;minimized=[HybridNative]::IsIconic([IntPtr]$c.NativeWindowHandle)} } } catch [System.Windows.Automation.ElementNotAvailableException] {} }
            @{windows=$rows;truncated=$truncated}
        }
        'inspect' {
            $limit=IntRange $p.limit 150 1 500 'limit';$depth=IntRange $p.depth 5 0 12 'depth'
            $q=[Collections.Generic.Queue[object]]::new();$q.Enqueue(@{element=(Root);depth=0;parent=$null})
            $rows=[Collections.Generic.List[object]]::new();$truncated=$false;$walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
            while ($q.Count -gt 0 -and $rows.Count -lt $limit) {
                Budget;$entry=$q.Dequeue();$el=$entry.element
                try {
                    $c=$el.Current;$ref=$el.GetRuntimeId() -join '.';$b=$c.BoundingRectangle
                    $bounds=$null;if (!$b.IsEmpty) {$bounds=@{x=$b.X;y=$b.Y;width=$b.Width;height=$b.Height}}
                    $rows.Add(@{ref=$ref;parent=$entry.parent;depth=$entry.depth;name=(Clip $c.Name);automation_id=(Clip $c.AutomationId);control_type=$c.ControlType.ProgrammaticName;enabled=$c.IsEnabled;offscreen=$c.IsOffscreen;native_hwnd=[long]$c.NativeWindowHandle;class_name=$c.ClassName;bounds=$bounds;patterns=@($el.GetSupportedPatterns() | ForEach-Object {$_.ProgrammaticName})})
                    $child=$walker.GetFirstChild($el)
                    if ($entry.depth -ge $depth) {if ($null -ne $child) {$truncated=$true};continue}
                    while ($null -ne $child) {Budget;$q.Enqueue(@{element=$child;depth=$entry.depth+1;parent=$ref});if ($q.Count -ge $limit) {$truncated=$true;break};$child=$walker.GetNextSibling($child)}
                } catch [System.Windows.Automation.ElementNotAvailableException] {}
            }
            @{hwnd=$p.hwnd;controls=@($rows.ToArray());truncated=($truncated -or $q.Count -gt 0)}
        }
        'wait' {
            $timeout=IntRange $p.timeout_ms 5000 1 30000 'timeout_ms';$timer=[Diagnostics.Stopwatch]::StartNew();$el=$null
            do { Budget;$el=FindOne;if ($null -ne $el) {break};if ($timer.ElapsedMilliseconds -ge $timeout) {throw 'Timed out waiting for control'};Start-Sleep -Milliseconds 150 } while ($true)
            @{ref=($el.GetRuntimeId() -join '.');found=$true}
        }
        {$_ -in 'probe','background_act'} {
            if ($p.operation -notin 'invoke','set_value','select') {
                if ($p.operation -notin 'move','click','type','key','scroll') {throw 'Unsupported operation'}
                @{supported=$false;executed=$false;takeover_required=$true;reason='This operation requires an explicit foreground takeover';patterns=@();operation=$p.operation}
                break
            }
            $el=FindOne
            if ($null -eq $el) { @{supported=$false;takeover_required=$true;reason='No matching control';patterns=@();operation=$p.operation} }
            else {
                $cap=Capability $el $p.operation
                if ($request.action -eq 'background_act' -and $cap.supported) {
                    if ($p.operation -eq 'set_value') {
                        if ($null -eq $p.value -or ([string]$p.value).Length -gt 2000 -or ([string]$p.value).Contains([char]0)) {throw 'value must be a string of at most 2000 UTF-16 code units without NUL'}
                        $messageResult=[HybridNative]::Message([IntPtr][long]$cap.native_hwnd,12,[string]$p.value)
                        if ($messageResult -eq 0) {throw 'WM_SETTEXT rejected by control'}
                    } else { $null=[HybridNative]::Message([IntPtr][long]$cap.native_hwnd,245,$null) }
                    $cap.executed=$true;$cap.verification='Inspect target controls/screenshot; message delivery is not business success'
                } else { $cap.executed=$false }
                $cap
            }
        }
        'screenshot' {
            $mode='background';if ($p.mode) {$mode=[string]$p.mode};if ($mode -notin 'background','foreground') {throw 'mode must be background or foreground'}
            if (!$p.path -or ![IO.Path]::IsPathRooted([string]$p.path) -or [IO.Path]::GetExtension([string]$p.path) -ine '.png') {throw 'Absolute .png path required'}
            $r=Bounds;$w=$r.Right-$r.Left;$h=$r.Bottom-$r.Top
            if ($w -le 0 -or $h -le 0 -or [long]$w*$h -gt 40000000) {throw 'Invalid or excessive capture dimensions (maximum 40 million pixels)'}
            $bitmap=[Drawing.Bitmap]::new($w,$h);$g=[Drawing.Graphics]::FromImage($bitmap);$dc=[IntPtr]::Zero
            try {
                if ($mode -eq 'background') {$dc=$g.GetHdc();$painted=[HybridNative]::PrintWindow((Target),$dc,2);$g.ReleaseHdc($dc);$dc=[IntPtr]::Zero;if (!$painted) {throw 'PrintWindow failed; no foreground fallback'}}
                else {$g.CopyFromScreen($r.Left,$r.Top,0,0,[Drawing.Size]::new($w,$h))}
                $bitmap.Save([string]$p.path,[Drawing.Imaging.ImageFormat]::Png)
            } finally {if ($dc -ne [IntPtr]::Zero) {$g.ReleaseHdc($dc)};$g.Dispose();$bitmap.Dispose()}
            @{path=$p.path;width=$w;height=$h;screen_origin=@{x=$r.Left;y=$r.Top};mode=$mode;capture='Background may be blank/stale for GPU apps; foreground includes overlapping windows; inspect image'}
        }
        'compare' {
            $stride=IntRange $p.stride 4 1 32 'stride';$threshold=IntRange $p.threshold 20 0 255 'threshold'
            $a=[Drawing.Bitmap]::new([string]$p.before);$b=$null
            try {
                $b=[Drawing.Bitmap]::new([string]$p.after)
                if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {throw 'Images must have identical dimensions'}
                if ([long][Math]::Ceiling($a.Width/[double]$stride)*[long][Math]::Ceiling($a.Height/[double]$stride) -gt 2000000) {throw 'More than 2 million samples; increase stride'}
                $count=0;$changed=0
                for ($y=0;$y -lt $a.Height;$y+=$stride) {Budget;for ($x=0;$x -lt $a.Width;$x+=$stride) {$ca=$a.GetPixel($x,$y);$cb=$b.GetPixel($x,$y);$delta=[Math]::Max([Math]::Abs([int]$ca.R-[int]$cb.R),[Math]::Max([Math]::Abs([int]$ca.G-[int]$cb.G),[Math]::Abs([int]$ca.B-[int]$cb.B)));if ($delta -gt $threshold) {$changed++};$count++}}
                @{changed_ratio=$changed/[double]$count;changed_samples=$changed;samples=$count;stride=$stride;threshold=$threshold;interpretation='Pixel changes do not establish task success'}
            } finally {$a.Dispose();if ($null -ne $b) {$b.Dispose()}}
        }
        'prepare' {
            $null=Lease $false $true
            [HybridNative]::Focus((Target))
            $null=Lease $true $true
            @{prepared=$true;hwnd=$p.hwnd;note='Restored/focused without changing topmost; user input remains unblocked'}
        }
        {$_ -in 'invoke','set_value','select'} {
            $null=Lease $true $true
            $el=FindOne
            if ($null -eq $el) {throw 'No matching control'}
            if (!$el.Current.IsEnabled) {throw 'Control disabled'}
            $ref=$el.GetRuntimeId() -join '.'
            if ($action -eq 'set_value' -and ($null -eq $p.value -or ([string]$p.value).Length -gt 2000 -or ([string]$p.value).Contains([char]0))) {throw 'value required; maximum 2000 UTF-16 code units, no NUL'}
            $null=Lease $true $true
            switch ($action) {
                'invoke' {$pattern=$el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern);$null=Lease $true $true;$pattern.Invoke()}
                'set_value' {$pattern=$el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern);if ($pattern.Current.IsReadOnly) {throw 'Control read-only'};$null=Lease $true $true;$pattern.SetValue([string]$p.value)}
                'select' {$pattern=$el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);$null=Lease $true $true;$pattern.Select()}
            }
            @{executed=$true;operation=$action;ref=$ref;verification='Foreground UIA action; inspect actual result'}
        }
        {$_ -in 'move','click','type','key','scroll'} {
            $null=Lease $true ($action -in 'type','key')
            switch ($action) {
                'move' {$point=SmoothMove;@{moved=$true;x=$point.X;y=$point.Y}}
                'click' {
                    $button='left';if ($p.button) {$button=[string]$p.button};if ($button -notin 'left','right','middle') {throw 'button must be left/right/middle'}
                    $point=SmoothMove;$null=Lease $true $false;CheckPointer $point;HitTarget $point
                    [HybridNative]::MouseInput($button,0,$false)
                    @{clicked=$true;screen_x=$point.X;screen_y=$point.Y;button=$button}
                }
                'type' {
                    if ($null -eq $p.text -or ([string]$p.text).Length -gt 2000 -or ([string]$p.text).Contains([char]0)) {throw 'text required; maximum 2000 UTF-16 code units, no NUL'}
                    $anchor=Position;$text=[string]$p.text
                    for ($i=0;$i -lt $text.Length;$i++) {$null=Lease $true $true;CheckPointer $anchor;[HybridNative]::Unicode($text[$i])}
                    @{typed_code_units=$text.Length;verification='Re-inspect input before sending/submitting'}
                }
                'key' {
                    $keys=@{Enter=13;Tab=9;Escape=27;Backspace=8;Delete=46;ArrowLeft=37;Left=37;ArrowUp=38;Up=38;ArrowRight=39;Right=39;ArrowDown=40;Down=40;Home=36;End=35;PageUp=33;PageDown=34;'Ctrl+A'=65;'Ctrl+C'=67;'Ctrl+V'=86;'Ctrl+S'=83}
                    $name=[string]$p.key;if (!$keys.ContainsKey($name)) {throw 'Unsupported key; use Enter/Tab/Escape/Backspace/Delete/arrows/Home/End/PageUp/PageDown or Ctrl+A/C/V/S'}
                    $null=Lease $true $true
                    [HybridNative]::Key([ushort]$keys[$name],$name.StartsWith('Ctrl+',[StringComparison]::OrdinalIgnoreCase))
                    @{key=$name;sent=$true}
                }
                'scroll' {
                    $delta=IntRange $p.delta 0 -1200 1200 'delta';if ($delta -eq 0) {throw 'Nonzero delta required (wheel units, 120 per notch)'}
                    $point=Position;$null=Lease $true $false;HitTarget $point
                    [HybridNative]::MouseInput('wheel',$delta,($p.horizontal -eq $true))
                    @{scrolled=$true;delta=$delta;horizontal=($p.horizontal -eq $true)}
                }
            }
        }
        default { throw 'Unknown action; expected apps/windows/inspect/wait/compare/screenshot/probe/background_act/prepare/move/click/type/key/scroll' }
    }
    $cursorAfter=Position
    $result.background_observation=@{foreground_unchanged=($foregroundBefore -eq [HybridNative]::GetForegroundWindow().ToInt64());cursor_unchanged=($cursorBefore.X -eq $cursorAfter.X -and $cursorBefore.Y -eq $cursorAfter.Y);note='Observation only; user/application activity can also change focus or pointer'}
    Emit @{ok=$true;result=$result}
} catch {
    Emit @{ok=$false;error=$_.Exception.Message}
    exit 1
}
