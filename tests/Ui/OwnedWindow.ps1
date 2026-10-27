# Stand-in for a pop-up window of another program, used by the UI tests. Runs in its own process.
# With -OwnerHandle it is owned by the given window, like the Microsoft sign-in dialog is owned by the program that asks.
# It opens at the top-left corner of the screen so a test can tell whether the tool moved it.
param(
    [long]$OwnerHandle = 0,
    [string]$Title = 'PasskeyProvisionerSignInProbe',
    [int]$Seconds = 30
)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$w = New-Object System.Windows.Window
$w.Title = $Title
$w.Width = 420
$w.Height = 480
$w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$w.Left = 5
$w.Top = 5
if ($OwnerHandle -ne 0) { (New-Object System.Windows.Interop.WindowInteropHelper $w).Owner = [IntPtr]$OwnerHandle }
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($Seconds)
$timer.Add_Tick({ $w.Close() })
$timer.Start()
[void]$w.ShowDialog()
