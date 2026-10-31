# MUSE 云电脑终端 · AI 运维手册

一份写给 **AI 代理**看的操作手册：接管一台入站被封的云电脑终端，并在故障时快速归因。

不是给人读的科普，是可直接执行、可判读的运维文档。

## 内容

| 文件 | 说明 |
| --- | --- |
| [`AI-GUIDE.md`](AI-GUIDE.md) | 架构、组件、不变量、状态判读、归因决策树、踩坑记录 |
| [`scripts/`](scripts/) | 可直接运行的实现（PowerShell + Node） |

### scripts/

| 脚本 | 作用 |
| --- | --- |
| `start-all.ps1` / `start-all.cmd` | 一键启动：sshd → 计划任务 → 采集 → 等隧道 → 端到端探测 |
| `tunnel-monitor.ps1` | 30 秒采样，写 CSV，异常告警（状态机：DOWN/STALL/TTYD/RELAY） |
| `tunnel-death-capture.ps1` | 抓 `Connection closed` 事件，记录断连现场 |
| `ws-probe.js` | WebSocket 探针，判断 ttyd 是否真的出帧 |

**使用前**：把脚本里的 `<CLOUD_IP>`、`<TTYD_USER>` 换成你自己的值，并与 `.ttyd-pass` 放在同一目录。


## 适用场景

- Windows 本机通过反向 SSH 隧道接收云电脑（MUSE）的终端
- 隧道由云电脑主动发起，本机只负责接收、转发、监控
- 需要判断"打不开"到底断在哪一层：接收端 / 隧道 / ttyd / 中继

## 三条最关键的结论

1. **本机 sshd 停了会伪装成"对方连不上"**——tailnet 里对方显示在线，本机也能 ping 通，但 22/443 根本没监听。
2. **`Test-NetConnection` 在有 TUN 代理的机器上是假阳性**——任何地址都返回成功，只能用 `curl` 的真实状态码。
3. **"日志里没有连接关闭记录"不等于"没断过"**——静默丢包时 socket 半开，sshd 不写任何日志。

## 说明

文中所有 IP、主机名、路径均为占位符（`<CLOUD_IP>`、`<PROJECT_DIR>` 等），
按自己的环境替换即可。不含任何凭据。
