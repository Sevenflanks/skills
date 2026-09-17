[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('server', 'never-ready', 'delayed-exit', 'callback-cleanup-exit')]
    [string]$Mode,

    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopPath,
    [Parameter(Mandatory)][string]$Token,
    [ValidateRange(0, 65535)][int]$Port = 0,
    [ValidateRange(1, 40)][int]$MaxLifetimeSeconds = 30,
    [ValidateRange(1, 5000)][int]$ExitDelayMilliseconds = 150,
    [ValidateRange(1, 255)][int]$ExitCode = 42,
    [string]$StderrMessage = 'bind_failed socket_error=AddressAlreadyInUse',
    [string]$CallbackArtifactParent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-StopRequested {
    try {
        return [IO.File]::Exists($StopPath) -and
            [string]::Equals([IO.File]::ReadAllText($StopPath), $Token, [StringComparison]::Ordinal)
    }
    catch {
        return $false
    }
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($MaxLifetimeSeconds)
if ($Mode -eq 'delayed-exit') {
    [Threading.Thread]::Sleep($ExitDelayMilliseconds)
    [Console]::Error.WriteLine($StderrMessage)
    exit $ExitCode
}
if ($Mode -eq 'callback-cleanup-exit') {
    # 只在本次 fixture 的 callback 目錄鎖住 result，讓 deadline cleanup 等待；
    # stdout handle 釋放後才退出，確保重現 cleanup 期間的交錯，而非靠 sleep 猜時間。
    if ([string]::IsNullOrWhiteSpace($CallbackArtifactParent)) { throw 'CallbackArtifactParent is required.' }
    $resultStream = $null
    try {
        while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $resultStream) {
            foreach ($directory in [IO.Directory]::EnumerateDirectories($CallbackArtifactParent, 'readiness-*.callback', [IO.SearchOption]::TopDirectoryOnly)) {
                $resultPath = Join-Path $directory 'result.xml'
                if (-not [IO.File]::Exists($resultPath)) { continue }
                try {
                    $resultStream = [IO.File]::Open($resultPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                    [IO.File]::WriteAllText($ReadyPath, $Token, [Text.UTF8Encoding]::new($false))
                    while ([DateTimeOffset]::UtcNow -lt $deadline) {
                        $stdoutPath = Join-Path $directory 'stdout.log'
                        $stdoutStream = $null
                        try {
                            $stdoutStream = [IO.File]::Open($stdoutPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                            [Console]::Error.WriteLine($StderrMessage)
                            [Console]::Error.Flush()
                            [Environment]::Exit($ExitCode)
                        }
                        catch [IO.IOException] {
                            [Threading.Thread]::Sleep(10)
                        }
                        finally {
                            if ($stdoutStream) { $stdoutStream.Dispose() }
                        }
                    }
                }
                catch [IO.IOException] {
                    [Threading.Thread]::Sleep(10)
                }
            }
            [Threading.Thread]::Sleep(10)
        }
    }
    finally {
        if ($resultStream) { $resultStream.Dispose() }
    }
    exit 24
}
if ($Mode -eq 'never-ready') {
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-StopRequested) { exit 0 }
        [Threading.Thread]::Sleep(20)
    }
    exit 23
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Server.ExclusiveAddressUse = $true
try {
    try {
        $listener.Start()
    }
    catch [Net.Sockets.SocketException] {
        [Console]::Error.WriteLine("bind_failed socket_error=$($_.Exception.SocketErrorCode)")
        exit 98
    }

    $boundPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $ready = [ordered]@{
        token = $Token
        process_id = $PID
        port = $boundPort
        ready_at_utc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    [IO.File]::WriteAllText($ReadyPath, ($ready | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

    $payload = [Text.Encoding]::UTF8.GetBytes("$Token`n")
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-StopRequested) { exit 0 }
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 500
                $client.SendTimeout = 500
                $stream = $client.GetStream()
                $stream.Write($payload, 0, $payload.Length)
                $stream.Flush()
            }
            finally {
                $client.Dispose()
            }
        }
        else {
            [Threading.Thread]::Sleep(20)
        }
    }
}
finally {
    $listener.Stop()
}

exit 23
