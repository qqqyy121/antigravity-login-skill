<#
.SYNOPSIS
Starts Antigravity with proxy environment variables confined to the new process.
.DESCRIPTION
Windows PowerShell 5.1+. A reachable TCP port does not prove proxy functionality
or account login. Restart requests a normal window close and never force kills.
#>
[CmdletBinding()]
param(
    [string]$ProxyUrl = 'http://127.0.0.1:7890',
    [string]$AppPath = (Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'),
    [switch]$Restart,
    [int]$CloseTimeoutSeconds = 10
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Stop-WithError([string]$Code, [string]$Message, [int]$ExitCode = 1) {
    [pscustomobject]@{ status = 'error'; code = $Code; message = $Message } | ConvertTo-Json -Compress
    exit $ExitCode
}

function Get-SameProcess($Record) {
    $process = Get-Process -Id ([int]$Record.ProcessId) -ErrorAction SilentlyContinue
    if (!$process) { return $null }
    try {
        if ($process.HasExited) { $process.Dispose(); return $null }
        # CIM timestamps have microsecond precision; Process.StartTime has 100 ns precision.
        # Match within one microsecond and require the recorded path to guard PID reuse.
        $deltaTicks = $process.StartTime.ToUniversalTime().Ticks - $Record.CreationDate.ToUniversalTime().Ticks
        if ([Math]::Abs($deltaTicks) -ge 10 -or
            ![string]::Equals($process.Path, $Record.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
            $process.Dispose()
            return $null
        }
        return $process
    } catch {
        $exited = $false
        try { $exited = $process.HasExited } catch {}
        $process.Dispose()
        if ($exited) { return $null }
        Stop-WithError 'process_inspection_failed' 'A tracked process could not be inspected safely. Close the application manually and retry.'
    }
}

if ($env:OS -ne 'Windows_NT') {
    Stop-WithError 'unsupported_platform' 'This launcher requires Windows.'
}
if ($CloseTimeoutSeconds -lt 1 -or $CloseTimeoutSeconds -gt 60) {
    Stop-WithError 'invalid_timeout' 'CloseTimeoutSeconds must be between 1 and 60.'
}

$proxy = $null
$ProxyUrl = $ProxyUrl.Trim()
if (![Uri]::TryCreate($ProxyUrl, [UriKind]::Absolute, [ref]$proxy) -or
    $proxy.Scheme -notin @('http', 'https') -or
    !$proxy.Host -or $proxy.Port -lt 1 -or $proxy.Port -gt 65535 -or
    $proxy.UserInfo -or $proxy.AbsolutePath -notin @('', '/') -or $proxy.Query -or $proxy.Fragment) {
    Stop-WithError 'invalid_proxy' 'Use an HTTP or HTTPS proxy URL with a valid port and no credentials, query or path.'
}

if (!$AppPath -or $AppPath -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+\\)') {
    Stop-WithError 'invalid_app_path' 'AppPath must be an absolute path to the installed application executable.'
}
try {
    $AppPath = [IO.Path]::GetFullPath($AppPath)
    if (![IO.File]::Exists($AppPath) -or [IO.Path]::GetExtension($AppPath) -ine '.exe') {
        Stop-WithError 'invalid_app_path' 'The application executable does not exist at AppPath.'
    }
} catch {
    Stop-WithError 'invalid_app_path' 'AppPath could not be resolved to an application executable.'
}

$client = New-Object Net.Sockets.TcpClient
$connection = $null
try {
    $connection = $client.BeginConnect($proxy.DnsSafeHost.Trim('[', ']'), $proxy.Port, $null, $null)
    if (!$connection.AsyncWaitHandle.WaitOne(2000)) { throw 'connection timeout' }
    $client.EndConnect($connection)
} catch {
    Stop-WithError 'proxy_unreachable' 'Could not connect to the proxy endpoint. Start your proxy or verify its host and port.' 2
} finally {
    if ($connection) { $connection.AsyncWaitHandle.Close() }
    $client.Dispose()
}

try {
    # Request only identity fields; do not read process command lines or account files.
    $snapshot = @(Get-CimInstance -Query 'SELECT ProcessId, ParentProcessId, ExecutablePath, CreationDate, Name FROM Win32_Process')
} catch {
    Stop-WithError 'process_inspection_failed' 'Could not inspect process paths safely. Close the application manually and retry.'
}
$appName = [IO.Path]::GetFileName($AppPath)
if (@($snapshot | Where-Object { !$_.ExecutablePath -and $_.Name -ieq $appName }).Count -gt 0) {
    Stop-WithError 'process_inspection_failed' 'An application with the same executable name has an unreadable path. Close it manually and retry.'
}
$roots = @($snapshot | Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $AppPath, [StringComparison]::OrdinalIgnoreCase) })
if ($roots.Count -gt 0 -and !$Restart) {
    Stop-WithError 'already_running' 'This application is already running. Save your work and use -Restart, or close it manually before retrying.' 3
}

if ($roots.Count -gt 0) {
    $tree = @{}
    foreach ($root in $roots) { $tree[[int]$root.ProcessId] = $root }
    $installDirectory = [IO.Path]::GetDirectoryName($AppPath)
    $installPrefix = $installDirectory.TrimEnd('\') + '\'
    $allowDescendants = $installDirectory -ne [IO.Path]::GetPathRoot($AppPath)
    # Only same-installation descendants belong to the application. External browsers
    # or terminals opened by it are left running. No name-based closure is performed.
    do {
        $added = $false
        foreach ($record in $snapshot) {
            $parent = $tree[[int]$record.ParentProcessId]
            if ($allowDescendants -and !$tree.ContainsKey([int]$record.ProcessId) -and $parent -and
                $record.ExecutablePath -and $record.ExecutablePath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                $record.CreationDate -ge $parent.CreationDate) {
                $tree[[int]$record.ProcessId] = $record
                $added = $true
            }
        }
    } while ($added)

    foreach ($record in $tree.Values) {
        $process = Get-SameProcess $record
        if ($process) {
            try { [void]$process.CloseMainWindow() } catch {} finally { $process.Dispose() }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($CloseTimeoutSeconds)
    do {
        $remaining = 0
        foreach ($record in $tree.Values) {
            $process = Get-SameProcess $record
            if ($process) { $remaining++; $process.Dispose() }
        }
        if ($remaining -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining -gt 0) {
        Stop-WithError 'close_required' 'The application or a verified child did not exit normally. Save your work, close it manually and retry. Nothing was force killed.' 4
    }
}

try {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $AppPath
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($AppPath)
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['HTTP_PROXY'] = $ProxyUrl
    $startInfo.EnvironmentVariables['HTTPS_PROXY'] = $ProxyUrl
    $startInfo.EnvironmentVariables['ALL_PROXY'] = $ProxyUrl
    $startInfo.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1,::1'
    $started = [Diagnostics.Process]::Start($startInfo)
    if (!$started) { throw 'process did not start' }
    $startedId = $started.Id
    $started.Dispose()
} catch {
    Stop-WithError 'start_failed' 'The application could not be started. Verify AppPath and the executable permissions.'
}
[pscustomobject]@{ status = 'started_with_proxy'; pid = $startedId; app_path = $AppPath } | ConvertTo-Json -Compress
exit 0
