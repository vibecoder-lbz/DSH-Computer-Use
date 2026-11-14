param([long]$TargetHwnd)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TestEmergencyKey {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern void keybd_event(byte k,byte s,uint f,UIntPtr e);
 public static void Press() {
   try { keybd_event(0x11,0,0,UIntPtr.Zero); keybd_event(0x12,0,0,UIntPtr.Zero); keybd_event(0x1b,0,0,UIntPtr.Zero); System.Threading.Thread.Sleep(150); }
   finally { keybd_event(0x1b,0,2,UIntPtr.Zero); keybd_event(0x12,0,2,UIntPtr.Zero); keybd_event(0x11,0,2,UIntPtr.Zero); }
 }
}
'@
if ([TestEmergencyKey]::GetForegroundWindow().ToInt64() -ne $TargetHwnd) { throw 'Test fixture is not foreground; hotkey simulation cancelled' }
[TestEmergencyKey]::Press()
