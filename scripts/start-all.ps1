# start-all.ps1 — 一键启动云电脑终端链路
# 幂等：重复执行不会破坏已运行的部分。
# 用法：右键 start-all.cmd，或在 PowerShell 里执行本文件。

$ErrorActionPreference = "Continue"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Node = "C:\Program Files\nodejs\node.exe"
$CloudIp = "<CLOUD_IP>"

function Line($text) { Write-Host $text }
function Step($n, $text) { Write-Host ""; Write-Host "[$n] $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "    OK   $text" -ForegroundColor Green }
function Bad($text) { Write-Host "    FAIL $text" -ForegroundColor Red }
function Info($text) { Write-Host "    ..   $text" -ForegroundColor DarkGray }

# ---------- 1. sshd（接收端，最关键） ----------
Step 1 "sshd 服务（接收端，22/443）"
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Bad "未安装 sshd，无法继续"
    exit 1
}
if ($svc.Status -ne "Running") {
    Info "当前 $($svc.Status)，尝试启动（可能弹 UAC）"
    try {
        Start-Service sshd -ErrorAction Stop
    } catch {
        Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command',"Start-Service sshd" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    $svc.Refresh()
}
if ($svc.Status -eq "Running") { Ok "sshd Running / $((Get-Service sshd).StartType)" }
else { Bad "sshd 仍未启动，后续必然失败" }

if ((Get-Service sshd).StartType -ne "Automatic") {
    Info "启动类型不是 Automatic，尝试修正（可能弹 UAC）"
    Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command',"Set-Service sshd -StartupType Automatic" -ErrorAction SilentlyContinue
}

$listen = Get-NetTCPConnection -State Listen -LocalPort 22,443 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort -Unique
if ($listen) { Ok ("监听端口: " + ($listen -join ',')) } else { Bad "22/443 未监听" }

# ---------- 2. 计划任务 ----------
Step 2 "计划任务（中继 / 监控）"
foreach ($name in @("TunnelRelay", "TunnelMonitor")) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) { Bad "$name 不存在（需要重新注册）"; continue }
    if ($task.State -ne "Running") {
        Info "$name 当前 $($task.State)，启动中"
        Start-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskName $name
    }
    if ($task.State -eq "Running") { Ok "$name Running" } else { Bad "$name = $($task.State)" }
}

# ---------- 3. 断连采集 ----------
Step 3 "断连现场采集"
$cap = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
       Where-Object { $_.CommandLine -like "*tunnel-death-capture.ps1*" }
if ($cap) { Ok "已在运行 (pid $($cap[0].ProcessId))" }
else {
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$Dir\tunnel-death-capture.ps1"
    Start-Sleep -Seconds 2
    $cap = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*tunnel-death-capture.ps1*" }
    if ($cap) { Ok "已启动 (pid $($cap[0].ProcessId))" } else { Bad "启动失败" }
}

# ---------- 4. 等待隧道 ----------
Step 4 "等待反向隧道（由云电脑主动发起）"
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if ((Get-NetTCPConnection -LocalPort 7681 -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) { break }
    Start-Sleep -Seconds 3
}
$hasTunnel = (Get-NetTCPConnection -LocalPort 7681 -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
if ($hasTunnel) { Ok "7681 已监听" }
else {
    Bad "7681 未监听：云电脑侧没有连过来"
    Info "这一步本地无法修复，需要云电脑侧的看门狗或人工拉起"
}

# ---------- 5. 端到端探测 ----------
Step 5 "端到端探测"
$direct = & curl.exe -s -o NUL -m 8 -w "%{http_code}" -u ((Get-Content "$Dir\.ttyd-pass" -Raw).Trim()) http://127.0.0.1:7681/ 2>$null
$relay  = & curl.exe -s -o NUL -m 8 -w "%{http_code}" http://127.0.0.1:7683/ 2>$null
function Judge($code) { if ($code -in @("200","401")) { "OK" } else { "FAIL" } }
"    {0,-12} {1,-6} {2}" -f "7681 直连", $direct, (Judge $direct) | Write-Host
"    {0,-12} {1,-6} {2}" -f "7683 中继", $relay,  (Judge $relay)  | Write-Host

$wsRaw = & $Node "$Dir\ws-probe.js" 7683 2>$null
$wsOk = $false
try { $wsOk = [bool](($wsRaw | ConvertFrom-Json).ok) } catch {}
if ($wsOk) { Ok "WebSocket 有数据帧" } else { Bad "WebSocket 无帧（ttyd 僵死或路径 stall）" }

# ---------- 6. 汇总 ----------
Step 6 "汇总"
$healthy = $hasTunnel -and ($direct -in @("200","401")) -and ($relay -in @("200","401"))
Line ""
if ($healthy) {
    Write-Host "    链路可用 → http://127.0.0.1:7683" -ForegroundColor Green
    if ($args -notcontains "-NoOpen") { Start-Process "http://127.0.0.1:7683" }
} else {
    Write-Host "    链路不可用，请看下面的现场数据：" -ForegroundColor Yellow
    Line "      tunnel-status.txt : $Dir\tunnel-status.txt"
    Line "      monitor csv       : $Dir\tunnel-monitor.csv"
    Line "      death log         : $Dir\tunnel-deaths.log"
    Line ""
    Line "    判读方法见 AI-GUIDE.md 的「状态判读」一节"
}
Line ""
Line "    终端地址  http://127.0.0.1:7683   （备用 http://127.0.0.1:7681）"
Line "    账号      <TTYD_USER>                      密码见 .ttyd-pass"
