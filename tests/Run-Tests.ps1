# Run with Windows PowerShell 5.1 or PowerShell 7 on Windows; no Pester is required.
[CmdletBinding()]
param(
    [string]$PowerShellPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'antigravity-login\scripts\Start-AntigravityWithProxy.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('proxy-launcher-tests-' + [Guid]::NewGuid().ToString('N'))
$fixtures = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$listeners = New-Object 'System.Collections.Generic.List[System.Net.Sockets.TcpListener]'
$passed = 0
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Quote-Literal([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
function New-ProxyListener {
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $listener.Start()
    $listeners.Add($listener)
    return $listener
}
function New-Fixture([string]$Name, [string]$ExeName = 'FixtureApp.exe') {
    $folder = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $folder | Out-Null
    $path = Join-Path $folder $ExeName
    Copy-Item -LiteralPath (Join-Path $testRoot 'FixtureApp.exe') -Destination $path
    return $path
}
function Wait-Fixture([int]$ProcessId, [string]$AppPath) {
    $folder = Split-Path $AppPath -Parent
    $ready = Join-Path $folder ('ready-' + $ProcessId)
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (!(Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path -LiteralPath $ready) 'The isolated fixture did not become ready.'
    $process = Get-Process -Id $ProcessId
    $fixtures.Add($process)
    Assert-True ($process.MainWindowHandle -ne [IntPtr]::Zero) 'The fixture must expose a normal-close main window.'
    return $process
}
function Start-Fixture([string]$AppPath, [string]$Mode = '', [string]$ExternalPath = '') {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $AppPath
    $info.UseShellExecute = $false
    $info.EnvironmentVariables['PROXY_FIXTURE_MODE'] = $Mode
    $info.EnvironmentVariables['PROXY_FIXTURE_EXTERNAL_PATH'] = $ExternalPath
    $process = [Diagnostics.Process]::Start($info)
    return Wait-Fixture $process.Id $AppPath
}
function Invoke-Launcher([string]$AppPath, [string]$ProxyUrl, [switch]$Restart, [string]$Mode = '') {
    $snapshot = Join-Path $testRoot ([Guid]::NewGuid().ToString('N') + '.caller-env.txt')
    $command = '& ' + (Quote-Literal $launcher) + ' -AppPath ' + (Quote-Literal $AppPath) +
        ' -ProxyUrl ' + (Quote-Literal $ProxyUrl) + ' -CloseTimeoutSeconds 1'
    if ($Restart) { $command += ' -Restart' }
    # finally runs even when the command exits: this observes the launcher's caller environment.
    $source = '$ProgressPreference = ''SilentlyContinue''; try { ' + $command + ' } finally { @($env:HTTP_PROXY,$env:HTTPS_PROXY,$env:ALL_PROXY,$env:NO_PROXY) | Set-Content -LiteralPath ' + (Quote-Literal $snapshot) + ' }; exit $LASTEXITCODE'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $PowerShellPath
    $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['HTTP_PROXY'] = 'http://caller-http.invalid:1001'
    $info.EnvironmentVariables['HTTPS_PROXY'] = 'http://caller-https.invalid:1002'
    $info.EnvironmentVariables['ALL_PROXY'] = 'http://caller-all.invalid:1003'
    $info.EnvironmentVariables['NO_PROXY'] = 'caller-only.invalid'
    $info.EnvironmentVariables['PROXY_FIXTURE_MODE'] = $Mode
    $info.EnvironmentVariables['PROXY_FIXTURE_EXTERNAL_PATH'] = ''
    $process = [Diagnostics.Process]::Start($info)
    # A persistent GUI child can inherit the pipe. Read the launcher's one JSON line,
    # rather than waiting for EOF until the fixture itself exits.
    $outputTask = $process.StandardOutput.ReadLineAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    Assert-True ($process.WaitForExit(15000)) 'The launcher exceeded the test timeout.'
    $stdout = ''
    $stderr = ''
    if ($outputTask.Wait(1000) -and $outputTask.Result) { $stdout = $outputTask.Result.Trim() }
    if ($errorTask.Wait(100) -and $errorTask.Result) { $stderr = $errorTask.Result.Trim() }
    $result = $null
    if ($stdout) { try { $result = $stdout | ConvertFrom-Json } catch {} }
    $callerEnv = @()
    if (Test-Path -LiteralPath $snapshot) { $callerEnv = @(Get-Content -LiteralPath $snapshot) }
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{ ExitCode = $exitCode; Result = $result; Stdout = $stdout; Stderr = $stderr; CallerEnv = $callerEnv }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host ('PASS ' + $Name) }
    catch { $script:failed++; Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $compiledFixture = Join-Path $testRoot 'FixtureApp.exe'
    & $compiler /nologo /target:winexe ('/out:' + $compiledFixture) /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'FixtureApp.cs')
    Assert-True ($LASTEXITCODE -eq 0) 'Could not compile the isolated fixture.'

    # Wrong hard-coded port, missing env assignment or caller env mutation breaks this behavior.
    Test-Case 'Starts with a non-default proxy port and isolates caller environment' {
        $listener = New-ProxyListener
        $url = 'http://127.0.0.1:' + $listener.LocalEndpoint.Port
        $app = New-Fixture 'port-and-env'
        $run = Invoke-Launcher $app $url
        Assert-True ($run.ExitCode -eq 0) ('Expected a successful launch, got exit ' + $run.ExitCode + ': ' + $run.Stdout + ' ' + $run.Stderr)
        Assert-True ($run.Result.status -eq 'started_with_proxy') 'Success must describe proxy startup.'
        $process = Wait-Fixture $run.Result.pid $app
        $observed = @(Get-Content -LiteralPath (Join-Path (Split-Path $app -Parent) ('env-' + $process.Id + '.txt')))
        Assert-True (($observed -join '|') -eq ('HTTP_PROXY=' + $url + '|HTTPS_PROXY=' + $url + '|ALL_PROXY=' + $url + '|NO_PROXY=localhost,127.0.0.1,::1')) 'The child did not receive the four requested proxy values.'
        Assert-True (($run.CallerEnv -join '|') -eq 'http://caller-http.invalid:1001|http://caller-https.invalid:1002|http://caller-all.invalid:1003|caller-only.invalid') 'The launcher changed its caller environment.'
        Assert-True (!$run.Stderr) 'Successful startup wrote unexpected stderr.'
    }

    # Skipping TCP readiness would launch the fixture at this unbound port.
    Test-Case 'Rejects a proxy port without a listener before starting the app' {
        $listener = New-ProxyListener
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $app = New-Fixture 'unreachable'
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $port)
        Assert-True ($run.ExitCode -ne 0 -and $run.Result.code -eq 'proxy_unreachable') 'Expected proxy_unreachable.'
        Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $app -Parent) -Filter 'ready-*').Count -eq 0) 'The app started with a missing proxy.'
    }

    # Removing UserInfo validation would leak these fake credentials to a process or output.
    Test-Case 'Rejects credential-bearing proxy URLs without reflecting the credentials' {
        $listener = New-ProxyListener
        $app = New-Fixture 'credentials'
        $run = Invoke-Launcher $app ('http://testuser:testsecret@127.0.0.1:' + $listener.LocalEndpoint.Port)
        Assert-True ($run.ExitCode -ne 0 -and $run.Result.code -eq 'invalid_proxy') 'Expected invalid_proxy for userinfo.'
        Assert-True (($run.Stdout + $run.Stderr) -notmatch 'testuser|testsecret') 'Output reflected proxy credentials.'
        Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $app -Parent) -Filter 'ready-*').Count -eq 0) 'Credential-bearing proxy started the app.'
    }

    # Removing the existing-path guard falsely reports an env injection into an existing instance.
    Test-Case 'Protects an already running application unless Restart was requested' {
        $listener = New-ProxyListener
        $app = New-Fixture 'already-running'
        $existing = Start-Fixture $app
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $listener.LocalEndpoint.Port)
        Assert-True ($run.ExitCode -ne 0 -and $run.Result.code -eq 'already_running') 'Expected already_running.'
        $existing.Refresh()
        Assert-True (!$existing.HasExited) 'The existing fixture was closed without Restart.'
        Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $app -Parent) -Filter 'ready-*').Count -eq 1) 'A second instance started without Restart.'
    }

    # A process-name-only lookup would block or close this different-path application.
    Test-Case 'Distinguishes identical executable names in different directories' {
        $listener = New-ProxyListener
        $otherApp = New-Fixture 'same-name-other'
        $other = Start-Fixture $otherApp
        $app = New-Fixture 'same-name-target'
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $listener.LocalEndpoint.Port)
        Assert-True ($run.ExitCode -eq 0) 'A different-path process incorrectly blocked startup.'
        $started = Wait-Fixture $run.Result.pid $app
        $other.Refresh()
        Assert-True (!$other.HasExited) 'A different-path process was closed.'
    }

    # Starting early or skipping normal close breaks the close marker and exit condition.
    Test-Case 'Restart closes the exact application normally and starts a new PID' {
        $listener = New-ProxyListener
        $app = New-Fixture 'normal-restart'
        $existing = Start-Fixture $app
        $oldPid = $existing.Id
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $listener.LocalEndpoint.Port) -Restart
        Assert-True ($run.ExitCode -eq 0) ('Expected normal restart, got ' + $run.Stdout + ' ' + $run.Stderr)
        Assert-True ($run.Result.pid -ne $oldPid) 'Restart did not create a new PID.'
        $started = Wait-Fixture $run.Result.pid $app
        $existing.Refresh()
        Assert-True $existing.HasExited 'Restart started before the old process exited.'
        Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path $app -Parent) ('closed-' + $oldPid))) 'The old fixture was not closed normally.'
    }

    # Force-killing or launching despite a refused close breaks this protection.
    Test-Case 'Restart stops safely when normal close is refused' {
        $listener = New-ProxyListener
        $app = New-Fixture 'refuse-restart'
        $existing = Start-Fixture $app 'refuse_close'
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $listener.LocalEndpoint.Port) -Restart
        Assert-True ($run.ExitCode -ne 0 -and $run.Result.code -eq 'close_required') 'Expected close_required when the app refuses to close.'
        $existing.Refresh()
        Assert-True (!$existing.HasExited) 'The application was force killed.'
        Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $app -Parent) -Filter 'ready-*').Count -eq 1) 'Restart launched a new process after refused close.'
    }

    # Walking the entire tree could close an external browser/terminal opened by the app.
    Test-Case 'Restart leaves external descendants outside the installation directory running' {
        $listener = New-ProxyListener
        $externalApp = New-Fixture 'external-descendant' 'language_server.exe'
        $app = New-Fixture 'external-parent'
        $existing = Start-Fixture $app '' $externalApp
        $externalId = [int](Get-Content -LiteralPath (Join-Path (Split-Path $app -Parent) 'child.pid'))
        $external = Wait-Fixture $externalId $externalApp
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $listener.LocalEndpoint.Port) -Restart
        Assert-True ($run.ExitCode -eq 0) ('Expected target restart, got ' + $run.Stdout + ' ' + $run.Stderr)
        $started = Wait-Fixture $run.Result.pid $app
        $existing.Refresh()
        Assert-True $existing.HasExited 'The target parent remained running.'
        $external.Refresh()
        Assert-True (!$external.HasExited) 'Restart closed an external descendant.'
    }

    # Ignoring owned backend processes can leave them running with the old environment.
    Test-Case 'Restart normally closes a verified backend inside the installation directory' {
        $listener = New-ProxyListener
        $app = New-Fixture 'owned-backend'
        $backendApp = Join-Path (Split-Path $app -Parent) 'language_server.exe'
        Copy-Item -LiteralPath (Join-Path $testRoot 'FixtureApp.exe') -Destination $backendApp
        $existing = Start-Fixture $app '' $backendApp
        $backendId = [int](Get-Content -LiteralPath (Join-Path (Split-Path $app -Parent) 'child.pid'))
        $backend = Wait-Fixture $backendId $backendApp
        $run = Invoke-Launcher $app ('http://127.0.0.1:' + $listener.LocalEndpoint.Port) -Restart
        Assert-True ($run.ExitCode -eq 0) ('Expected application and backend restart, got ' + $run.Stdout)
        $started = Wait-Fixture $run.Result.pid $app
        $existing.Refresh()
        $backend.Refresh()
        Assert-True ($existing.HasExited -and $backend.HasExited) 'Restart left the old application or owned backend running.'
        Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path $app -Parent) ('closed-' + $backendId))) 'The owned backend did not close normally.'
    }

    # Relative AppPath is ambiguous and could accidentally target an unrelated installed app.
    Test-Case 'Requires an absolute application path' {
        $run = Invoke-Launcher '.\FixtureApp.exe' 'http://127.0.0.1:7890'
        Assert-True ($run.ExitCode -ne 0 -and $run.Result.code -eq 'invalid_app_path') 'Expected invalid_app_path for a relative path.'
    }
} finally {
    foreach ($listener in $listeners) { $listener.Stop() }
    # Cleanup affects only PIDs started by this harness, never a name-matched user process.
    foreach ($fixture in $fixtures) {
        try {
            $fixture.Refresh()
            if (!$fixture.HasExited) {
                $folder = Split-Path $fixture.Path -Parent
                [IO.File]::WriteAllText((Join-Path $folder 'exit.signal'), 'exit test fixture')
                if (!$fixture.WaitForExit(3000)) { $fixture.Kill(); $fixture.WaitForExit() }
            }
            $fixture.Dispose()
        } catch { Write-Warning ('Fixture cleanup failed for PID ' + $fixture.Id) }
    }
    # Only remove the freshly generated, resolved test directory within the temporary directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'proxy-launcher-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host ('Results: ' + $passed + ' passed, ' + $failed + ' failed.')
if ($failed -gt 0) { exit 1 }
