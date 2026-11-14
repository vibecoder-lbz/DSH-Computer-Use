using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace DshDesktopOverlay
{
    // Coordinates and numeric times in the state file are physical screen pixels
    // and Unix milliseconds. ISO-8601 times are also accepted. No input is injected.
    public static class OverlayRunner
    {
        public static void Run(string statePath, int ownerPid, int pollMs)
        {
            if (pollMs < 33 || pollMs > 100) throw new ArgumentOutOfRangeException("pollMs");
            // Keep native geometry in physical pixels on mixed-DPI monitors.
            try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            var window = new OverlayWindow(statePath, ownerPid, pollMs);
            window.ShowActivated = false;
            window.Show();
            if (!window.Finished) Dispatcher.Run();
        }
    }

    internal sealed class OverlayWindow : Window
    {
        const int HotkeyId = 0x4453;
        const long ExTransparent = 0x20, ExToolWindow = 0x80, ExLayered = 0x80000, ExNoActivate = 0x08000000;
        const int MarginPixels = 8;
        readonly string statePath, directory;
        readonly int ownerPid;
        readonly DispatcherTimer timer;
        readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        readonly OverlayVisual visual = new OverlayVisual();
        IntPtr handle, target;
        bool registered, readyWritten;
        long lastValidRead;
        Native.Rect targetRect;
        public bool Finished { get; private set; }

        public OverlayWindow(string path, int owner, int pollMs)
        {
            statePath = path; directory = Path.GetDirectoryName(path); ownerPid = owner;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            Focusable = false;
            IsHitTestVisible = false;
            Left = -32000; Top = -32000; Width = 1; Height = 1;
            Content = visual;
            SourceInitialized += OnSource;
            Closed += delegate { Finish(); };
            timer = new DispatcherTimer(DispatcherPriority.Render);
            timer.Interval = TimeSpan.FromMilliseconds(pollMs);
            timer.Tick += delegate { Tick(); };
            lastValidRead = Now();
        }

        void OnSource(object sender, EventArgs args)
        {
            handle = new WindowInteropHelper(this).Handle;
            long style = Native.GetStyle(handle).ToInt64();
            Native.SetStyle(handle, new IntPtr(style | ExTransparent | ExToolWindow | ExLayered | ExNoActivate));
            HwndSource.FromHwnd(handle).AddHook(Hook);
            // MOD_NOREPEAT avoids repeated stop writes. Polling is a fallback if registration fails.
            registered = Native.RegisterHotKey(handle, HotkeyId, 0x4003, 0x1B);
            timer.Start();
        }

        IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (message == 0x0084) { handled = true; return new IntPtr(-1); } // HTTRANSPARENT
            if (message == 0x0021) { handled = true; return new IntPtr(3); } // MA_NOACTIVATE
            if (message == 0x0312 && wParam.ToInt32() == HotkeyId) { handled = true; Stop(); }
            return IntPtr.Zero;
        }

        static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }
        static bool Down(int vk) { return (Native.GetAsyncKeyState(vk) & 0x8000) != 0; }
        bool OwnerAlive()
        {
            if (ownerPid <= 0) return true;
            try { using (var p = Process.GetProcessById(ownerPid)) return !p.HasExited; }
            catch { return false; }
        }
        static long Timestamp(object value)
        {
            if (value == null) return 0;
            long number;
            if (long.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Integer, CultureInfo.InvariantCulture, out number)) return number;
            DateTimeOffset date;
            if (DateTimeOffset.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out date)) return date.ToUnixTimeMilliseconds();
            return 0;
        }
        static object Value(Dictionary<string, object> data, string name)
        { object result; return data.TryGetValue(name, out result) ? result : null; }

        void Tick()
        {
            if (Finished) return;
            try
            {
                if (!OwnerAlive()) { Close(); return; }
                if (Down(0x11) && Down(0x12) && Down(0x1B)) { Stop(); return; }
                if (File.Exists(Path.Combine(directory, "stop"))) { Close(); return; }
                Dictionary<string, object> data;
                try
                {
                    using (var stream = new FileStream(statePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                        data = serializer.Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                }
                catch
                {
                    // Never display stale control state during a writer's partial update.
                    Native.ShowWindow(handle, 0);
                    if (Now() - lastValidRead > 1000) Close();
                    return;
                }
                if (data == null || !Object.Equals(Value(data, "active"), true) || Timestamp(Value(data, "expiresAt")) <= Now()) { Close(); return; }
                lastValidRead = Now();
                target = new IntPtr(Convert.ToInt64(Value(data, "hwnd"), CultureInfo.InvariantCulture));
                if (target == IntPtr.Zero || target == handle || !Native.IsWindow(target)) { Close(); return; }
                // The control indicator surrounds the full desktop, independently of target size.
                targetRect.Left = Native.GetSystemMetrics(76);
                targetRect.Top = Native.GetSystemMetrics(77);
                targetRect.Right = targetRect.Left + Native.GetSystemMetrics(78);
                targetRect.Bottom = targetRect.Top + Native.GetSystemMetrics(79);
                if (targetRect.Right <= targetRect.Left || targetRect.Bottom <= targetRect.Top) { Close(); return; }
                var points = new List<TrailPoint>();
                var trail = Value(data, "trail") as System.Collections.IEnumerable;
                if (trail != null)
                    foreach (object item in trail)
                    {
                        var point = item as Dictionary<string, object>;
                        if (point == null) continue;
                        if (points.Count >= 256) points.RemoveAt(0);
                        double x = Convert.ToDouble(Value(point, "x"), CultureInfo.InvariantCulture);
                        double y = Convert.ToDouble(Value(point, "y"), CultureInfo.InvariantCulture);
                        if (Double.IsNaN(x) || Double.IsNaN(y) || Double.IsInfinity(x) || Double.IsInfinity(y)) continue;
                        points.Add(new TrailPoint { X = x, Y = y, Time = Timestamp(Value(point, "t")) });
                    }
                // Render only the live pointer position; never retain movement history.
                Native.Point cursor;
                points.Clear();
                if (Native.GetCursorPos(out cursor)) points.Add(new TrailPoint { X = cursor.X, Y = cursor.Y, Time = Now() });
                int width = targetRect.Right - targetRect.Left;
                int height = targetRect.Bottom - targetRect.Top;
                visual.Update(targetRect.Left, targetRect.Top, width, height, points);
                // HWND_TOPMOST + SWP_NOACTIVATE + SWP_SHOWWINDOW. Never touch target z-order.
                Native.SetWindowPos(handle, new IntPtr(-1), targetRect.Left, targetRect.Top, width, height, 0x0050);
                if (!readyWritten)
                {
                    string json = serializer.Serialize(new { hwnd = handle.ToInt64(), pid = Process.GetCurrentProcess().Id, targetHwnd = target.ToInt64(), hotkeyRegistered = registered });
                    File.WriteAllText(Path.Combine(directory, "overlay-ready.json"), json, new UTF8Encoding(false));
                    readyWritten = true;
                }
            }
            catch { Close(); }
        }
        void Stop()
        {
            try { File.WriteAllText(Path.Combine(directory, "stop"), serializer.Serialize(new { reason = "emergency-hotkey", at = Now(), pid = Process.GetCurrentProcess().Id }), new UTF8Encoding(false)); }
            finally { Close(); }
        }
        void Finish()
        {
            if (Finished) return;
            Finished = true;
            timer.Stop();
            if (registered) Native.UnregisterHotKey(handle, HotkeyId);
            // Do not delete another process's ready marker.
            try
            {
                string path = Path.Combine(directory, "overlay-ready.json");
                if (readyWritten && File.Exists(path))
                {
                    var marker = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                    if (Convert.ToInt32(Value(marker, "pid"), CultureInfo.InvariantCulture) == Process.GetCurrentProcess().Id) File.Delete(path);
                }
            }
            catch { }
            Dispatcher.BeginInvokeShutdown(DispatcherPriority.Background);
        }
    }

    internal struct TrailPoint { public double X, Y; public long Time; }
    internal sealed class OverlayVisual : FrameworkElement
    {
        int originX, originY, pixelWidth, pixelHeight;
        List<TrailPoint> points = new List<TrailPoint>();
        bool renderOverlayPointer = false;
        public void Update(int x, int y, int width, int height, List<TrailPoint> trail)
        { originX = x; originY = y; pixelWidth = width; pixelHeight = height; points = trail; InvalidateVisual(); }
        static void DrawEdgeGlow(DrawingContext dc, Rect area, Point start, Point end)
        {
            var brush = new LinearGradientBrush { StartPoint = start, EndPoint = end };
            brush.GradientStops.Add(new GradientStop(Color.FromArgb(170, 119, 212, 255), 0));
            brush.GradientStops.Add(new GradientStop(Color.FromArgb(65, 103, 195, 255), 0.2));
            brush.GradientStops.Add(new GradientStop(Color.FromArgb(18, 97, 180, 255), 0.55));
            brush.GradientStops.Add(new GradientStop(Color.FromArgb(0, 97, 180, 255), 1));
            dc.DrawRectangle(brush, null, area);
        }
        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            if (pixelWidth <= 0 || pixelHeight <= 0 || ActualWidth <= 0 || ActualHeight <= 0) return;
            dc.PushTransform(new ScaleTransform(ActualWidth / pixelWidth, ActualHeight / pixelHeight));
            double pulse = 0.82 + 0.18 * Math.Sin(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1100.0);
            dc.PushOpacity(pulse);
            DrawEdgeGlow(dc, new Rect(0, 0, pixelWidth, 40), new Point(0, 0), new Point(0, 1));
            DrawEdgeGlow(dc, new Rect(0, pixelHeight - 40, pixelWidth, 40), new Point(0, 1), new Point(0, 0));
            DrawEdgeGlow(dc, new Rect(0, 0, 40, pixelHeight), new Point(0, 0), new Point(1, 0));
            DrawEdgeGlow(dc, new Rect(pixelWidth - 40, 0, 40, pixelHeight), new Point(1, 0), new Point(0, 0));
            dc.Pop();
            var rect = new Rect(1.5, 1.5, Math.Max(1, pixelWidth - 3), Math.Max(1, pixelHeight - 3));
            var gradient = new LinearGradientBrush();
            gradient.StartPoint = new Point(0, 0); gradient.EndPoint = new Point(1, 1);
            gradient.GradientStops.Add(new GradientStop(Color.FromArgb(215, 145, 225, 255), 0));
            gradient.GradientStops.Add(new GradientStop(Color.FromArgb(90, 70, 165, 245), 0.5));
            gradient.GradientStops.Add(new GradientStop(Color.FromArgb(195, 174, 234, 255), 1));
            for (int i = 7; i >= 1; i--)
            {
                var glow = new SolidColorBrush(Color.FromArgb((byte)(18 - i * 2), 100, 200, 255));
                dc.DrawRoundedRectangle(null, new Pen(glow, 2 + i * 2), rect, 10, 10);
            }
            dc.DrawRoundedRectangle(null, new Pen(gradient, 2), rect, 10, 10);
            Rect inner = rect; inner.Inflate(-3, -3);
            if (inner.Width > 0 && inner.Height > 0) dc.DrawRoundedRectangle(null, new Pen(new SolidColorBrush(Color.FromArgb(80, 170, 230, 255)), 1), inner, 8, 8);
            if (renderOverlayPointer && points.Count > 0) // Native whale cursor supplies the sole pointer; no duplicate overlay.
            {
                TrailPoint p = points[points.Count - 1];
                // Original compact blue whale. Its nose marks the exact cursor hotspot.
                // No glow, movement history or trailing copies.
                var whale = new StreamGeometry();
                using (var path = whale.Open())
                {
                    path.BeginFigure(new Point(0, 0), true, true);
                    path.BezierTo(new Point(3, -7), new Point(15, -8), new Point(21, -2), true, false);
                    path.LineTo(new Point(24, 1), true, false);
                    path.BezierTo(new Point(25, -4), new Point(29, -7), new Point(32, -6), true, false);
                    path.LineTo(new Point(30, 0), true, false);
                    path.LineTo(new Point(34, 4), true, false);
                    path.BezierTo(new Point(30, 7), new Point(26, 6), new Point(23, 4), true, false);
                    path.BezierTo(new Point(20, 13), new Point(7, 14), new Point(2, 7), true, false);
                    path.BezierTo(new Point(0, 5), new Point(0, 2), new Point(0, 0), true, false);
                }
                dc.PushTransform(new TranslateTransform(p.X - originX, p.Y - originY));
                var blue = new LinearGradientBrush(Color.FromRgb(74, 173, 255), Color.FromRgb(35, 103, 222), new Point(0, 0), new Point(0, 1));
                dc.DrawGeometry(blue, new Pen(new SolidColorBrush(Color.FromRgb(18, 68, 137)), 1.2), whale);
                dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(155, 220, 255)), null, new Point(11, 7), 7, 2.7);
                var fin = new StreamGeometry();
                using (var path = fin.Open())
                {
                    path.BeginFigure(new Point(12, 4), true, true);
                    path.BezierTo(new Point(11, 10), new Point(16, 13), new Point(19, 11), true, false);
                    path.LineTo(new Point(17, 5), true, false);
                }
                dc.DrawGeometry(new SolidColorBrush(Color.FromRgb(41, 119, 230)), null, fin);
                dc.DrawEllipse(Brushes.White, null, new Point(5.5, 0), 2.1, 2.1);
                dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(15, 43, 83)), null, new Point(5, 0), 1, 1.3);
                dc.Pop();
            }
            const string label = "DSH agent control \u00b7 Ctrl+Alt+Esc stop";
            var text = new FormattedText(label, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12, new SolidColorBrush(Color.FromRgb(210, 241, 255)), 1.0);
            double labelWidth = Math.Min(pixelWidth - 20, text.Width + 24);
            if (labelWidth > 24)
            {
                dc.PushClip(new RectangleGeometry(new Rect(10, 9, labelWidth, 28)));
                dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(210, 22, 52, 76)), null, new Rect(10, 9, labelWidth, 27), 6, 6);
                dc.DrawText(text, new Point(22, 14));
                dc.Pop();
            }
            dc.Pop();
        }
    }

    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct Point { public int X, Y; }
        [DllImport("user32.dll")] internal static extern bool GetCursorPos(out Point point);
        [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] internal static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] internal static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] internal static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll")] internal static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr hwnd, int id);
        [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr hwnd, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLong64(IntPtr hwnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern int SetWindowLong32(IntPtr hwnd, int index, int value);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLong64(IntPtr hwnd, int index, IntPtr value);
        internal static IntPtr GetStyle(IntPtr hwnd) { return IntPtr.Size == 8 ? GetWindowLong64(hwnd, -20) : new IntPtr(GetWindowLong32(hwnd, -20)); }
        internal static void SetStyle(IntPtr hwnd, IntPtr style) { if (IntPtr.Size == 8) SetWindowLong64(hwnd, -20, style); else SetWindowLong32(hwnd, -20, style.ToInt32()); }
    }
}
