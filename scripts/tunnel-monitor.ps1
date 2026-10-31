# tunnel-monitor.ps1
# 云电脑终端隧道的端到端监控。
#
# 设计要点：探测必须"穿透隧道"，而不是只看本机进程。
#   - relay_code : 经 7683 中继访问，等价于走完 隧道 → ttyd 全链路（最强信号）
#   - direct_code: 直连 7681，期望 401（ttyd 的认证挑战）
#   - ssh_estab  : 来自云电脑 IP 的 ESTABLISHED 连接数（区分"没连"和"连了但没认证"）
#   - last_auth  : 本机 sshd 最近一次公钥认证时间
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tunnel-monitor.ps1 -Once   # 单次，用于自检
#   powershell -NoProfile -ExecutionPolicy Bypass -File tunnel-monitor.ps1         # 常驻
param(
    [switch]$Once,
    [int]$IntervalSeconds = 30,
    [string]$AuthUser = "<TTYD_USER>",
    [string]$AuthPass = "",
    [string]$CloudIp = "<CLOUD_IP>"
)

$ErrorActionPreference = "Continue"
$Dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Csv      = Join-Path $Dir "tunnel-monitor.csv"
$StatusFile = Join-Path $Dir "tunnel-status.txt"
$AlertFile  = Join-Path $Dir "tunnel-alert.txt"
$StateFile  = Join-Path $Dir ".monitor-state.json"

# 从 .ttyd-pass 读取凭据（与 relay.js 共用同一份），读不到就只做无认证探测
if (-not $AuthPass) {
    $passFile = Join-Path $Dir ".ttyd-pass"
    if (Test-Path $passFile) {
        $raw = (Get-Content $passFile -Raw).Trim()
        $i = $raw.IndexOf(':')
        if ($i -gt 0) { $AuthUser = $raw.Substring(0, $i); $AuthPass = $raw.Substring($i + 1) }
    }
}

function Get-Code([string]$Url, [string]$User, [string]$Pass) {
    try {
        if ($User -and $Pass) {
            return (& curl.exe -s -o NUL -m 8 -w "%{http_code}" -u "${User}:${Pass}" $Url 2>$null)
        }
        return (& curl.exe -s -o NUL -m 8 -w "%{http_code}" $Url 2>$null)
    } catch { return "000" }
}

function Get-LastAuth {
    try {
        # 用 FilterHashtable 只取 Id=4，比拉 30 条再过滤快一个数量级
        $e = Get-WinEvent -FilterHashtable @{ LogName = 'OpenSSH/Operational'; Id = 4 } -MaxEvents 6 -ErrorAction Stop |
             Where-Object { $_.Message -like "*Accepted publickey*" } |
             Select-Object -First 1
        if ($e) { return $e.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") }
    } catch {}
    return ""
}

function Get-WsProbe {
    # ttyd 可能「HTTP 200 但 WebSocket 不出帧」——那样页面是白屏，HTTP 探测完全看不出来
    try {
        $raw = & node (Join-Path $Dir "ws-probe.js") 7683 2>$null
        if (-not $raw) { return $null }
        return ($raw | Out-String).Trim() | ConvertFrom-Json
    } catch { return $null }
}

function Show-Alert([string]$Title, [string]$Message) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Warning
        $n.Visible = $true
        $n.ShowBalloonTip(10000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Seconds 6
        $n.Dispose()
    } catch {}
}

function Invoke-Sample {
    $ts      = Get-Date
    $relay   = Get-Code "http://127.0.0.1:7683/" $null $null
    $direct  = Get-Code "http://127.0.0.1:7681/" $AuthUser $AuthPass
    $listen  = @(Get-NetTCPConnection -LocalPort 7681 -State Listen -ErrorAction SilentlyContinue).Count
    $estab   = 0
    try { $estab = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                      Where-Object { $_.RemoteAddress -eq $CloudIp }).Count } catch {}
    $lastAuth = Get-LastAuth
    $ws = Get-WsProbe
    $wsOk = [bool]($ws -and $ws.ok)
    $wsMsgs = if ($ws) { [int]$ws.msgs } else { -1 }

    $status = "OK"
    $detail = ""
    $relayBad  = ($relay  -notin @("200","401"))
    $directBad = ($direct -notin @("200","401"))
    if ($listen -eq 0) {
        $status = "DOWN"
        $detail = "7681 无监听：反向隧道未建立"
    } elseif ($relayBad -and $directBad) {
        # 两条独立路径同时无响应 —— 路径级静默 stall 的特征
        $status = "STALL"
        $detail = "两条探测均无响应（direct=$direct relay=$relay）：路径级静默丢包"
    } elseif (-not $wsOk -and $directBad) {
        # HTTP 通但直连也失败，且 WS 不出帧：ttyd 会话侧问题
        $status = "TTYD"
        $detail = "直连失败且 WebSocket 无帧（direct=$direct ws_msgs=$wsMsgs）：ttyd 会话侧问题"
    } elseif ($directBad) {
        # 只有带认证的直连失败：可能是 ttyd 会话侧问题（探测会真实拉起一个 shell）
        $status = "TTYD"
        $detail = "中继正常但直连失败（direct=$direct）：ttyd 会话侧问题，非路径"
    } elseif ($relayBad) {
        # 只有中继失败：relay.js 或其上游连接
        $status = "RELAY"
        $detail = "直连正常但中继失败（relay=$relay）：检查 relay.js"
    } elseif ($estab -eq 0) {
        # 隧道可用但看不到来自云端的已建立连接（可能刚好在重连窗口，记录不告警）
        $detail = "estab=0（瞬时重连窗口？）"
    }

    $row = [pscustomobject]@{
        time          = $ts.ToString("yyyy-MM-dd HH:mm:ss")
        status        = $status
        relay_code    = $relay
        direct_code   = $direct
        ttyd_listening = $listen
        ssh_estab     = $estab
        ws_ok         = $wsOk
        ws_msgs       = $wsMsgs
        last_auth     = $lastAuth
        detail        = $detail
    }

    # 5 MB 轮转，避免每分钟采样把文件撑爆
    if ((Test-Path $Csv) -and ((Get-Item $Csv).Length -gt 5MB)) {
        Move-Item -Path $Csv -Destination "$Csv.old" -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $Csv)) {
        $row | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    } else {
        $row | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8 -Append
    }

    # 状态快照，便于随时查看最新一次
    @(
        "时间        : $($row.time)"
        "状态        : $status"
        "中继(7683)  : $relay"
        "直连(7681)  : $direct"
        "7681 监听   : $listen"
        "云端 ESTAB  : $estab"
        "WS 帧数     : $wsMsgs"
        "最近认证    : $lastAuth"
        "说明        : $detail"
    ) | Set-Content -Path $StatusFile -Encoding UTF8

    return $row
}

if ($Once) {
    $r = Invoke-Sample
    $r | Format-List
    exit 0
}

# ---- 常驻循环 ----
Write-Host "tunnel-monitor started, interval=${IntervalSeconds}s, dir=$Dir"
$failStreak = 0
$lastAlertAt = $null

while ($true) {
    try {
        $r = Invoke-Sample
        if ($r.status -eq "OK") {
            $failStreak = 0
            if (Test-Path $AlertFile) { Remove-Item $AlertFile -Force -ErrorAction SilentlyContinue }
        } else {
            $failStreak++
            # 连续两次异常（约 10 分钟）才告警，避免把重连窗口当成故障
            if ($failStreak -ge 3) {
                $now = Get-Date
                $shouldAlert = (-not $lastAlertAt) -or (($now - $lastAlertAt).TotalMinutes -ge 60)
                $msg = "$($r.time)  $($r.status)`n$($r.detail)`nrelay=$($r.relay_code) direct=$($r.direct_code) listen=$($r.ttyd_listening) estab=$($r.ssh_estab)"
                $msg | Set-Content -Path $AlertFile -Encoding UTF8
                if ($shouldAlert) {
                    Show-Alert "云电脑终端隧道异常" "$($r.status)：$($r.detail)"
                    $lastAlertAt = $now
                }
                Write-Host "ALERT $($r.status) $($r.detail)"
            }
        }
        Write-Host "$($r.time) $($r.status) relay=$($r.relay_code) listen=$($r.ttyd_listening) estab=$($r.ssh_estab)"
    } catch {
        Write-Host "sample failed: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $IntervalSeconds
}
