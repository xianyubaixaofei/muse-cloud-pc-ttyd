# AI-GUIDE — 云电脑终端链路（本机运维手册）

> 面向对象：接手这台 Windows 机器的 AI 或人。
> 目标：让 `http://127.0.0.1:7683` 能打开云电脑（muse）的 Linux 终端。
> 最后更新：2026-10-31

---

## 0. 一句话

隧道是**云电脑主动连出来**的，本机只负责「接收 + 转发 + 监控」。本机任何操作都**无法发起**隧道；本机能做的是保证接收端健康并快速判断断在哪一层。

---

## 1. 架构与数据流

```
浏览器 → http://127.0.0.1:7683
            ↓  relay.js（注入 ttyd 的 Basic 认证，改写 Host/Origin）
         127.0.0.1:7681  ← sshd 的反向转发监听（只在本机回环）
            ↑  反向 SSH 隧道（由 muse 发起，经其出口代理）
         muse:<CLOUD_IP> —— ttyd 127.0.0.1:7681 —— bash
```

关键点：

- 隧道方向是 **muse → 本机**，端口 22（不是 443；443 也开着但对方用的是 22）
- 本机 Tailscale 地址 `<THIS_PC_IP>`，muse 是 `<CLOUD_IP>`
- 反向绑定是 `127.0.0.1`，不对外暴露

---

## 2. 组件清单

目录：`<PROJECT_DIR>\anthropic-proxy`

| 组件 | 类型 | 端口 | 自启方式 | 职责 |
|---|---|---|---|---|
| `sshd` | Windows 服务 | 22 / 443 | 服务 **Automatic** | 接收 muse 的反向隧道，持有 7681 监听 |
| `TunnelRelay` | 计划任务 | 7683 | 登录启动 + 崩溃重启 | 跑 `relay.js`，免密进终端 |
| `TunnelMonitor` | 计划任务 | — | 登录启动 + 崩溃重启 | 跑 `tunnel-monitor.ps1`，30 秒采样 + 告警 |
| 断连采集 | 后台进程 | — | 需 `start-all.ps1` 拉起 | 跑 `tunnel-death-capture.ps1`，记录 CLOSED 现场 |

关键文件：

| 文件 | 用途 |
|---|---|
| `.ttyd-pass` | ttyd 凭据，单行 `<TTYD_USER>:密码`（明文，勿外传） |
| `tunnel-monitor.csv` | 采样历史（30 秒一条） |
| `tunnel-status.txt` | 最新一次快照（人读） |
| `tunnel-alert.txt` | 异常时存在，恢复后自动删除 |
| `tunnel-deaths.csv/.log` | 断连现场（依赖 sshd 的 CLOSED 事件） |
| `proxy.js` | **已停用**（早期 8787 方案，勿启动） |

---

## 3. 一键启动

```powershell
<PROJECT_DIR>\anthropic-proxy\start-all.cmd
```

双击即可。脚本行为（幂等，可重复执行）：

1. 检查并启动 `sshd`，必要时提权（会弹 UAC）
2. 确保 `TunnelRelay` / `TunnelMonitor` 处于 Running
3. 检查断连采集进程，缺则拉起
4. 最多等 60 秒，等 muse 把 7681 连上来
5. 做端到端探测（直连 / 中继 / WebSocket），打印判读结果
6. 链路可用则打开浏览器到 7683

加 `-NoOpen` 可只检测不打开浏览器。

---

## 4. 不变量（必须同时成立）

终端能用 ⇔ 以下五条全部为真：

1. `Get-Service sshd` = **Running**，且 22/443 在监听
2. `Get-NetTCPConnection -LocalPort 7681 -State Listen` 有 1 条，**且属于当前的 sshd 会话**
3. `Get-NetTCPConnection -LocalPort 7683 -State Listen` 有 1 条
4. 直连 7681 返回 200/401（不能是 000）
5. 中继 7683 返回 200/401

任何一条不成立，终端都打不开。

---

## 5. 状态判读

`tunnel-monitor.csv` 的列：

```
time, status, relay_code, direct_code, ttyd_listening, ssh_estab, ws_ok, ws_msgs, last_auth, detail
```

| status | 判据 | 含义 | 归因方向 |
|---|---|---|---|
| `DOWN` | `ttyd_listening=0` | 7681 无监听 | 隧道没建立（muse 侧没连过来 / 本机 sshd 没开） |
| `STALL` | relay 与 direct 同时失败 | 路径级静默丢包 | 云电脑出口代理 / 链路数据面 |
| `TTYD` | direct 失败（relay 正常或都失败且 ws=0） | ttyd 会话侧 | muse 上 ttyd 是否存活 |
| `RELAY` | 只有 relay 失败 | relay.js 或其上游 | 重启 TunnelRelay |

`ws_ok` / `ws_msgs` 目前**不可靠**（恒定 False/0），只作线索，不参与判定。

---

## 6. 归因决策树

```
终端打不开
├─ 7681 无监听（DOWN）
│  ├─ sshd 不是 Running ──────────→ 启动 sshd（本次真实事故，见 §7.1）
│  ├─ sshd Running 但无 Accepted ─→ 看 sshd 日志；无任何连接记录 = 对方没连到本机
│  └─ 有 Accepted 但端口没绑 ────→ 僵尸会话占端口，重启 sshd 强制重连
├─ 7681 有监听但 000（STALL）
│  ├─ muse 本地 curl 127.0.0.1:7681 正常 → 路径问题，本机无解，找平台侧
│  └─ muse 本地也不正常 ─────────→ 让对方重启 ttyd
└─ 7683 不通（RELAY）
   └─ 重启 TunnelRelay，确认 .ttyd-pass 与 ttyd 当前密码一致
```

---

## 7. 已验证的踩坑点（反直觉，务必遵守）

### 7.1 本机 sshd 没自启 → 看起来像"对方连不上"

2026-10-31 事故：隧道断了 1.5 小时，muse 重试几百次全失败。
真因：本机 `sshd` 服务是 **Stopped**（StartType=Manual，重启后没起来），22/443 无监听。
表现极具误导性：tailnet 里 muse 显示 `active`，本机也能 ping 通，但**没有任何入站接收**。

**判据**：`Get-NetTCPConnection -State Listen -LocalPort 22,443` 为空 = 接收端根本没开。
**已修**：服务改为 Automatic。

### 7.2 `Test-NetConnection` 在本机不可信

本机装了 Mihomo（TUN + fake-IP `198.18.0.0/15`），tun2socks 会**本地伪造 SYN-ACK**：
任何地址、任何端口都可能返回 `TcpTestSucceeded: True`。

**只能信 `curl` 的真实行为**（200/401 才算通，000 即不通）。

### 7.3 "日志里没有 CLOSED" ≠ "没断过"

静默丢包时服务端收不到 FIN/RST，socket 半开，sshd **不会写任何关闭日志**。
判断是否断过要看：端口监听 + 端到端探测，不能只看事件日志。

### 7.4 容器内 `curl 127.0.0.1:7681` 不测隧道

它走容器本地回环，只证明 ttyd 活着。要验证隧道必须从**本机**发起。

---

## 8. 常用命令

```powershell
# 全链路健康
$cred = (Get-Content .\.ttyd-pass -Raw).Trim()
curl.exe -s -o NUL -w "%{http_code}`n" -u $cred http://127.0.0.1:7681/
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:7683/
node ws-probe.js 7683

# 组件
Get-Service sshd
Get-ScheduledTask TunnelRelay,TunnelMonitor | Select TaskName,State
Get-NetTCPConnection -State Listen -LocalPort 22,443,7681,7683

# 最近状态
Get-Content .\tunnel-status.txt
Get-Content .\tunnel-monitor.csv | Select-Object -Last 5

# 强制重连（清僵尸会话）
Restart-Service sshd          # 需管理员
```

---

## 9. 外部依赖与已知未解问题

| 项 | 说明 |
|---|---|
| 隧道发起 | 只能由 muse 侧 `ssh -N -R 127.0.0.1:7681:127.0.0.1:7681` 发起，本机无法代劳 |
| 云电脑频繁重置 | `/etc` 会被清空，服务由对方看门狗重建；`/home/hatch` 保留 |
| 数据面间歇 stall | 2026-10-28 起观测到：TCP 能建立、ttyd 本地健康，但数据不回（`STALL`）。已定位到**云电脑出口代理**这一层，本机与 muse 都无法看到代理日志，需平台侧排查 |
| 无 CLOSED 的断连 | 静默丢包不产生 sshd 日志，`tunnel-death-capture` 对此类失效，靠 STALL 判定 |

---

## 10. 安全约束

- `.ttyd-pass` 是明文，改完密码必须**同时**重启 TunnelRelay，否则中继一直用旧凭据
- sshd 仅密钥登录，防火墙只放行 `<CLOUD_IP>`
- 反向隧道等于把本机 `administrator` 借给对方收发端口，收工后应加 `PermitTTY no` + `ForceCommand internal-sftp`
- 不要为了图省事清空 `administrators_authorized_keys` 的 ACL，sshd 会拒绝该文件
