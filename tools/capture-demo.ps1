<#
.SYNOPSIS
  Records the demo for the README: Task Manager while thousands of short processes start and exit.
  On an affected PC the RAM fills up although no process owns it; on a fixed PC it stays flat.
  Run elevated with Task Manager closed or open. Writes PNG frames + GIF into -OutDir.

.EXAMPLE
  .\tools\capture-demo.ps1 -Label before -StopAtPercent 97
  .\tools\capture-demo.ps1 -Label after  -Processes 300000
#>
param(
    [string]$Label = 'demo',
    [int]$StopAtPercent = 97,      # stop when RAM in use reaches this
    [int]$Processes = 0,           # or stop after this many processes (0 = only the percent limit)
    [int]$MaxMinutes = 30,
    [int]$Parallel = 8,
    [int]$FrameSeconds = 3,
    [string]$OutDir = (Join-Path (Get-Location) 'demo-capture'),
    [switch]$TestTabs              # only take the two start screenshots
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, Microsoft.VisualBasic
if (-not ('Demo.Win' -as [type])) {
Add-Type @'
using System; using System.Runtime.InteropServices;
namespace Demo { public static class Win {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
}}
'@
}
[Demo.Win]::SetProcessDPIAware() | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null
$X0 = 40; $Y0 = 40; $WW = 1000; $WH = 760

function Get-Tm {
    $p = Get-Process Taskmgr -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    if (-not $p) { Start-Process taskmgr.exe; Start-Sleep 4; $p = Get-Process Taskmgr | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1 }
    $p.MainWindowHandle
}
function Show-Tm {
    $h = Get-Tm
    [Demo.Win]::ShowWindow($h, 9) | Out-Null
    [Demo.Win]::MoveWindow($h, $X0, $Y0, $WW, $WH, $true) | Out-Null
    [Demo.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Demo.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)  # ALT unlocks SetForegroundWindow
    [Demo.Win]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 600; $h
}
# tab positions relative to the window at 1000x760 (Task Manager "More details" view)
function Select-Tab([string]$tab) {
    $h = Show-Tm
    switch ($tab) {
        'Processes' { [Demo.Win]::Click($X0 + 41, $Y0 + 65) }
        'Memory' { [Demo.Win]::Click($X0 + 113, $Y0 + 64); Start-Sleep 1; [Demo.Win]::Click($X0 + 120, $Y0 + 165) }
    }
    Start-Sleep 2; $h
}
function Save-Shot([string]$file) {
    $h = Get-Tm
    if ([Demo.Win]::IsIconic($h)) { Show-Tm | Out-Null }
    $r = New-Object Demo.Win+RECT; [Demo.Win]::GetWindowRect($h, [ref]$r) | Out-Null
    $bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T); $g = [Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc(); [Demo.Win]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
    $bmp.Save($file); $g.Dispose(); $bmp.Dispose()
}
function Get-UsedPercent { $os = Get-CimInstance Win32_OperatingSystem; [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 1) }
function Get-InUseGB {
    # like Task Manager "In use": total minus available (free + standby), via GlobalMemoryStatusEx
    $ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
    [math]::Round(($ci.TotalPhysicalMemory - $ci.AvailablePhysicalMemory) / 1GB, 1)
}

$total = [math]::Round((New-Object Microsoft.VisualBasic.Devices.ComputerInfo).TotalPhysicalMemory / 1GB, 1)
Select-Tab 'Processes' | Out-Null; Save-Shot (Join-Path $OutDir "$Label-processes-start.png")
Select-Tab 'Memory' | Out-Null; Save-Shot (Join-Path $OutDir "$Label-memory-start.png")
if ($TestTabs) { "Screenshots in $OutDir"; return }
$startInUse = Get-InUseGB
"Start: in use $startInUse of $total GB"

$per = if ($Processes -gt 0) { [math]::Ceiling($Processes / $Parallel) } else { [int]::MaxValue }
$jobs = 1..$Parallel | ForEach-Object {
    $cf = Join-Path $OutDir ("$Label-count-$_.txt")
    Start-Job -ArgumentList $per, $cf -ScriptBlock {
        param($n, $cf)
        for ($i = 0; $i -lt $n; $i++) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe', '/c exit'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit(); $p.Dispose()
            if ($i % 200 -eq 0) { [IO.File]::WriteAllText($cf, [string]$i) }
        }
        [IO.File]::WriteAllText($cf, [string]$n)
    }
}
function Get-Started { $sum = 0; foreach ($f in Get-ChildItem $OutDir -Filter "$Label-count-*.txt" -ErrorAction SilentlyContinue) { try { $sum += [int][IO.File]::ReadAllText($f.FullName) } catch {} }; $sum }
$t0 = Get-Date; $i = 0; $log = Join-Path $OutDir "$Label-log.csv"; Set-Content $log 'Sekunden;InUseGB;Prozent;Prozesse'
try {
    while ($jobs | Where-Object State -eq 'Running') {
        Save-Shot (Join-Path $OutDir ('{0}-f{1:D4}.png' -f $Label, $i)); $i++
        $inUse = Get-InUseGB; $pct = [math]::Round(100 * $inUse / $total, 1)
        Add-Content $log ('{0};{1};{2};{3}' -f [int]((Get-Date) - $t0).TotalSeconds, $inUse, $pct, (Get-Started))
        if ($pct -ge $StopAtPercent) { "Reached $pct % in use - stopping"; break }
        if (((Get-Date) - $t0).TotalMinutes -ge $MaxMinutes) { 'Time limit - stopping'; break }
        Start-Sleep -Seconds $FrameSeconds
    }
} finally { $jobs | Stop-Job; $jobs | Remove-Job -Force }
for ($k = 0; $k -lt 6; $k++) { Save-Shot (Join-Path $OutDir ('{0}-f{1:D4}.png' -f $Label, $i)); $i++; Start-Sleep -Seconds $FrameSeconds }
Save-Shot (Join-Path $OutDir "$Label-memory-end.png")
Select-Tab 'Processes' | Out-Null; Save-Shot (Join-Path $OutDir "$Label-processes-end.png")
"End: in use $(Get-InUseGB) of $total GB after $([int]((Get-Date) - $t0).TotalSeconds) s, $i frames, $(Get-Started) processes started"
