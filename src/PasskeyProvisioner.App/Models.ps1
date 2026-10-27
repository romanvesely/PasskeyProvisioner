# Data model for the enrollment grid. A compiled class is used because WPF only refreshes bound cells
# automatically when the row object implements INotifyPropertyChanged.

if (-not ([System.Management.Automation.PSTypeName]'PasskeyProvisioner.EnrollRow').Type) {
    Add-Type -ReferencedAssemblies 'System.dll' -TypeDefinition @'
using System.ComponentModel;

namespace PasskeyProvisioner
{
    public class EnrollRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;

        private int index;
        private string upn = "";
        private string serialId = "";
        private string status = "Pending";
        private string detail = "";
        private string graphId = "";

        private void Raise(string name)
        {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null) { handler(this, new PropertyChangedEventArgs(name)); }
        }

        public int Index { get { return index; } set { index = value; Raise("Index"); } }
        public string Upn { get { return upn; } set { upn = value; Raise("Upn"); } }
        public string SerialId { get { return serialId; } set { serialId = value; Raise("SerialId"); } }
        public string Detail { get { return detail; } set { detail = value; Raise("Detail"); } }
        public string GraphId { get { return graphId; } set { graphId = value; Raise("GraphId"); } }

        // Pending, Checking, WaitingForKey, Running, Registered, AlreadyRegistered, Failed, Skipped, Cancelled
        public string Status
        {
            get { return status; }
            set { status = value; Raise("Status"); Raise("StatusText"); }
        }

        public string StatusText
        {
            get
            {
                switch (status)
                {
                    case "Checking": return "Checking";
                    case "WaitingForKey": return "Insert key";
                    case "Running": return "Touch key";
                    case "Registered": return "Registered";
                    case "AlreadyRegistered": return "Already registered";
                    case "Failed": return "Failed";
                    case "Skipped": return "Skipped";
                    case "Cancelled": return "Cancelled";
                    default: return "Pending";
                }
            }
        }
    }
}
'@
}

# Title bar colors on Windows 11 (dark mode switch, caption, caption text and border color).
if (-not ([System.Management.Automation.PSTypeName]'PasskeyProvisioner.Dwm').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PasskeyProvisioner
{
    public static class Dwm
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        public static void Set(IntPtr hwnd, int attribute, int value)
        {
            try { DwmSetWindowAttribute(hwnd, attribute, ref value, 4); } catch { }
        }
    }
}
'@
}

# Key handling for the shortcuts and the bongo cat. Compiled code on purpose: a PowerShell handler on every key press adds
# a noticeable delay to typing and to the cat; here nothing but the small C# handler runs per key.
if (-not ([System.Management.Automation.PSTypeName]'PasskeyProvisioner.KeyHooks').Type) {
    Add-Type -ReferencedAssemblies 'PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace PasskeyProvisioner
{
    public class KeyHooks
    {
        // Raised only while Ctrl is the only modifier held (Ctrl+1, Ctrl+2, Ctrl+3, Ctrl+T).
        public event KeyEventHandler CtrlKeyDown;

        private const double MinDownMs = 70;   // a quick tap stays visible at least this long
        private readonly UIElement[] up = new UIElement[2];
        private readonly UIElement[] down = new UIElement[2];
        private readonly int[] count = new int[2];
        private readonly DateTime[] since = new DateTime[2];
        private readonly bool[] pending = new bool[2];
        private readonly Dictionary<Key, int> held = new Dictionary<Key, int>();
        private readonly DispatcherTimer timer;
        private bool nextLeft = true;

        public KeyHooks(Window window, UIElement upLeft, UIElement upRight, UIElement downLeft, UIElement downRight)
        {
            up[0] = upLeft; up[1] = upRight; down[0] = downLeft; down[1] = downRight;
            timer = new DispatcherTimer(DispatcherPriority.Input);
            timer.Interval = TimeSpan.FromMilliseconds(10);
            timer.Tick += OnTick;
            window.PreviewKeyDown += OnKeyDown;
            window.PreviewKeyUp += OnKeyUp;
            window.Deactivated += delegate { ReleaseAll(); };
        }

        private static Key RealKey(KeyEventArgs e)
        {
            if (e.Key == Key.System) { return e.SystemKey; }
            if (e.Key == Key.ImeProcessed) { return e.ImeProcessedKey; }
            return e.Key;
        }

        private static bool IsModifier(Key k)
        {
            return k == Key.LeftShift || k == Key.RightShift || k == Key.LeftCtrl || k == Key.RightCtrl ||
                   k == Key.LeftAlt || k == Key.RightAlt || k == Key.LWin || k == Key.RWin || k == Key.None;
        }

        private void SetDown(int side, bool isDown)
        {
            down[side].Visibility = isDown ? Visibility.Visible : Visibility.Hidden;   // Hidden, not Collapsed: no layout pass per key
            up[side].Visibility = isDown ? Visibility.Hidden : Visibility.Visible;
        }

        private void OnKeyDown(object sender, KeyEventArgs e)
        {
            if (CtrlKeyDown != null && Keyboard.Modifiers == ModifierKeys.Control) { CtrlKeyDown(sender, e); }
            if (e.Handled || e.IsRepeat) { return; }
            Key key = RealKey(e);
            if (IsModifier(key) || held.ContainsKey(key)) { return; }
            int side = nextLeft ? 0 : 1;
            nextLeft = !nextLeft;
            held[key] = side;
            count[side]++;
            since[side] = DateTime.UtcNow;
            pending[side] = false;
            SetDown(side, true);
        }

        private void OnKeyUp(object sender, KeyEventArgs e)
        {
            int side;
            Key key = RealKey(e);
            if (!held.TryGetValue(key, out side)) { return; }
            held.Remove(key);
            count[side]--;
            if (count[side] > 0) { return; }
            if ((DateTime.UtcNow - since[side]).TotalMilliseconds >= MinDownMs) { SetDown(side, false); }
            else { pending[side] = true; timer.Start(); }
        }

        private void OnTick(object sender, EventArgs e)
        {
            bool any = false;
            for (int side = 0; side < 2; side++)
            {
                if (!pending[side]) { continue; }
                if (count[side] == 0 && (DateTime.UtcNow - since[side]).TotalMilliseconds >= MinDownMs) { pending[side] = false; SetDown(side, false); }
                else { any = true; }
            }
            if (!any) { timer.Stop(); }
        }

        // Window lost the focus: key-up events will not arrive, so let go of everything.
        private void ReleaseAll()
        {
            held.Clear();
            for (int side = 0; side < 2; side++) { count[side] = 0; pending[side] = false; SetDown(side, false); }
            timer.Stop();
        }
    }
}
'@
}
