# Win32 helpers to find, move and close windows of other applications.
#
# Used for the Windows security key dialog ("Windows Hello setup"): opening ms-settings:signinoptions-launchsecuritykeyenrollment
# opens the large Settings window plus this small dialog, which is owned by it. The tool moves the Settings window off
# screen (minimizing would hide the owned dialog too) and shows the small dialog centered over its own window.
# Only windows that appeared after the tool opened the link are touched, and only user level windows (no elevation).

if (-not ([System.Management.Automation.PSTypeName]'PasskeyProvisioner.WindowTools').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace PasskeyProvisioner
{
    public static class WindowTools
    {
        private delegate bool EnumProc(IntPtr h, IntPtr l);

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr h, int index, int value);
        [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
        [DllImport("user32.dll")] private static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO info);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int L, T, R, B; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MONITORINFO { public int Size; public RECT Monitor; public RECT Work; public uint Flags; }

        private const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

        // Handles of all visible top-level windows that have a title.
        public static long[] VisibleTopLevel()
        {
            List<long> list = new List<long>();
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                if (IsWindowVisible(h) && GetWindowTextLength(h) > 0) { list.Add(h.ToInt64()); }
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        public static string ClassName(IntPtr h)
        {
            StringBuilder sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            return sb.ToString();
        }

        public static IntPtr OwnerOf(IntPtr h) { return GetWindow(h, 4); }   // GW_OWNER

        public static int ProcessIdOf(IntPtr h)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            return (int)pid;
        }

        public static string TitleOf(IntPtr h)
        {
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            return sb.ToString();
        }

        // The console window of this process (zero when it has none, for example a compiled GUI program).
        public static IntPtr ConsoleWindow() { return GetConsoleWindow(); }

        public static bool IsVisibleWindow(IntPtr h) { return h != IntPtr.Zero && IsWindow(h) && IsWindowVisible(h); }

        // left, top, width, height in physical pixels
        public static int[] RectOf(IntPtr h)
        {
            RECT r;
            GetWindowRect(h, out r);
            return new int[] { r.L, r.T, r.R - r.L, r.B - r.T };
        }

        // work area (without taskbar) of the monitor that shows the window: left, top, width, height
        public static int[] WorkAreaOf(IntPtr h)
        {
            MONITORINFO info = new MONITORINFO();
            info.Size = Marshal.SizeOf(typeof(MONITORINFO));
            IntPtr mon = MonitorFromWindow(h, 2);   // MONITOR_DEFAULTTONEAREST
            GetMonitorInfo(mon, ref info);
            return new int[] { info.Work.L, info.Work.T, info.Work.R - info.Work.L, info.Work.B - info.Work.T };
        }

        public static void MoveTo(IntPtr h, int x, int y)
        {
            SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }

        public static void MoveOffScreen(IntPtr h) { MoveTo(h, -32000, -32000); }

        // Fully transparent, still a normal window (unlike moving or minimizing it, this does not stop Windows from building the
        // dialog that is owned by it).
        public static void MakeInvisible(IntPtr h)
        {
            SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80000);   // GWL_EXSTYLE, WS_EX_LAYERED
            SetLayeredWindowAttributes(h, 0, 0, 2);                    // LWA_ALPHA, alpha 0
        }

        public static bool IsInvisible(IntPtr h)
        {
            if ((GetWindowLong(h, -20) & 0x80000) == 0) { return false; }
            uint key, flags; byte alpha;
            return GetLayeredWindowAttributes(h, out key, out alpha, out flags) && alpha == 0;
        }

        public static void MakeVisible(IntPtr h)
        {
            SetLayeredWindowAttributes(h, 0, 255, 2);
            SetWindowLong(h, -20, GetWindowLong(h, -20) & ~0x80000);
        }

        // Above all normal windows (including the tool's window), without staying topmost.
        public static void BringToFront(IntPtr h)
        {
            SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            SetForegroundWindow(h);
        }

        // True when a child window of this frame belongs to a process with this name (for example SystemSettings behind an
        // ApplicationFrameWindow). Language independent, unlike the window title.
        public static bool HostsProcess(IntPtr frame, string processName)
        {
            bool found = false;
            EnumChildWindows(frame, delegate (IntPtr c, IntPtr l)
            {
                uint pid;
                GetWindowThreadProcessId(c, out pid);
                try
                {
                    if (string.Equals(System.Diagnostics.Process.GetProcessById((int)pid).ProcessName, processName, StringComparison.OrdinalIgnoreCase)) { found = true; return false; }
                }
                catch { }
                return true;
            }, IntPtr.Zero);
            return found;
        }
        public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }   // WM_CLOSE
    }
}
'@
}
