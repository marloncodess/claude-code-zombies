<#
.SYNOPSIS
  Demo for screenshots/videos: starts many short processes quickly (like a busy coding agent).
  On an AFFECTED PC every one of them stays in kernel memory until reboot - watch Task Manager.
  On a healthy PC nothing happens. Stops at -Count processes (default 60,000 = ~4 GB on an affected PC).
#>
param([int]$Count = 60000, [int]$Parallel = 8)
$per = [math]::Ceiling($Count / $Parallel)
$jobs = 1..$Parallel | ForEach-Object {
    Start-Job -ArgumentList $per -ScriptBlock {
        param($n)
        for ($i = 0; $i -lt $n; $i++) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe', '/c exit'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit(); $p.Dispose()
        }
    }
}
$t0 = Get-Date
while ($jobs | Where-Object State -eq 'Running') {
    Start-Sleep 5
    $os = Get-CimInstance Win32_OperatingSystem
    '{0:mm\:ss}  free RAM {1:N1} GB' -f ((Get-Date) - $t0), ($os.FreePhysicalMemory / 1MB)
}
$jobs | Remove-Job -Force
"Done: $Count processes started and exited."
