[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('server', 'never-ready', 'delayed-exit')]
    [string]$Mode,

    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopPath,
    [Parameter(Mandatory)][string]$Token,
    [ValidateRange(0, 65535)][int]$Port = 0,
    [ValidateRange(1, 40)][int]$MaxLifetimeSeconds = 30,
    [ValidateRange(1, 5000)][int]$ExitDelayMilliseconds = 150,
    [ValidateRange(1, 255)][int]$ExitCode = 42,
    [string]$StderrMessage = 'bind_failed socket_error=AddressAlreadyInUse'
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
