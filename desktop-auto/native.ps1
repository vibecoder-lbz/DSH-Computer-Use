param(
    [string]$RequestPath,
    [string]$ResponsePath,
    [string]$WorkerDir,
    [switch]$CheckSyntax
)
# One compiled worker can serve many requests. A single-shot mode is kept for tests.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:rememberedRect = $null

$script:csharp = @'
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
 [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo { public int cbSize; public uint flags; public IntPtr active,focus,capture,menuOwner,moveSize,caret; public Rect caretRect; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
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
 [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h,ref Point p);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid,ref GuiThreadInfo info);
 [DllImport("user32.dll")] public static extern IntPtr RealChildWindowFromPoint(IntPtr parent,Point p);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr h,int index);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint msg,UIntPtr wp,string lp,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",ExactSpelling=true,SetLastError=true)] static extern IntPtr SendMessageTimeoutP(IntPtr h,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] data,int size);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out Rect rect,int size);
 public static string ClassName(IntPtr h) { var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
 public static string WindowText(IntPtr h) { var s=new StringBuilder(512); GetWindowText(h,s,512); return s.ToString(); }
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
 public static long Message(IntPtr h,uint msg,string text) { UIntPtr result; if(SendMessageTimeoutW(h,msg,UIntPtr.Zero,text,0x2,1000,out result)==IntPtr.Zero) throw new Exception("Native control message failed/timed out; state may be unknown, inspect before retrying"); return unchecked((long)result.ToUInt64()); }
 public static long Post(IntPtr h,uint msg,long wp,long lp) { UIntPtr result; if(SendMessageTimeoutP(h,msg,new IntPtr(wp),new IntPtr(lp),0x2,1000,out result)==IntPtr.Zero) throw new Exception("Native message failed/timed out; state may be unknown, inspect before retrying"); return unchecked((long)result.ToUInt64()); }
 public static IntPtr FocusOf(IntPtr h) { uint pid; uint tid=GetWindowThreadProcessId(h,out pid); var info=new GuiThreadInfo(); info.cbSize=Marshal.SizeOf(typeof(GuiThreadInfo)); if(tid==0||!GetGUIThreadInfo(tid,ref info)) return IntPtr.Zero; return info.focus; }
 public static void Focus(IntPtr h) {
   uint ignored; uint current=GetCurrentThreadId(); uint target=GetWindowThreadProcessId(h,out ignored); uint foreground=GetWindowThreadProcessId(GetForegroundWindow(),out ignored);
   bool a=false,b=false;
   try { if(foreground!=0&&foreground!=current) a=AttachThreadInput(current,foreground,true); if(target!=0&&target!=current&&target!=foreground) b=AttachThreadInput(current,target,true); if(IsIconic(h)) ShowWindow(h,9); SetForegroundWindow(h); }
   finally { if(b) AttachThreadInput(current,target,false); if(a) AttachThreadInput(current,foreground,false); }
 }
}
'@

function Initialize {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition $script:csharp | Out-Null
    [void][HybridNative]::SetProcessDPIAware()
}
function Budget { if ($script:clock.ElapsedMilliseconds -gt 35000) { throw 'Backend deadline exceeded; inspect actual state before retrying' } }
function Clip($value) { $text=[string]$value; if ($text.Length -gt 2000) { return $text.Substring(0,2000)+' [truncated]' }; return $text }
function Range($value,$default,$min,$max,$name) {
    if ($null -eq $value) { return $default }
    $number=0L
    if (![long]::TryParse([string]$value,[ref]$number) -or $number -lt $min -or $number -gt $max) { throw "$name must be an integer in [$min,$max]" }
    return [int]$number
}
function Emit($value) { [IO.File]::WriteAllText($ResponsePath,(ConvertTo-Json -InputObject $value -Depth 22 -Compress),[Text.UTF8Encoding]::new($false)) }
function Target {
    $id=0L
    if (![long]::TryParse([string]$script:p.hwnd,[ref]$id) -or $id -eq 0 -or ![HybridNative]::IsWindow([IntPtr]$id)) { throw 'Invalid hwnd; enumerate windows again' }
    return [IntPtr]$id
}
function Root { return [System.Windows.Automation.AutomationElement]::FromHandle((Target)) }
function RawBounds {
    $h=Target
    if ([HybridNative]::IsIconic($h)) { throw 'Window minimized; no implicit restore' }
    $r=New-Object HybridNative+Rect
    if (![HybridNative]::GetWindowRect($h,[ref]$r)) { throw 'Cannot read window bounds' }
    return $r
}
function Bounds {
    # Visible frame: matches what a screenshot shows, so pixel estimates agree with clicks.
    $raw=RawBounds
    try {
        $visible=New-Object HybridNative+Rect
        if ([HybridNative]::DwmGetWindowAttribute((Target),9,[ref]$visible,16) -eq 0 -and $visible.Right -gt $visible.Left -and $visible.Bottom -gt $visible.Top) {
            if ($visible.Left -ge $raw.Left -and $visible.Top -ge $raw.Top -and $visible.Right -le $raw.Right -and $visible.Bottom -le $raw.Bottom) { return $visible }
        }
    } catch {}
    return $raw
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
    if (!$script:p.selector -or !@($script:p.selector.PSObject.Properties | Where-Object { $_.Name -in 'ref','name','automation_id','control_type' -and $_.Value }).Count) { throw 'Nonempty selector required (ref/name/automation_id/control_type)' }
    foreach ($field in $script:p.selector.PSObject.Properties) { if ($field.Name -notin 'ref','name','automation_id','control_type' -or ![string]$field.Value) { throw 'Invalid or empty selector field' } }
    $q=[Collections.Generic.Queue[object]]::new(); $q.Enqueue((Root)); $found=$null; $seen=0
    $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
    while ($q.Count -gt 0) {
        Budget
        if (++$seen -gt 5000) { throw 'Selector search exceeds 5000 controls; narrow the target window' }
        $el=$q.Dequeue()
        try {
            if (Match $el $script:p.selector) { if ($null -ne $found) { throw 'Selector ambiguous; use an exact ref' }; $found=$el }
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
function StopPath { return [IO.Path]::Combine([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$script:p.statePath)),'stop') }
function StopNow($reason) {
    if ($script:p.statePath) { try { [IO.File]::WriteAllText((StopPath),$reason,[Text.UTF8Encoding]::new($false)) } catch {} }
    throw $reason
}
function Lease([bool]$requireForeground=$true,[bool]$keyboard=$false) {
    Budget
    if (!$script:p.statePath -or ![IO.Path]::IsPathRooted([string]$script:p.statePath)) { throw 'An absolute statePath lease is required' }
    if (Test-Path -LiteralPath (StopPath)) { throw 'Takeover stopped: stop file exists' }
    if ([HybridNative]::Emergency()) { StopNow 'Emergency Ctrl+Alt+Esc pressed' }
    $state=Get-Content -LiteralPath $script:p.statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.active -isnot [bool] -or $state.active -ne $true -or [long]$state.hwnd -ne (Target).ToInt64()) { throw 'Inactive or wrong-target lease' }
    $expiry=0L
    if (![long]::TryParse([string]$state.expiresAt,[ref]$expiry)) { $expiry=[DateTimeOffset]::Parse([string]$state.expiresAt).ToUnixTimeMilliseconds() }
    if ($expiry -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { StopNow 'Takeover lease expired' }
    if ($requireForeground -and [HybridNative]::GetForegroundWindow() -ne (Target)) { StopNow 'Foreground window changed; takeover stopped' }
    if ($keyboard -and [HybridNative]::Modifiers()) { StopNow 'User modifier key is held; keyboard input cancelled' }
    return $state
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
    $x=Range $script:p.x $null 0 ($r.Right-$r.Left-1) 'x'; $y=Range $script:p.y $null 0 ($r.Bottom-$r.Top-1) 'y'
    if ($null -eq $script:p.x -or $null -eq $script:p.y) { throw 'x and y required' }
    $start=Position; $last=$start
    for ($step=1; $step -le 20; $step++) {
        $null=Lease $true $false
        CheckPointer $last
        $currentBounds=Bounds
        if ($currentBounds.Left -ne $r.Left -or $currentBounds.Top -ne $r.Top -or $currentBounds.Right -ne $r.Right -or $currentBounds.Bottom -ne $r.Bottom) { StopNow 'Target window moved or resized; inspect before retrying' }
        $next=New-Object HybridNative+Point
        $next.X=[int][Math]::Round($start.X+(($r.Left+$x-$start.X)*$step/20.0)); $next.Y=[int][Math]::Round($start.Y+(($r.Top+$y-$start.Y)*$step/20.0))
        if (![HybridNative]::SetCursorPos($next.X,$next.Y)) { throw 'Cannot move pointer' }
        $last=$next
        Start-Sleep -Milliseconds 15
    }
    $null=Lease $true $false; CheckPointer $last
    return $last
}
function SelectorCenter {
    # UIA reports physical screen rectangles, so no pixel estimation is needed.
    $el=FindOne
    if ($null -eq $el) { throw 'No matching control' }
    $c=$el.Current
    if (!$c.IsEnabled) { throw 'Control disabled' }
    $b=$c.BoundingRectangle
    if ($b.IsEmpty) { throw 'Control has no on-screen rectangle' }
    $point=New-Object HybridNative+Point
    $point.X=[int][Math]::Round($b.X+$b.Width/2); $point.Y=[int][Math]::Round($b.Y+$b.Height/2)
    return @{point=$point;ref=($el.GetRuntimeId() -join '.');name=(Clip $c.Name);class_name=$c.ClassName;control_type=$c.ControlType.ProgrammaticName;bounds=@{x=[int]$b.X;y=[int]$b.Y;width=[int]$b.Width;height=[int]$b.Height}}
}
function TargetPoint {
    # Returns a screen point from an element center when a selector is supplied, else from window coordinates.
    if ($script:p.selector) { return (SelectorCenter) }
    $r=Bounds
    $x=Range $script:p.x $null 0 ($r.Right-$r.Left-1) 'x'; $y=Range $script:p.y $null 0 ($r.Bottom-$r.Top-1) 'y'
    if ($null -eq $script:p.x -or $null -eq $script:p.y) { throw 'Provide a selector, or both x and y' }
    $point=New-Object HybridNative+Point
    $point.X=$r.Left+$x; $point.Y=$r.Top+$y
    return @{point=$point;ref=$null;name=$null;class_name=$null;control_type=$null;bounds=@{x=$r.Left;y=$r.Top;width=($r.Right-$r.Left);height=($r.Bottom-$r.Top)}}
}
function IsClassicClass($name) {
    # Message-based input is reliable only for controls with a standard window procedure.
    if (!$name) { return $false }
    return $name -match '(?i)^(Edit|RichEdit|RICHEDIT|Button|ComboBox|ListBox|Static|SysListView32|SysTreeView32|SysTabControl32|Scintilla|msctls_|WindowsForms10\.|ThunderRT6|Afx:)'
}
function ControlUnderPoint($screenPoint) {
    # Background messages do not need the window to be uncovered, so resolve inside
    # the target tree even when another application is on top of that point.
    $h=[HybridNative]::WindowFromPoint($screenPoint)
    if ($h -ne [IntPtr]::Zero -and $h -ne (Target) -and [HybridNative]::GetAncestor($h,2) -eq [HybridNative]::GetAncestor((Target),2)) { return $h }
    $client=$screenPoint
    [void][HybridNative]::ScreenToClient((Target),[ref]$client)
    $child=[HybridNative]::RealChildWindowFromPoint((Target),$client)
    if ($child -ne [IntPtr]::Zero -and $child -ne (Target)) { return $child }
    return (Target)
}
function ElementInfo {
    $el=FindOne
    if ($null -eq $el) { throw 'No matching control' }
    $c=$el.Current
    $b=$c.BoundingRectangle
    $point=New-Object HybridNative+Point
    if (!$b.IsEmpty) { $point.X=[int][Math]::Round($b.X+$b.Width/2); $point.Y=[int][Math]::Round($b.Y+$b.Height/2) }
    $bounds=$null
    if (!$b.IsEmpty) { $bounds=@{x=[int]$b.X;y=[int]$b.Y;width=[int]$b.Width;height=[int]$b.Height} }
    return @{element=$el;native=[IntPtr][long]$c.NativeWindowHandle;point=$point;ref=($el.GetRuntimeId() -join '.');class_name=$c.ClassName;name=(Clip $c.Name);enabled=$c.IsEnabled;bounds=$bounds}
}
function ClassicChildOf($element) {
    if ($null -eq $element) { return [IntPtr]::Zero }
    $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
    $stack=[Collections.Generic.Stack[object]]::new(); $stack.Push($element)
    while ($stack.Count -gt 0) {
        Budget
        $current=$stack.Pop()
        try {
            $h=[IntPtr][long]$current.Current.NativeWindowHandle
            if ($h -ne [IntPtr]::Zero -and (IsClassicClass ([HybridNative]::ClassName($h)))) { return $h }
            $child=$walker.GetFirstChild($current)
            while ($null -ne $child) { $stack.Push($child); $child=$walker.GetNextSibling($child) }
        } catch [System.Windows.Automation.ElementNotAvailableException] {}
    }
    return [IntPtr]::Zero
}
function InputControlForText {
    if ($script:p.selector) {
        $info=ElementInfo
        if (!$info.enabled) { return [IntPtr]::Zero }
        if ($info.native -ne [IntPtr]::Zero -and (IsClassicClass $info.class_name)) { return $info.native }
        $nested=ClassicChildOf $info.element
        if ($nested -ne [IntPtr]::Zero) { return $nested }
        return (ControlUnderPoint($info.point))
    }
    $focus=[HybridNative]::FocusOf((Target))
    if ($focus -ne [IntPtr]::Zero -and [HybridNative]::GetAncestor($focus,2) -eq [HybridNative]::GetAncestor((Target),2) -and (IsClassicClass ([HybridNative]::ClassName($focus)))) { return $focus }
    return (ClassicChildOf (Root))
}
function BackgroundClick {
    if ($script:p.selector) {
        $info=ElementInfo
        if (!$info.enabled) { return @{supported=$false;executed=$false;takeover_required=$true;operation='click';reason='Control disabled; foreground input required'} }
        $point=$info.point
        $hit=$info.native
        if ($hit -eq [IntPtr]::Zero) { $hit=ControlUnderPoint($point) }
    } else {
        $target=TargetPoint
        $point=$target.point
        $hit=ControlUnderPoint($point)
        $info=$target
    }
    if ($hit -eq [IntPtr]::Zero) { return @{supported=$false;executed=$false;takeover_required=$true;operation='click';reason='No control found for that point; foreground input required'} }
    $class=[HybridNative]::ClassName($hit)
    if (!(IsClassicClass $class)) { return @{supported=$false;executed=$false;takeover_required=$true;operation='click';class_name=$class;reason="Class '$class' ignores posted mouse messages; foreground input required"} }
    $before=RawBounds
    $method='WM_LBUTTON'
    if ($class -match '(?i)(^Button$|\.BUTTON\.|ThunderRT6CommandButton|Afx:)') {
        # Standard buttons ignore posted mouse pairs; BM_CLICK runs their click handler.
        [void][HybridNative]::Post($hit,0x00F5,0,0)
        $method='BM_CLICK'
        Start-Sleep -Milliseconds 60
    } else {
        $client=$point
        [void][HybridNative]::ScreenToClient($hit,[ref]$client)
        $packed=([long]($client.Y -band 0xFFFF) -shl 16) -bor [long]($client.X -band 0xFFFF)
        [void][HybridNative]::Post($hit,0x0201,1,$packed)
        Start-Sleep -Milliseconds 30
        [void][HybridNative]::Post($hit,0x0202,0,$packed)
    }
    $after=RawBounds
    if ($after.Left -ne $before.Left -or $after.Top -ne $before.Top) { throw 'Target window moved during background click; inspect before retrying' }
    return @{supported=$true;executed=$true;mode='background';operation='click';method=$method;hit_class=$class;hit_title=(Clip ([HybridNative]::WindowText($hit)));screen_x=$point.X;screen_y=$point.Y;ref=$info.ref;bounds=$info.bounds;verification='Message posted without focus change; inspect target state to confirm the application handled it'}
}
function BackgroundText {
    $text=[string]$script:p.text
    if ($null -eq $script:p.text -or $text.Length -gt 2000 -or $text.Contains([char]0)) { throw 'text required; maximum 2000 UTF-16 code units, no NUL' }
    $control=InputControlForText
    if ($control -eq [IntPtr]::Zero) { return @{supported=$false;executed=$false;takeover_required=$true;operation='type';reason='No standard text control found; foreground input required'} }
    $class=[HybridNative]::ClassName($control)
    if (!(IsClassicClass $class)) { return @{supported=$false;executed=$false;takeover_required=$true;operation='type';class_name=$class;reason="Class '$class' needs real keyboard input; foreground input required"} }
    # WM_SETFOCUS keeps the form's internal focus without taking system focus.
    [void][HybridNative]::Post($control,0x0007,0,0)
    foreach ($ch in $text.ToCharArray()) { Budget; [void][HybridNative]::Post($control,0x0102,[long][int]$ch,1) }
    return @{supported=$true;executed=$true;mode='background';operation='type';typed_code_units=$text.Length;native_hwnd=$control.ToInt64();class_name=$class;verification='WM_CHAR sent without focus change; inspect the control text before sending/submitting'}
}
function BackgroundKey {
    $name=[string]$script:p.key
    if ($name.StartsWith('Ctrl+',[StringComparison]::OrdinalIgnoreCase)) { return @{supported=$false;executed=$false;takeover_required=$true;operation='key';reason='Modifier chords need the real keyboard queue; foreground input required'} }
    $keys=@{Enter=13;Tab=9;Escape=27;Backspace=8;Delete=46;ArrowLeft=37;Left=37;ArrowUp=38;Up=38;ArrowRight=39;Right=39;ArrowDown=40;Down=40;Home=36;End=35;PageUp=33;PageDown=34}
    if (!$keys.ContainsKey($name)) { throw 'Unsupported key; use Enter/Tab/Escape/Backspace/Delete/arrows/Home/End/PageUp/PageDown or Ctrl+A/C/V/S' }
    $control=InputControlForText
    if ($control -eq [IntPtr]::Zero) { return @{supported=$false;executed=$false;takeover_required=$true;operation='key';reason='No standard control accepts background keys'} }
    $class=[HybridNative]::ClassName($control)
    if (!(IsClassicClass $class)) { return @{supported=$false;executed=$false;takeover_required=$true;operation='key';class_name=$class;reason="Class '$class' needs real keyboard input; foreground input required"} }
    $vk=[int]$keys[$name]
    [void][HybridNative]::Post($control,0x0007,0,0)
    [void][HybridNative]::Post($control,0x0100,[long]$vk,1)
    if ($vk -in 13,9,8,27,46) { [void][HybridNative]::Post($control,0x0102,[long]$vk,1) }
    [void][HybridNative]::Post($control,0x0101,[long]$vk,[long]0xC0000001)
    return @{supported=$true;executed=$true;mode='background';operation='key';key=$name;class_name=$class;verification='Key messages sent without focus change; inspect the control before submitting'}
}
function BackgroundScroll {
    $delta=Range $script:p.delta 0 -1200 1200 'delta'
    if ($delta -eq 0) { throw 'Nonzero delta required (wheel units, 120 per notch)' }
    if ($script:p.selector) {
        $info=ElementInfo
        $point=$info.point
        $hit=$info.native
        if ($hit -eq [IntPtr]::Zero) { $hit=ControlUnderPoint($point) }
    } else {
        $target=TargetPoint
        $point=$target.point
        $hit=ControlUnderPoint($point)
    }
    if ($hit -eq [IntPtr]::Zero) { return @{supported=$false;executed=$false;takeover_required=$true;operation='scroll';reason='No control found for that point; foreground input required'} }
    $client=$point
    [void][HybridNative]::ScreenToClient($hit,[ref]$client)
    $packed=([long]($client.Y -band 0xFFFF) -shl 16) -bor [long]($client.X -band 0xFFFF)
    $wp=[long]((([int64]$delta -band 0xFFFF) -shl 16))
    [void][HybridNative]::Post($hit,0x020A,$wp,$packed)
    return @{supported=$true;executed=$true;mode='background';operation='scroll';delta=$delta;hit_class=[HybridNative]::ClassName($hit);verification='Wheel message posted without focus change; inspect the result'}
}
function Run-Action {
    switch ($script:action) {
        'apps' {
            $limit=Range $script:p.limit 100 1 500 'limit'; $items=@{}
            foreach ($base in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                foreach ($app in @(Get-ItemProperty -Path $base -ErrorAction SilentlyContinue)) {
                    Budget
                    if (!$app.DisplayName -or ($script:p.query -and $app.DisplayName.IndexOf([string]$script:p.query,[StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
                    $items["$($app.DisplayName)|$($app.DisplayVersion)|$($app.InstallLocation)"]=@{name=(Clip $app.DisplayName);version=(Clip $app.DisplayVersion);publisher=(Clip $app.Publisher);install_location=(Clip $app.InstallLocation);display_icon=(Clip $app.DisplayIcon)}
                }
            }
            @{total=$items.Count;truncated=($items.Count -gt $limit);apps=@($items.Values | Sort-Object {$_.name} | Select-Object -First $limit);coverage='Uninstall registry; some portable/Store apps absent'}
        }
        'windows' {
            $limit=Range $script:p.limit 100 1 500 'limit'
            $children=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
            $rows=@();$truncated=$false
            foreach ($el in $children) { Budget; try { $c=$el.Current; if ($c.NativeWindowHandle -ne 0) { if ($rows.Count -ge $limit) {$truncated=$true;break}; $rows+=@{hwnd=[long]$c.NativeWindowHandle;title=(Clip $c.Name);pid=$c.ProcessId;control_type=$c.ControlType.ProgrammaticName;offscreen=$c.IsOffscreen;minimized=[HybridNative]::IsIconic([IntPtr]$c.NativeWindowHandle)} } } catch [System.Windows.Automation.ElementNotAvailableException] {} }
            @{windows=$rows;truncated=$truncated}
        }
        'inspect' {
            $limit=Range $script:p.limit 150 1 500 'limit';$depth=Range $script:p.depth 5 0 12 'depth'
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
            @{hwnd=$script:p.hwnd;controls=@($rows.ToArray());truncated=($truncated -or $q.Count -gt 0)}
        }
        'wait' {
            $timeout=Range $script:p.timeout_ms 5000 1 30000 'timeout_ms';$timer=[Diagnostics.Stopwatch]::StartNew();$el=$null
            do { Budget;$el=FindOne;if ($null -ne $el) {break};if ($timer.ElapsedMilliseconds -ge $timeout) {throw 'Timed out waiting for control'};Start-Sleep -Milliseconds 150 } while ($true)
            @{ref=($el.GetRuntimeId() -join '.');found=$true}
        }
        'background_act' {
            $op=[string]$script:p.operation
            if ($op -in 'invoke','set_value','select') {
                $el=FindOne
                if ($null -eq $el) { @{supported=$false;takeover_required=$true;reason='No matching control';patterns=@();operation=$op} }
                else {
                    $cap=Capability $el $op
                    if ($cap.supported) {
                        if ($op -eq 'set_value') {
                            if ($null -eq $script:p.value -or ([string]$script:p.value).Length -gt 2000 -or ([string]$script:p.value).Contains([char]0)) {throw 'value must be a string of at most 2000 UTF-16 code units without NUL'}
                            $messageResult=[HybridNative]::Message([IntPtr][long]$cap.native_hwnd,12,[string]$script:p.value)
                            if ($messageResult -eq 0) {throw 'WM_SETTEXT rejected by control'}
                        } else { $null=[HybridNative]::Message([IntPtr][long]$cap.native_hwnd,245,$null) }
                        $cap.executed=$true;$cap.verification='Inspect target controls/screenshot; message delivery is not business success'
                    } else { $cap.executed=$false }
                    $cap
                }
            }
            elseif ($op -eq 'click') { BackgroundClick }
            elseif ($op -eq 'type') { BackgroundText }
            elseif ($op -eq 'key') { BackgroundKey }
            elseif ($op -eq 'scroll') { BackgroundScroll }
            elseif ($op -eq 'move') { @{supported=$false;executed=$false;takeover_required=$true;operation='move';reason='Pointer movement is a visible action; foreground takeover required'} }
            else { throw 'Unsupported operation' }
        }
        'screenshot' {
            $mode='background';if ($script:p.mode) {$mode=[string]$script:p.mode};if ($mode -notin 'background','foreground') {throw 'mode must be background or foreground'}
            if (!$script:p.path -or ![IO.Path]::IsPathRooted([string]$script:p.path) -or [IO.Path]::GetExtension([string]$script:p.path) -ine '.png') {throw 'Absolute .png path required'}
            $raw=RawBounds;$visible=Bounds
            $w=$raw.Right-$raw.Left;$h=$raw.Bottom-$raw.Top
            if ($w -le 0 -or $h -le 0 -or [long]$w*$h -gt 40000000) {throw 'Invalid or excessive capture dimensions (maximum 40 million pixels)'}
            $bitmap=[Drawing.Bitmap]::new($w,$h);$g=[Drawing.Graphics]::FromImage($bitmap);$cropped=$null;$dc=[IntPtr]::Zero
            try {
                if ($mode -eq 'background') {$dc=$g.GetHdc();$painted=[HybridNative]::PrintWindow((Target),$dc,2);$g.ReleaseHdc($dc);$dc=[IntPtr]::Zero;if (!$painted) {throw 'PrintWindow failed; no foreground fallback'}}
                else {$g.CopyFromScreen($raw.Left,$raw.Top,0,0,[Drawing.Size]::new($w,$h))}
                $vw=$visible.Right-$visible.Left;$vh=$visible.Bottom-$visible.Top
                $ox=$visible.Left-$raw.Left;$oy=$visible.Top-$raw.Top
                if ($ox -gt 0 -or $oy -gt 0 -or $vw -ne $w -or $vh -ne $h) {
                    if ($vw -le 0 -or $vh -le 0 -or $ox -lt 0 -or $oy -lt 0 -or ($ox+$vw) -gt $w -or ($oy+$vh) -gt $h) { throw 'Visible frame lies outside the captured window' }
                    $cropped=[Drawing.Bitmap]::new($vw,$vh);$cg=[Drawing.Graphics]::FromImage($cropped)
                    try { $cg.DrawImage($bitmap,[Drawing.Rectangle]::new(0,0,$vw,$vh),[Drawing.Rectangle]::new($ox,$oy,$vw,$vh),[Drawing.GraphicsUnit]::Pixel);$cropped.Save([string]$script:p.path,[Drawing.Imaging.ImageFormat]::Png) }
                    finally { $cg.Dispose() }
                } else { $bitmap.Save([string]$script:p.path,[Drawing.Imaging.ImageFormat]::Png) }
            } finally {if ($dc -ne [IntPtr]::Zero) {$g.ReleaseHdc($dc)};$g.Dispose();$bitmap.Dispose();if ($null -ne $cropped) {$cropped.Dispose()}}
            @{path=$script:p.path;width=$vw;height=$vh;screen_origin=@{x=$visible.Left;y=$visible.Top};mode=$mode;capture='Image is cropped to the visible window frame; coordinates are pixels inside this image'}
        }
        'compare' {
            $stride=Range $script:p.stride 4 1 32 'stride';$threshold=Range $script:p.threshold 20 0 255 'threshold'
            $a=[Drawing.Bitmap]::new([string]$script:p.before);$b=$null
            try {
                $b=[Drawing.Bitmap]::new([string]$script:p.after)
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
            @{prepared=$true;hwnd=$script:p.hwnd;note='Restored/focused without changing topmost; user input remains unblocked'}
        }
        {$_ -in 'invoke','set_value','select'} {
            $null=Lease $true $true
            $el=FindOne
            if ($null -eq $el) {throw 'No matching control'}
            if (!$el.Current.IsEnabled) {throw 'Control disabled'}
            $ref=$el.GetRuntimeId() -join '.'
            if ($script:action -eq 'set_value' -and ($null -eq $script:p.value -or ([string]$script:p.value).Length -gt 2000 -or ([string]$script:p.value).Contains([char]0))) {throw 'value required; maximum 2000 UTF-16 code units, no NUL'}
            $null=Lease $true $true
            switch ($script:action) {
                'invoke' {$pattern=$el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern);$null=Lease $true $true;$pattern.Invoke()}
                'set_value' {$pattern=$el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern);if ($pattern.Current.IsReadOnly) {throw 'Control read-only'};$null=Lease $true $true;$pattern.SetValue([string]$script:p.value)}
                'select' {$pattern=$el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern);$null=Lease $true $true;$pattern.Select()}
            }
            @{executed=$true;operation=$script:action;ref=$ref;verification='Foreground UIA action; inspect actual result'}
        }
        {$_ -in 'move','click','type','key','scroll'} {
            $null=Lease $true ($script:action -in 'type','key')
            switch ($script:action) {
                'move' {$point=SmoothMove;@{moved=$true;x=$point.X;y=$point.Y}}
                'click' {
                    $button='left';if ($script:p.button) {$button=[string]$script:p.button};if ($button -notin 'left','right','middle') {throw 'button must be left/right/middle'}
                    $target=TargetPoint
                    if ($script:p.selector) { $point=$target.point; CheckPointer $point; HitTarget $point }
                    else {
                        $point=SmoothMove
                        $null=Lease $true $false;CheckPointer $point;HitTarget $point
                    }
                    [HybridNative]::MouseInput($button,0,$false)
                    Start-Sleep -Milliseconds 40
                    @{clicked=$true;screen_x=$point.X;screen_y=$point.Y;button=$button;ref=$target.ref;bounds=$target.bounds;hit_class=[HybridNative]::ClassName([HybridNative]::WindowFromPoint($point))}
                }
                'type' {
                    if ($null -eq $script:p.text -or ([string]$script:p.text).Length -gt 2000 -or ([string]$script:p.text).Contains([char]0)) {throw 'text required; maximum 2000 UTF-16 code units, no NUL'}
                    $anchor=Position;$text=[string]$script:p.text
                    for ($i=0;$i -lt $text.Length;$i++) {$null=Lease $true $true;CheckPointer $anchor;[HybridNative]::Unicode($text[$i])}
                    Start-Sleep -Milliseconds 30
                    @{typed_code_units=$text.Length;verification='Re-inspect input before sending/submitting'}
                }
                'key' {
                    $keys=@{Enter=13;Tab=9;Escape=27;Backspace=8;Delete=46;ArrowLeft=37;Left=37;ArrowUp=38;Up=38;ArrowRight=39;Right=39;ArrowDown=40;Down=40;Home=36;End=35;PageUp=33;PageDown=34;'Ctrl+A'=65;'Ctrl+C'=67;'Ctrl+V'=86;'Ctrl+S'=83}
                    $name=[string]$script:p.key;if (!$keys.ContainsKey($name)) {throw 'Unsupported key; use Enter/Tab/Escape/Backspace/Delete/arrows/Home/End/PageUp/PageDown or Ctrl+A/C/V/S'}
                    $null=Lease $true $true
                    [HybridNative]::Key([ushort]$keys[$name],$name.StartsWith('Ctrl+',[StringComparison]::OrdinalIgnoreCase))
                    @{key=$name;sent=$true}
                }
                'scroll' {
                    $delta=Range $script:p.delta 0 -1200 1200 'delta';if ($delta -eq 0) {throw 'Nonzero delta required (wheel units, 120 per notch)'}
                    $point=Position;$null=Lease $true $false;HitTarget $point
                    [HybridNative]::MouseInput('wheel',$delta,($script:p.horizontal -eq $true))
                    @{scrolled=$true;delta=$delta;horizontal=($script:p.horizontal -eq $true)}
                }
            }
        }
        default { throw 'Unknown action; expected apps/windows/inspect/wait/compare/screenshot/background_act/prepare/foreground operations' }
    }
}
function Invoke-Request($request) {
    $script:p=$request.params
    if (!$script:p) { $script:p=[pscustomobject]@{} }
    $script:action=[string]$request.action
    if ($script:action -eq 'foreground_act') {
        if ($script:p.operation -notin 'move','click','type','key','scroll','invoke','set_value','select') { throw 'Unsupported foreground operation' }
        $script:action=[string]$script:p.operation
    }
    $foregroundBefore=[HybridNative]::GetForegroundWindow().ToInt64()
    $cursorBefore=New-Object HybridNative+Point
    [void][HybridNative]::GetCursorPos([ref]$cursorBefore)
    $result=Run-Action
    $cursorAfter=Position
    $result.background_observation=@{foreground_unchanged=($foregroundBefore -eq [HybridNative]::GetForegroundWindow().ToInt64());cursor_unchanged=($cursorBefore.X -eq $cursorAfter.X -and $cursorBefore.Y -eq $cursorAfter.Y);note='Observation only; user/application activity can also change focus or pointer'}
    return $result
}
function Respond($request) {
    try { $value=Invoke-Request $request; return @{ok=$true;result=$value} }
    catch { return @{ok=$false;error=$_.Exception.Message} }
}

Initialize
if ($CheckSyntax) { Write-Output 'Native script parsed and C# compiled'; exit 0 }
if ($WorkerDir) {
    $lock=Join-Path $WorkerDir 'worker.lock'
    if (Test-Path -LiteralPath $lock) {
        $holder=0
        if ([int]::TryParse([string](Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue),[ref]$holder) -and $holder -ne $PID) {
            $alive=$false
            try { $alive=-not (Get-Process -Id $holder -ErrorAction Stop).HasExited } catch {}
            if ($alive) { exit 0 }
        }
    }
    [IO.File]::WriteAllText($lock,[string]$PID,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $WorkerDir 'worker-ready.json'),(ConvertTo-Json -InputObject @{pid=$PID;startedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()} -Compress),[Text.UTF8Encoding]::new($false))
    $idle=[Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $pending=@([IO.Directory]::EnumerateFiles($WorkerDir,'req-*.json'))
        if ($pending.Count -eq 0) {
            if ($idle.Elapsed.TotalMinutes -gt 10) { break }
            Start-Sleep -Milliseconds 15
            continue
        }
        [Array]::Sort($pending,[StringComparer]::Ordinal)
        $requestFile=$pending[0]
        $id=[IO.Path]::GetFileNameWithoutExtension($requestFile).Substring(4)
        $responseFile=Join-Path $WorkerDir ("res-$id.json")
        $script:clock.Restart()
        $payload=$null
        try {
            $request=Get-Content -LiteralPath $requestFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $payload=Respond $request
        } catch { $payload=@{ok=$false;error=$_.Exception.Message} }
        [IO.File]::WriteAllText($responseFile,(ConvertTo-Json -InputObject $payload -Depth 22 -Compress),[Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
        $idle.Restart()
    }
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    exit 0
}
$request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Emit (Respond $request)
