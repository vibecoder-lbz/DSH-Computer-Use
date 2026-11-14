param([int]$OverlayPid)
$ErrorActionPreference='SilentlyContinue'
Wait-Process -Id $OverlayPid -ErrorAction SilentlyContinue
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class RestoreDshCursor { [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a,uint b,IntPtr c,uint d); }'
[void][RestoreDshCursor]::SystemParametersInfo(0x57,0,[IntPtr]::Zero,0)
