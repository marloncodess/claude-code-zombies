<#
.SYNOPSIS
  Records the Task Manager window (open it first) for -Seconds and writes an animated GIF.
  Needs ffmpeg in PATH. Usage: .\tools\record-taskmanager.ps1 -Seconds 240 -Out assets\taskmanager.gif
#>
param([int]$Seconds = 240, [string]$Out = 'taskmanager.gif', [int]$Fps = 2, [int]$Speed = 8)
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Win { [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[Win]::SetProcessDPIAware() | Out-Null
$tm = Get-Process Taskmgr -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $tm) { 'Open Task Manager first.'; exit 1 }
$r = New-Object Win+RECT; [Win]::GetWindowRect($tm.MainWindowHandle, [ref]$r) | Out-Null
$w = ($r.R - $r.L) - (($r.R - $r.L) % 2); $h = ($r.B - $r.T) - (($r.B - $r.T) % 2)
$raw = [IO.Path]::ChangeExtension($Out, '.mp4')
ffmpeg -y -loglevel error -f gdigrab -framerate $Fps -offset_x $r.L -offset_y $r.T -video_size "${w}x$h" -t $Seconds -i desktop -pix_fmt yuv420p $raw
$vf = "setpts=PTS/$Speed,fps=10,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
ffmpeg -y -loglevel error -i $raw -vf $vf -loop 0 $Out
"Written: $Out  (raw video: $raw)"
