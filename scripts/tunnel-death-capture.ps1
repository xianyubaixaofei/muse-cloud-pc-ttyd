# tunnel-death-capture.ps1
# Watches Windows OpenSSH/Operational for "Connection closed" events and
# records a forensic snapshot for each tunnel death.
#
# Output:
#   tunnel-deaths.csv   one row per death: closed_time, port, prev_accept, lifetime
#   tunnel-deaths.log   readable timeline around each death
#
# Runs as a plain background process (no admin required for reading the log).

$ErrorActionPreference = "Continue"
$Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$Csv        = Join-Path $Dir "tunnel-deaths.csv"
$LogFile    = Join-Path $Dir "tunnel-deaths.log"
$StateFile  = Join-Path $Dir ".death-capture-state.txt"
$CloudIp    = "<CLOUD_IP>"
$Interval   = 60

function Get-Events {
    try {
        return Get-WinEvent -LogName "OpenSSH/Operational" -MaxEvents 300 -ErrorAction Stop |
               Sort-Object TimeCreated
    } catch { return @() }
}

function Write-Line($text) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

if (-not (Test-Path $Csv)) {
    "closed_time,closed_port,prev_accept_time,prev_accept_port,lifetime_min,detected_at" |
        Set-Content -Path $Csv -Encoding UTF8
}

$lastSeen = [datetime]::MinValue
if (Test-Path $StateFile) {
    $raw = (Get-Content $StateFile -Raw).Trim()
    if ($raw) { [datetime]::TryParse($raw, [ref]$lastSeen) | Out-Null }
}
if ($lastSeen -eq [datetime]::MinValue) {
    $lastSeen = (Get-Date).AddMinutes(-10)
}

Write-Line "capture started, watching from $($lastSeen.ToString('yyyy-MM-dd HH:mm:ss'))"

while ($true) {
    try {
        $events = Get-Events
        $closes = $events | Where-Object {
            $_.Id -eq 4 -and $_.Message -like "*Connection closed by $CloudIp*" -and
            $_.TimeCreated -gt $lastSeen
        }

        foreach ($c in $closes) {
            if ($c.Message -match "\[preauth\]") { continue }

            $port = ""
            if ($c.Message -match "port (\d+)") { $port = $matches[1] }

            $prev = $events | Where-Object {
                $_.TimeCreated -lt $c.TimeCreated -and $_.Message -like "*Accepted publickey*"
            } | Select-Object -Last 1

            $prevTime = ""; $prevPort = ""; $life = ""
            if ($prev) {
                $prevTime = $prev.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                if ($prev.Message -match "port (\d+)") { $prevPort = $matches[1] }
                $life = [math]::Round(($c.TimeCreated - $prev.TimeCreated).TotalMinutes, 1)
            }

            $row = "{0},{1},{2},{3},{4},{5}" -f `
                $c.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss"), $port, $prevTime, $prevPort, $life, (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Add-Content -Path $Csv -Value $row -Encoding UTF8

            Write-Line "=== DEATH detected: closed at $($c.TimeCreated.ToString('HH:mm:ss')) port=$port prev_accept=$prevTime lifetime=${life}min ==="
            $events | Where-Object { [math]::Abs(($_.TimeCreated - $c.TimeCreated).TotalMinutes) -le 6 } |
                ForEach-Object {
                    Write-Line ("  {0}  {1}" -f $_.TimeCreated.ToString("HH:mm:ss"),
                        (($_.Message -replace "`r`n"," ").Substring(0,[Math]::Min(80,$_.Message.Length))))
                }
            $lastSeen = $c.TimeCreated
            Set-Content -Path $StateFile -Value $lastSeen.ToString("o") -Encoding UTF8
        }

        if (-not $closes -or $closes.Count -eq 0) {
            Set-Content -Path $StateFile -Value $lastSeen.ToString("o") -Encoding UTF8
        }
    } catch {
        Write-Line "capture error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $Interval
}
