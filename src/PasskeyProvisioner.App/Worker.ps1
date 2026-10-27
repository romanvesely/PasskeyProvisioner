[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal UI helper functions, not cmdlets')]
param()

# Background execution for the GUI.
#
# The window thread must never block on Graph calls, module installation or the sign-in. Long operations run in
# a separate STA runspace (the worker). The window thread waits for a result with Wait-UiTask, which keeps the
# message loop running (dispatcher frame), so painting, clicks and timers stay alive.
#
# Two runspaces exist:
#   Worker   - modules (Graph, DSInternals), Connect-MgGraph and every Entra call. One operation at a time.
#   Detector - polls Get-FidoKeyDevice. Needs only the Core module, never loads Graph.
# Keeping Graph out of the window runspace also avoids module version conflicts there.

function New-AppRunspace {
    param(
        [Parameter(Mandatory)][string]$CoreModulePath,
        [Parameter(Mandatory)][object]$LogQueue,
        [string]$SimulationScript,
        [switch]$ForwardLog
    )
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('CoreModulePath', $CoreModulePath)
    $rs.SessionStateProxy.SetVariable('LogQueue', $LogQueue)
    $rs.SessionStateProxy.SetVariable('ForwardLog', [bool]$ForwardLog)
    $rs.SessionStateProxy.SetVariable('SimulationScript', $SimulationScript)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction Stop } catch { $null = $_ }
            Import-Module -Name $CoreModulePath -Force -ErrorAction Stop
            if ($SimulationScript) { . $SimulationScript }
            if ($ForwardLog) {
                # Messages from the worker travel through the queue; the window thread logs them (single log path).
                Set-PasskeyProvisionerLogSink -Sink {
                    param($Message, $Level, $Line)
                    $null = $Line
                    $LogQueue.Enqueue([pscustomobject]@{ Message = $Message; Level = $Level })
                }
            }
        })
    try {
        [void]$ps.Invoke()
        if ($ps.HadErrors) { throw ($ps.Streams.Error | Select-Object -First 1).ToString() }
    } finally {
        $ps.Dispose()
    }
    return $rs
}

function Invoke-UiPump {
    <# Processes pending window messages once (the dispatcher equivalent of a message loop iteration). #>
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $done = { $frame.Continue = $false }.GetNewClosure()
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, [System.Action]$done)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Invoke-AppRunspace {
    <#
    .SYNOPSIS
        Runs a scriptblock in the given runspace and returns its output. The window stays responsive while waiting.
    .DESCRIPTION
        Terminating errors of the scriptblock are rethrown with their original message. OnTick runs on the window thread
        about every 15 ms while waiting (used to watch for pop-up windows).
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.Runspace]$Runspace,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @(),
        [scriptblock]$OnTick
    )
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $Runspace
        [void]$ps.AddScript($Script.ToString())
        foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
        $async = $ps.BeginInvoke()
        while (-not $async.IsCompleted) {
            Invoke-UiPump
            if ($OnTick) { & $OnTick }
            Start-Sleep -Milliseconds 15
        }
        try {
            return $ps.EndInvoke($async)
        } catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            throw $inner.Message
        }
    } finally {
        $ps.Dispose()
    }
}

function Start-AppRunspaceTask {
    <# Starts a scriptblock without waiting. Returns an object to poll with Receive-AppRunspaceTask. #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.Runspace]$Runspace,
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $ps = [powershell]::Create()
    $ps.Runspace = $Runspace
    [void]$ps.AddScript($Script.ToString())
    [pscustomobject]@{ Shell = $ps; Async = $ps.BeginInvoke() }
}

function Receive-AppRunspaceTask {
    <# Returns the output of a finished task and disposes it. Returns $null while the task is still running. #>
    param([Parameter(Mandatory)][object]$Task)
    if (-not $Task.Async.IsCompleted) { return $null }
    try {
        return , @($Task.Shell.EndInvoke($Task.Async))
    } catch {
        return , @()
    } finally {
        $Task.Shell.Dispose()
    }
}
