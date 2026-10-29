<#
.SYNOPSIS
  zombieprobe - find out if Windows keeps your exited processes in kernel memory, and which driver does it.

.DESCRIPTION
  Some kernel drivers take a reference on every process and never release it. Each process that exits then
  stays in kernel memory (about 50-100 KB) until the next reboot. Task Manager shows the RAM as "in use",
  but no process owns it. Tools that start many short processes (Claude Code, Cursor, Codex, git, build
  tools, test runners) turn this small leak into gigabytes per hour.

  Commands:
    test               30-second check (default). No admin needed; admin adds the system-wide count.
    scan               lists third-party kernel drivers and devices, flags known culprits.
    hunt               finds a guilty DEVICE driver without rebooting: disables one device at a time,
                       re-tests, re-enables. Asks before each device. Admin.
    bisect start       finds a guilty NON-device driver by binary search over reboots. Admin.
    bisect continue    run after each reboot until the culprit is named.
    bisect status      shows the current bisect round.
    restore            undoes everything hunt/bisect changed.
    report             writes zombieprobe-report.md to paste into a GitHub issue.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\zombieprobe.ps1
  powershell -ExecutionPolicy Bypass -File .\zombieprobe.ps1 hunt
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('test', 'scan', 'hunt', 'bisect', 'restore', 'report', 'help')][string]$Command = 'test',
    [Parameter(Position = 1)][ValidateSet('start', 'continue', 'status', 'restore')][string]$Step = 'status',
    [int]$Count = 50,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$IncludeActiveDisplay,
    [switch]$IncludeActiveNetwork,
    [string]$StateDir = ''
)
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$RepoUrl = 'https://github.com/marlondiebold123/claude-code-zombies'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $StateDir) { $StateDir = Join-Path $env:ProgramData 'zombieprobe' }
$HuntState = Join-Path $StateDir 'hunt-state.json'
$BisectState = Join-Path $StateDir 'bisect-state.json'
$ServicesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services'

# ---------------------------------------------------------------- native helpers
if (-not ('ZombieProbe.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
namespace ZombieProbe {
public static class Native {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
  [DllImport("psapi.dll", SetLastError=true)] static extern bool EnumDeviceDrivers([Out] IntPtr[] bases, int cb, out int needed);
  [DllImport("psapi.dll", CharSet=CharSet.Unicode)] static extern int GetDeviceDriverFileNameW(IntPtr b, StringBuilder s, int n);

  // 0 = object gone (healthy), 1 = zombie (exited but still in kernel), 2 = running (pid reused)
  public static int ProcessState(int pid) {
    IntPtr h = OpenProcess(0x1000, false, pid);
    if (h == IntPtr.Zero) return 0;
    uint code; GetExitCodeProcess(h, out code); CloseHandle(h);
    return code == 259 ? 2 : 1;
  }

  // live kernel objects with pool tag 'Proc' (= process objects incl. zombies); -1 if not readable
  public static long ProcObjects() {
    int size = 4 * 1024 * 1024, ret = 0, st; IntPtr buf = IntPtr.Zero;
    try {
      while (true) {
        buf = Marshal.AllocHGlobal(size);
        st = NtQuerySystemInformation(22, buf, size, out ret);
        if (st == unchecked((int)0xC0000004)) { Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; size = ret + 1024 * 1024; continue; }
        break;
      }
      if (st != 0) return -1;
      int n = Marshal.ReadInt32(buf, 0);
      for (int i = 0; i < n; i++) {
        int o = 8 + i * 40;
        if (Marshal.ReadInt32(buf, o) != 0x636f7250) continue; // "Proc"
        uint pa = (uint)Marshal.ReadInt32(buf, o + 4), pf = (uint)Marshal.ReadInt32(buf, o + 8);
        uint na = (uint)Marshal.ReadInt32(buf, o + 24), nf = (uint)Marshal.ReadInt32(buf, o + 28);
        return (long)unchecked(pa - pf) + (long)unchecked(na - nf);
      }
      return -1;
    } catch { return -1; }
    finally { if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf); }
  }

  public static string[] LoadedDrivers() {
    var bases = new IntPtr[2048]; int needed;
    if (!EnumDeviceDrivers(bases, bases.Length * IntPtr.Size, out needed)) return new string[0];
    int n = Math.Min(needed / IntPtr.Size, bases.Length); var res = new List<string>();
    for (int i = 0; i < n; i++) { var sb = new StringBuilder(1024); if (GetDeviceDriverFileNameW(bases[i], sb, sb.Capacity) > 0) res.Add(sb.ToString()); }
    return res.ToArray();
  }
}
}
'@
}

# ---------------------------------------------------------------- small utilities
function Write-Head([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }
function Write-Good([string]$t) { Write-Host $t -ForegroundColor Green }
function Write-Bad([string]$t) { Write-Host $t -ForegroundColor Red }
function Write-Warn2([string]$t) { Write-Host $t -ForegroundColor Yellow }
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Admin { if (-not (Test-Admin)) { Write-Bad 'This command needs an elevated PowerShell (Run as administrator).'; exit 2 } }
function Save-Json($obj, [string]$path) { New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null; $obj | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8 }
function Read-Json([string]$path) { if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { $null } }
function Confirm-Step([string]$question) {
    if ($Yes) { return $true }
    $a = Read-Host "$question [y/N]"
    return ($a -match '^(y|j)')
}
function Get-OsLine {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $name = $cv.ProductName; if ([int]$cv.CurrentBuild -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }
    '{0} {1}, build {2}.{3}' -f $name, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR
}
function Get-BootTime { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }

function Convert-DriverPath([string]$p) {
    $p = $p -replace '^\\SystemRoot\\', "$env:SystemRoot\" -replace '^\\\?\?\\', '' -replace '^\\Windows\\', "$env:SystemRoot\"
    if ($p -match '^(?i)system32\\') { $p = Join-Path $env:SystemRoot $p }
    if ($p -notmatch '^[A-Za-z]:\\') { $p = Join-Path "$env:SystemRoot\System32\drivers" ([IO.Path]::GetFileName($p)) }
    $p
}

$script:SigCache = @{}
function Test-MicrosoftFile([string]$path, [string]$company) {
    if ($company -match 'Microsoft') { return $true }
    if ($company) { return $false }
    if ($script:SigCache.ContainsKey($path)) { return $script:SigCache[$path] }
    $ms = $false
    # inbox drivers are signed "CN=Microsoft Windows"; third-party WHQL/attestation drivers carry
    # "Microsoft Windows Hardware Compatibility Publisher" and must count as third-party
    try { $subj = [string](Get-AuthenticodeSignature -FilePath $path).SignerCertificate.Subject; $ms = ($subj -match 'CN=Microsoft Windows(,| Production)' -and $subj -notmatch 'Hardware Compatibility') } catch {}
    $script:SigCache[$path] = $ms; $ms
}

# ---------------------------------------------------------------- the probe
function Invoke-Probe([int]$n = 50, [int]$waitSeconds = 5) {
    $ids = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $n; $i++) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe', '/c exit'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit(); $ids.Add($p.Id); $p.Dispose()
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Seconds $waitSeconds
    $z = 0; $reused = 0
    foreach ($id in $ids) { switch ([ZombieProbe.Native]::ProcessState($id)) { 1 { $z++ } 2 { $reused++ } } }
    $valid = [math]::Max(1, $n - $reused)
    [pscustomobject]@{ Started = $n; Zombies = $z; Reused = $reused; Percent = [math]::Round(100 * $z / $valid) }
}
function Get-Verdict($probe) {
    if ($probe.Percent -ge 80) { 'LEAK' } elseif ($probe.Percent -le 10) { 'OK' } else { 'UNCLEAR' }
}
function Get-SystemCount {
    $obj = [ZombieProbe.Native]::ProcObjects()
    $live = @(Get-Process).Count
    if ($obj -lt 0) { return $null }
    $z = [math]::Max(0, $obj - $live)
    [pscustomobject]@{ Objects = $obj; Live = $live; Zombies = $z; EstGB = [math]::Round($z * 64KB / 1GB, 1) }
}

# ---------------------------------------------------------------- inventory
function Get-KnownCulprits {
    $f = Join-Path $ScriptDir 'known-culprits.json'
    if (Test-Path $f) { return @((Get-Content $f -Raw | ConvertFrom-Json).culprits) }
    @([pscustomobject]@{ driver = 'amdkmdag.sys'; vendor = 'AMD'; device = 'AMD Radeon integrated graphics'; versions = @('31.0.24002.92'); fix = 'Disable the unused iGPU in Device Manager, or update the AMD driver and re-test.' })
}
function Find-Known($culprits, [string]$file, [string]$ver) {
    foreach ($c in $culprits) {
        if ($c.driver -ne $file) { continue }
        $exact = @($c.versions) -contains $ver
        return [pscustomobject]@{ Entry = $c; ExactVersion = $exact }
    }
    $null
}

function Get-DriverInventory {
    $svcByImage = @{}
    foreach ($k in Get-ChildItem $ServicesKey -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.ImagePath -or $p.Type -notin 1, 2, 8) { continue }
        $img = (Convert-DriverPath ([string]$p.ImagePath)).ToLowerInvariant()
        $svcByImage[$img] = [pscustomobject]@{ Name = $k.PSChildName; Start = [int]$p.Start; Group = [string]$p.Group }
    }
    $pnp = @{}
    foreach ($e in Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue) {
        if (-not $e.Service) { continue }
        $key = $e.Service.ToLowerInvariant(); if (-not $pnp.ContainsKey($key)) { $pnp[$key] = @() }
        $pnp[$key] += $e
    }
    $culprits = Get-KnownCulprits
    foreach ($raw in [ZombieProbe.Native]::LoadedDrivers()) {
        $path = Convert-DriverPath $raw
        $vi = $null; try { $vi = (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo } catch {}
        $company = if ($vi) { [string]$vi.CompanyName } else { '' }
        if (Test-Path -LiteralPath $path) { if (Test-MicrosoftFile $path $company) { continue } } elseif (-not $company) { continue }
        $file = [IO.Path]::GetFileName($path).ToLowerInvariant()
        $ver = if ($vi -and $vi.FileVersion) { ($vi.FileVersion -split '\s')[0] } else { '' }
        $svc = $svcByImage[$path.ToLowerInvariant()]
        $devs = if ($svc -and $pnp.ContainsKey($svc.Name.ToLowerInvariant())) { @($pnp[$svc.Name.ToLowerInvariant()]) } else { @() }
        [pscustomobject]@{
            File = $file; Path = $path; Vendor = $company; Version = $ver
            Description = if ($vi) { [string]$vi.FileDescription } else { '' }
            Service = if ($svc) { $svc.Name } else { '' }; Start = if ($svc) { $svc.Start } else { $null }; Group = if ($svc) { $svc.Group } else { '' }
            Devices = $devs; Known = (Find-Known $culprits $file $ver)
        }
    }
}

function Get-DisabledKnownDevices {
    $files = @(Get-KnownCulprits | ForEach-Object { $_.driver })
    foreach ($e in Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue) {
        if (-not $e.Service -or $e.Status -eq 'OK') { continue }
        $p = Get-ItemProperty "$ServicesKey\$($e.Service)" -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.ImagePath) { continue }
        $file = [IO.Path]::GetFileName([string]$p.ImagePath).ToLowerInvariant()
        if ($files -contains $file) { [pscustomobject]@{ Name = $e.Name; Driver = $file; Status = $e.Status } }
    }
}

# ---------------------------------------------------------------- commands
function Invoke-Test {
    Write-Head "zombieprobe $Version  -  $(Get-OsLine)"
    Write-Host "Starting $Count short processes (cmd /c exit), closing every handle, waiting 5 s ..."
    $pr = Invoke-Probe $Count
    Write-Host ("Still in kernel memory afterwards: {0} of {1}" -f $pr.Zombies, ($pr.Started - $pr.Reused))
    $sys = Get-SystemCount
    if ($sys) {
        Write-Host ("System-wide: {0:N0} process objects for {1:N0} running processes -> {2:N0} zombies (~{3} GB, est.)" -f $sys.Objects, $sys.Live, $sys.Zombies, $sys.EstGB)
    } elseif (-not (Test-Admin)) { Write-Host 'System-wide count: run as administrator to see it.' }
    $v = Get-Verdict $pr
    Write-Host ''
    switch ($v) {
        'LEAK' {
            Write-Bad 'RESULT: LEAK. Windows keeps exited processes in kernel memory on this PC.'
            Write-Host 'Every process that ends (each agent tool call starts several) stays until reboot.'
            Write-Host 'Next:  .\zombieprobe.ps1 scan    (suspicious drivers, known culprits)'
            Write-Host '       .\zombieprobe.ps1 hunt    (find the device driver, no reboot, admin)'
        }
        'OK' { Write-Good 'RESULT: OK. Exited processes are freed normally. This leak is not your problem.' }
        default { Write-Warn2 'RESULT: UNCLEAR. Part of the processes stayed. Run the test again in a minute.' }
    }
    $pr
}

function Invoke-Scan {
    Write-Head "Third-party kernel drivers loaded on this PC  ($(Get-OsLine))"
    $inv = @(Get-DriverInventory)
    $rows = foreach ($d in $inv) {
        [pscustomobject]@{
            Known = if ($d.Known) { if ($d.Known.ExactVersion) { 'KNOWN!' } else { 'known*' } } else { '' }
            Driver = $d.File; Vendor = $d.Vendor; Version = $d.Version
            Device = ((@($d.Devices) | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')
            Service = $d.Service
        }
    }
    $rows | Sort-Object @{ e = { $_.Known -eq '' } }, Vendor, Driver | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    $hits = @($inv | Where-Object Known)
    foreach ($h in $hits) {
        $tag = if ($h.Known.ExactVersion) { 'exact version match' } else { 'same driver, other version - re-test' }
        Write-Bad ("Known culprit: {0} {1} ({2}) - {3}" -f $h.File, $h.Version, $h.Known.Entry.vendor, $tag)
        Write-Host ("  Fix: {0}" -f $h.Known.Entry.fix)
    }
    foreach ($d in @(Get-DisabledKnownDevices)) { Write-Good ("Known culprit device is switched off already: {0} ({1}) - status {2}" -f $d.Name, $d.Driver, $d.Status) }
    if (-not $hits) { Write-Host 'No known culprit loaded. Use "hunt" (devices) and "bisect" (other drivers) to find yours.' }
    Write-Host '"known*" = same driver file, version not confirmed yet. Please report your result.'
    $inv
}

$SafeClasses = @('DISPLAY', 'MEDIA', 'NET', 'BLUETOOTH', 'CAMERA', 'IMAGE', 'SENSOR', 'BIOMETRIC', 'PRINTER', 'SMARTCARDREADER', 'EXTENSION', 'SOFTWAREDEVICE')
function Get-HuntCandidates {
    $active = @{}
    foreach ($vc in Get-CimInstance Win32_VideoController) { if ($vc.ConfigManagerErrorCode -eq 0 -and $vc.CurrentHorizontalResolution) { $active[$vc.PNPDeviceID] = $true } }
    $netUp = @{}
    foreach ($a in Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') { $netUp[$a.PnPDeviceID] = $true }
    $inv = @(Get-DriverInventory)
    $out = foreach ($d in $inv) {
        $devs = @($d.Devices | Where-Object { $_.Status -eq 'OK' -and $SafeClasses -contains ([string]$_.PNPClass).ToUpperInvariant() })
        if (-not $devs) { continue }
        $skip = ''
        if (($devs | Where-Object { $active[$_.PNPDeviceID] }) -and -not $IncludeActiveDisplay) { $skip = 'drives a monitor (use -IncludeActiveDisplay)' }
        if (($devs | Where-Object { $netUp[$_.PNPDeviceID] }) -and -not $IncludeActiveNetwork) { $skip = 'active network connection (use -IncludeActiveNetwork)' }
        [pscustomobject]@{ Driver = $d.File; Version = $d.Version; Vendor = $d.Vendor; Class = ([string]$devs[0].PNPClass); Devices = $devs; Skip = $skip; Known = [bool]$d.Known }
    }
    @($out | Sort-Object @{ e = { -not $_.Known } }, @{ e = { $_.Class -ne 'Display' } }, Driver)
}

function Invoke-Hunt {
    Assert-Admin
    Write-Head 'hunt: test device drivers one at a time (no reboot)'
    $base = Invoke-Probe 30
    Write-Host ("Baseline: {0} of {1} processes stay as zombies." -f $base.Zombies, ($base.Started - $base.Reused))
    if ((Get-Verdict $base) -ne 'LEAK') { Write-Good 'No leak right now - nothing to hunt.'; if (-not $DryRun) { return } }
    $cands = Get-HuntCandidates
    if (-not $cands) { Write-Warn2 'No third-party device drivers that can be switched off safely. Try: bisect start'; return }
    Write-Host 'Candidates (each device is switched off for ~15 s and switched back on):'
    foreach ($c in $cands) { Write-Host ('  {0,-22} {1,-16} {2,-10} {3}{4}' -f $c.Driver, $c.Version, $c.Class, (($c.Devices | ForEach-Object Name) -join ', '), $(if ($c.Skip) { "  [skip: $($c.Skip)]" } else { '' })) }
    if ($DryRun) { Write-Warn2 'DryRun: nothing changed.'; return }
    foreach ($c in $cands) {
        if ($c.Skip) { continue }
        $names = ($c.Devices | ForEach-Object Name) -join ', '
        if (-not (Confirm-Step "Switch off '$names' ($($c.Driver)) for a moment?")) { continue }
        $ids = @($c.Devices | ForEach-Object PNPDeviceID)
        Save-Json ([pscustomobject]@{ disabled = $ids; driver = $c.Driver; time = (Get-Date).ToString('s') }) $HuntState
        $kept = $false
        try {
            foreach ($id in $ids) { Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop }
            Start-Sleep -Seconds 5
            $still = @($ids | Where-Object { (Get-PnpDevice -InstanceId $_).Status -eq 'OK' })
            if ($still) { Write-Warn2 "  could not switch off without a reboot - skipped"; continue }
            $pr = Invoke-Probe 30
            Write-Host ("  {0}: {1} of {2} zombies" -f $c.Driver, $pr.Zombies, ($pr.Started - $pr.Reused))
            if ((Get-Verdict $pr) -eq 'OK') {
                Write-Host ''
                Write-Bad ("FOUND IT: {0} {1} ({2}) - device: {3}" -f $c.Driver, $c.Version, $c.Vendor, $names)
                Write-Host 'Fix options: update this driver and re-run the test, or keep the device disabled if you do not need it.'
                Write-Host ("Please report it: {0}/issues  (.\zombieprobe.ps1 report)" -f $RepoUrl)
                if (Confirm-Step 'Keep this device disabled now (survives reboots, undo with: restore)?') { $kept = $true }
                return
            }
        } finally {
            if (-not $kept) { foreach ($id in $ids) { try { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop } catch { Write-Warn2 "  could not re-enable $id - run: restore" } } ; [IO.File]::Delete($HuntState) }
            else { Save-Json ([pscustomobject]@{ disabled = $ids; driver = $c.Driver; kept = $true; time = (Get-Date).ToString('s') }) $HuntState }
        }
    }
    Write-Warn2 'No device driver was the cause. Next: .\zombieprobe.ps1 bisect start   (non-device drivers, needs reboots)'
}

$BootCritical = 'Boot|Bus Extender|SCSI|Port|Primary Disk|File System|FSFilter (Bottom|Encryption|Virtualization|Compression)|Filter$|Base|PNP Filter|Keyboard|Pointer|Video Init'
function Get-BisectCandidates {
    $pnpServices = @{}
    foreach ($e in Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue) { if ($e.Service) { $pnpServices[$e.Service.ToLowerInvariant()] = $true } }
    @(Get-DriverInventory | Where-Object {
            $_.Service -and $_.Start -in 1, 2, 3 -and -not $pnpServices.ContainsKey($_.Service.ToLowerInvariant()) -and
            $_.Group -notmatch $BootCritical -and $_.Description -notmatch '(?i)storage|nvme|raid|disk|encrypt|bitlocker|veracrypt|anti-?cheat'
        } | Sort-Object @{ e = { -not $_.Known } }, File)
}
function Set-Start([string]$svc, [int]$v) { Set-ItemProperty "$ServicesKey\$svc" -Name Start -Value $v -Type DWord }
function Get-LoadedSet { $h = @{}; foreach ($p in [ZombieProbe.Native]::LoadedDrivers()) { $h[[IO.Path]::GetFileName((Convert-DriverPath $p)).ToLowerInvariant()] = $true }; $h }

function Start-BisectRound($st) {
    $s = @($st.suspects)
    $half = if ($st.confirm) { $s } else { @($s | Select-Object -First ([math]::Ceiling($s.Count / 2))) }
    foreach ($svc in $half) { Set-Start $svc 4 }
    $st.disabled = $half; $st.round = [int]$st.round + 1; $st.actionTime = (Get-Date).ToString('o')
    Save-Json $st $BisectState
    Write-Host ("Round {0}: switched off {1} of {2} suspects for the next boot: {3}" -f $st.round, $half.Count, $s.Count, ($half -join ', '))
    Write-Warn2 'Reboot now. After logging in, run (as administrator):  .\zombieprobe.ps1 bisect continue'
    Write-Host 'Undo at any time:  .\zombieprobe.ps1 restore'
}
function Restore-Bisect($st) {
    foreach ($p in $st.original.PSObject.Properties) { try { Set-Start $p.Name ([int]$p.Value) } catch {} }
}

function Invoke-Bisect {
    Assert-Admin
    $st = Read-Json $BisectState
    switch ($Step) {
        'status' {
            if (-not $st) { Write-Host 'No bisect running. Start with: .\zombieprobe.ps1 bisect start'; return }
            Write-Host ("Round {0}. Suspects ({1}): {2}" -f $st.round, @($st.suspects).Count, (@($st.suspects) -join ', '))
            Write-Host ("Switched off for this boot: {0}" -f (@($st.disabled) -join ', '))
            foreach ($h in @($st.history)) { Write-Host ("  round {0}: off={1} -> {2}" -f $h.round, ($h.disabled -join ','), $h.result) }
        }
        'restore' { if ($st) { Restore-Bisect $st; [IO.File]::Delete($BisectState); Write-Good 'All driver start values restored. Reboot to apply.' } else { Write-Host 'Nothing to restore.' } }
        'start' {
            if ($st) { Write-Warn2 'A bisect is already running: use "bisect continue" or "restore".'; return }
            $base = Invoke-Probe 30
            if ((Get-Verdict $base) -ne 'LEAK') { Write-Good "No leak right now ($($base.Zombies)/$($base.Started)) - nothing to bisect."; if (-not $DryRun) { return } }
            $c = Get-BisectCandidates
            if (-not $c) { Write-Warn2 'No third-party non-device drivers that can be switched off safely.'; return }
            Write-Host ("Candidates ({0} third-party drivers that are not boot-critical and not bound to a device):" -f $c.Count)
            foreach ($x in $c) { Write-Host ('  {0,-28} {1,-22} {2,-16} start={3}' -f $x.Service, $x.Vendor, $x.Version, $x.Start) }
            Write-Host ("About {0} reboots needed." -f ([math]::Ceiling([math]::Log([math]::Max(2, $c.Count), 2)) + 1))
            if ($DryRun) { Write-Warn2 'DryRun: nothing changed.'; return }
            Write-Warn2 'Software that depends on these drivers (VPNs, RGB tools, cloud drives ...) will not work while it is switched off.'
            if (-not (Confirm-Step 'Start the bisect?')) { return }
            try { Checkpoint-Computer -Description 'zombieprobe bisect' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; Write-Host 'System restore point created.' } catch { Write-Warn2 'No restore point (System Protection off) - restore still works via this script.' }
            $orig = [ordered]@{}; foreach ($x in $c) { $orig[$x.Service] = $x.Start }
            $st = [pscustomobject]@{ version = $Version; original = [pscustomobject]$orig; files = [pscustomobject]@{}; suspects = @($c.Service); disabled = @(); round = 0; confirm = $false; history = @(); actionTime = '' }
            foreach ($x in $c) { $st.files | Add-Member -NotePropertyName $x.Service -NotePropertyValue $x.File }
            Start-BisectRound $st
        }
        'continue' {
            if (-not $st) { Write-Host 'No bisect running. Start with: .\zombieprobe.ps1 bisect start'; return }
            if ((Get-BootTime) -lt [datetime]$st.actionTime) { Write-Warn2 'You have not rebooted since the last round. Reboot first.'; return }
            $loaded = Get-LoadedSet
            $stillLoaded = @(@($st.disabled) | Where-Object { $loaded[[string]$st.files.$_] })
            if ($stillLoaded) { Write-Warn2 ("Still loaded although switched off (result less reliable): {0}" -f ($stillLoaded -join ', ')) }
            $pr = Invoke-Probe 30
            $v = Get-Verdict $pr
            Write-Host ("Round {0}: {1} of {2} zombies with [{3}] off -> {4}" -f $st.round, $pr.Zombies, ($pr.Started - $pr.Reused), (@($st.disabled) -join ', '), $v)
            if ($v -eq 'UNCLEAR') { Write-Warn2 'Unclear result. Run "bisect continue" again in a minute (no reboot needed).'; return }
            $st.history = @($st.history) + [pscustomobject]@{ round = $st.round; disabled = @($st.disabled); result = $v; stillLoaded = $stillLoaded }
            Restore-Bisect $st
            $off = @($st.disabled)
            if ($st.confirm) {
                [IO.File]::Delete($BisectState)
                if ($v -eq 'OK') {
                    $svc = $off[0]
                    Write-Bad ("FOUND IT: driver service '{0}' ({1})" -f $svc, $st.files.$svc)
                    Write-Host 'Fix: update or uninstall the software that installed it, then re-run the test.'
                    Write-Host ("Please report it: {0}/issues  (.\zombieprobe.ps1 report)" -f $RepoUrl)
                } else {
                    Write-Warn2 'Not found among third-party non-device drivers. Remaining suspects: Microsoft components (e.g. Hyper-V/VBS) or a device driver hunt could not switch off. See README > "Still not found".'
                }
                Write-Host 'All drivers restored. Reboot once more to return to normal.'
                return
            }
            $st.suspects = if ($v -eq 'OK') { $off } else { @(@($st.suspects) | Where-Object { $off -notcontains $_ }) }
            if (@($st.suspects).Count -eq 0) { [IO.File]::Delete($BisectState); Write-Warn2 'No suspects left - the cause is not a third-party non-device driver. All restored.'; return }
            if (@($st.suspects).Count -eq 1) { $st.confirm = $true }
            Start-BisectRound $st
        }
    }
}

function Invoke-Restore {
    Assert-Admin
    $h = Read-Json $HuntState
    if ($h) { foreach ($id in @($h.disabled)) { try { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop; Write-Host "re-enabled device $id" } catch { Write-Warn2 "could not re-enable $id" } }; [IO.File]::Delete($HuntState) }
    $b = Read-Json $BisectState
    if ($b) { Restore-Bisect $b; [IO.File]::Delete($BisectState); Write-Host 'driver start values restored (reboot to apply)' }
    if (-not $h -and -not $b) { Write-Host 'Nothing to restore.' } else { Write-Good 'Restored.' }
}

function Invoke-Report {
    $pr = Invoke-Probe $Count
    $sys = Get-SystemCount
    $inv = @(Get-DriverInventory)
    $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { "- $($_.Name) - driver $($_.DriverVersion) - $(if ($_.ConfigManagerErrorCode -ne 0) { 'disabled' } elseif ($_.CurrentHorizontalResolution) { 'drives a monitor' } else { 'no monitor' })" })
    $cpu = ([string](Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($d in ($inv | Sort-Object Vendor, File)) {
        $dn = (@($d.Devices) | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '
        $rows.Add(('| {0} | {1} | {2} | {3} |' -f $d.File, $d.Vendor, $d.Version, $dn))
    }
    $lines = @(
        '## zombieprobe report', '',
        "- zombieprobe: $Version", "- OS: $(Get-OsLine)", "- CPU: $cpu", '- GPUs:'
    ) + $gpus + @(
        "- Probe: $($pr.Zombies) of $($pr.Started - $pr.Reused) processes stayed as zombies -> **$(Get-Verdict $pr)**",
        $(if ($sys) { "- System-wide: $($sys.Objects) process objects / $($sys.Live) running -> $($sys.Zombies) zombies" } else { '- System-wide: (not elevated)' }),
        '', '### Culprit (fill in)', '- Driver / device: ', '- How found (hunt / bisect / other): ', '- Fixed by: ', '',
        '### Third-party kernel drivers', '', '| Driver | Vendor | Version | Device |', '|---|---|---|---|'
    ) + @($rows)
    $out = Join-Path (Get-Location).Path 'zombieprobe-report.md'
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Good "Report written: $out"
    Write-Host "Paste it into a new issue: $RepoUrl/issues/new   (it contains no user names or paths)"
}

switch ($Command) {
    'test' { $null = Invoke-Test }
    'scan' { $null = Invoke-Scan }
    'hunt' { Invoke-Hunt }
    'bisect' { Invoke-Bisect }
    'restore' { Invoke-Restore }
    'report' { Invoke-Report }
    'help' { Get-Help $MyInvocation.MyCommand.Path -Detailed }
}
