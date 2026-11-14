param(
    [Parameter(Mandatory=$true)][string]$StatePath,
    [int]$OwnerPid = 0,
    [ValidateRange(33,100)][int]$PollMs = 50,
    [switch]$CheckSyntax
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'overlay.cs'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Xaml
$references = @(
    [System.Windows.Window].Assembly.Location,
    [System.Windows.Media.Visual].Assembly.Location,
    [System.Windows.Threading.DispatcherObject].Assembly.Location,
    [System.Web.Script.Serialization.JavaScriptSerializer].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location
)
Add-Type -Path $source -ReferencedAssemblies $references
if ($CheckSyntax) { Write-Output 'Overlay C# compilation passed'; exit 0 }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run overlay.ps1 with powershell.exe -STA -File.'
}
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WhaleCursor {
 [StructLayout(LayoutKind.Sequential)] public struct Info { public bool icon; public uint x,y; public IntPtr mask,color; }
 [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr h,out Info i);
 [DllImport("user32.dll")] public static extern IntPtr CreateIconIndirect(ref Info i);
 [DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr h,uint id);
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
 [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a,uint b,IntPtr c,uint d);
}
'@
# An independent watchdog restores the configured Windows cursors even if this process is killed.
$watchdog = Join-Path $PSScriptRoot 'cursor-restore.ps1'
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$startInfo.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchdog + '" -OverlayPid ' + $PID
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$watchdogProcess = [Diagnostics.Process]::Start($startInfo)
$watchdogProcess.Dispose()
try {
    $cursorBitmap=[Drawing.Bitmap]::new((Join-Path $PSScriptRoot 'deepseek-whale.png'))
    $icon=$cursorBitmap.GetHicon()
    try {
        foreach ($cursorId in @(32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650,32651)) {
            $info=New-Object WhaleCursor+Info
            if (![WhaleCursor]::GetIconInfo($icon,[ref]$info)) { throw 'Cannot create whale cursor' }
            try {
                $info.icon=$false; $info.x=2; $info.y=10
                $cursor=[WhaleCursor]::CreateIconIndirect([ref]$info)
                if ($cursor -eq [IntPtr]::Zero -or ![WhaleCursor]::SetSystemCursor($cursor,[uint32]$cursorId)) { throw 'Cannot install whale cursor' }
            } finally { [void][WhaleCursor]::DeleteObject($info.mask); [void][WhaleCursor]::DeleteObject($info.color) }
        }
    } finally { [void][WhaleCursor]::DestroyIcon($icon); $cursorBitmap.Dispose() }
    [DshDesktopOverlay.OverlayRunner]::Run([IO.Path]::GetFullPath($StatePath), $OwnerPid, $PollMs)
} finally { [void][WhaleCursor]::SystemParametersInfo(0x57,0,[IntPtr]::Zero,0) }
