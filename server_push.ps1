param(
    [string]$TargetFile = (Join-Path $PSScriptRoot "targets.txt"),
    [string]$TaskName   = "CloudrawPCCheck"
)

# ---- Validate targets.txt ----
if (-not (Test-Path $TargetFile)) {
    Write-Host "[ERROR] targets.txt not found: $TargetFile" -ForegroundColor Red
    Write-Host "        Create targets.txt with one hostname or IP per line."
    Read-Host "Press Enter to exit"
    exit 1
}
$targets = Get-Content $TargetFile |
           Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
           ForEach-Object { $_.Trim() }
if (-not $targets) {
    Write-Host "[ERROR] No valid targets in targets.txt" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# ---- Banner ----
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PCCheck Remote Push" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Targets : $($targets.Count) PCs"
Write-Host "  Task    : $TaskName"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---- Credentials ----
$cred = Get-Credential -Message "Local admin credentials for target PCs"
if (-not $cred) { exit }
$user = $cred.UserName
$pass = $cred.GetNetworkCredential().Password

$ok = 0; $fail = 0; $skip = 0

foreach ($pc in $targets) {
    $now = Get-Date -Format 'HH:mm:ss'

    # ---- Case 1: CloudrawPCCheck task already registered ----
    $null = schtasks /query /S $pc /U $user /P $pass /tn $TaskName 2>&1
    if ($LASTEXITCODE -eq 0) {
        $null = schtasks /run /S $pc /U $user /P $pass /tn $TaskName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
            Write-Host " OK  " -NoNewline -ForegroundColor Green
            Write-Host " $pc  task triggered"
            $ok++
        } else {
            Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
            Write-Host " ERR " -NoNewline -ForegroundColor Red
            Write-Host " $pc  task run failed"
            $fail++
        }
        continue
    }

    # ---- Case 2: Task not registered - find bat via SMB admin share ----
    Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
    Write-Host " ... " -NoNewline -ForegroundColor DarkGray
    Write-Host " $pc  task not found, searching bat under C:\..."

    try {
        $batFile = Get-ChildItem "\\$pc\C$" -Filter "remote_diagnostic_pc.bat" -Recurse -ErrorAction Stop |
                   Select-Object -First 1
    } catch {
        Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
        Write-Host " ERR " -NoNewline -ForegroundColor Red
        Write-Host " $pc  cannot access \\$pc\C$  ($($_.Exception.Message))"
        $fail++
        continue
    }

    if (-not $batFile) {
        Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
        Write-Host " --- " -NoNewline -ForegroundColor Yellow
        Write-Host " $pc  remote_diagnostic_pc.bat not found under C:\"
        $skip++
        continue
    }

    # Convert UNC path to local path on target PC
    $localBat = $batFile.FullName -replace ([regex]::Escape("\\$pc\C$")), "C:"
    $batDir   = Split-Path $localBat

    # Write a tiny launcher PS1 to the target's Temp folder via SMB
    $launcherUNC   = "\\$pc\C$\Windows\Temp\pccheck_run.ps1"
    $launcherLocal = "C:\Windows\Temp\pccheck_run.ps1"
    Set-Content -Path $launcherUNC -Value "Set-Location '$batDir'; & '$localBat' '--silent'" -Encoding ASCII

    # Register and trigger one-shot task with highest privileges
    $tempTask = "PCCheck_Push_Temp"
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcherLocal"
    $null = schtasks /S $pc /U $user /P $pass /create /tn $tempTask /tr $tr /sc once /st 00:00 /rl highest /ru $user /rp $pass /f 2>&1
    $null = schtasks /run /S $pc /U $user /P $pass /tn $tempTask 2>&1
    $triggered = ($LASTEXITCODE -eq 0)

    # Allow bat to start, then clean up temp task and launcher
    Start-Sleep -Seconds 5
    $null = schtasks /S $pc /U $user /P $pass /delete /tn $tempTask /f 2>&1
    Remove-Item $launcherUNC -Force -ErrorAction SilentlyContinue

    if ($triggered) {
        Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
        Write-Host " OK  " -NoNewline -ForegroundColor Green
        Write-Host " $pc  bat triggered ($localBat)"
        $ok++
    } else {
        Write-Host "[$now] " -NoNewline -ForegroundColor DarkGray
        Write-Host " ERR " -NoNewline -ForegroundColor Red
        Write-Host " $pc  failed to trigger bat"
        $fail++
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Done:  OK=$ok  FAIL=$fail  SKIP=$skip" -ForegroundColor Cyan
Write-Host "  Results arrive at the HTTP listener." -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
