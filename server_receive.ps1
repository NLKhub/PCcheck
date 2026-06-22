param([int]$Port = 8080)

$saveDir = Join-Path $PSScriptRoot "results"
if (-not (Test-Path $saveDir)) {
    New-Item -ItemType Directory -Path $saveDir | Out-Null
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")

try {
    $listener.Start()
} catch {
    Write-Host "[ERROR] Failed to bind port ${Port}: $($_.Exception.Message)" -ForegroundColor Red
    if ($Port -lt 1024) {
        Write-Host "       Ports below 1024 require administrator privileges." -ForegroundColor Yellow
    }
    Read-Host "Press Enter to exit"
    exit 1
}

$startTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PCCheck Result Receiver" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Started : $startTime"
Write-Host "  Port    : $Port"
Write-Host "  Save to : $saveDir"
Write-Host "  Stop    : Ctrl+C"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req     = $context.Request
        $resp    = $context.Response
        $now     = Get-Date -Format 'HH:mm:ss'

        if ($req.HttpMethod -eq 'POST' -and $req.Url.LocalPath -eq '/result') {
            try {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body   = $reader.ReadToEnd()
                $reader.Close()

                $qs     = $req.QueryString
                $pcHost = if ($qs['host']) { $qs['host'] } else { 'UnknownHost' }
                $pcIp   = if ($qs['ip'])   { $qs['ip']   } else { $req.RemoteEndPoint.Address.ToString() }

                $ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
                $filename = "${pcHost}_${pcIp}_${ts}_result.json"
                $filepath = Join-Path $saveDir $filename
                [System.IO.File]::WriteAllText($filepath, $body, [System.Text.Encoding]::UTF8)

                Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
                Write-Host " OK  " -NoNewline -ForegroundColor Green
                Write-Host " $pcHost ($pcIp) -> $filename"

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
                $resp.StatusCode  = 200
                $resp.ContentType = 'application/json; charset=utf-8'
                $resp.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
                Write-Host " ERR " -NoNewline -ForegroundColor Red
                Write-Host " $($_.Exception.Message)"
                $resp.StatusCode = 500
            }
        } else {
            Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
            Write-Host " --- " -NoNewline -ForegroundColor DarkGray
            Write-Host " $($req.HttpMethod) $($req.Url.LocalPath) from $($req.RemoteEndPoint.Address)" -ForegroundColor DarkGray
            $resp.StatusCode = 404
        }

        $resp.Close()
    }
} catch [System.Net.HttpListenerException] {
    # normal exit on Ctrl+C
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    Write-Host ""
    Write-Host "Server stopped." -ForegroundColor Yellow
}
