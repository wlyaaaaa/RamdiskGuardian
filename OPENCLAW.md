# OpenClaw 个人智能体网关 — 完整运维手册

> **机器**: WLY\10979 (Windows 11) &nbsp;|&nbsp; **OpenClaw 版本**: v2026.6.6  
> **网关端口**: 18789 (loopback) &nbsp;|&nbsp; **公网入口**: https://wly.tailbe620b.ts.net  
> **最后审计**: 2026-06-16 &nbsp;|&nbsp; **审计人**: Antigravity Agent (Google DeepMind)

---

## 目录

1. [系统架构总览](#1-系统架构总览)
2. [核心组件清单](#2-核心组件清单)
3. [静默自启与心跳自愈方案](#3-静默自启与心跳自愈方案)
4. [安全认证与免登录运行](#4-安全认证与免登录运行)
5. [Tailscale Funnel 公网隧道](#5-tailscale-funnel-公网隧道)
6. [Telegram 渠道配置](#6-telegram-渠道配置)
7. [Google Chat 渠道配置](#7-google-chat-渠道配置)
8. [技能与插件生态](#8-技能与插件生态)
9. [缺陷审计与已修复项](#9-缺陷审计与已修复项)
10. [已实施的调优项与安全配置](#10-已实施的调优项与安全配置)
11. [灾难恢复与重装指南](#11-灾难恢复与重装指南)
12. [运维速查命令](#12-运维速查命令)
13. [文件清单](#13-文件清单)
14. [变更历史](#14-变更历史)

---

## 1. 系统架构总览

```
                            ╔══════════════════════════════╗
                            ║   互联网 (Internet)           ║
                            ╚══════════════╦═══════════════╝
                                           │ HTTPS (443)
                            ╔══════════════╩═══════════════╗
                            ║  Tailscale Funnel (WireGuard) ║
                            ║  https://wly.tailbe620b.ts.net║
                            ╚══════════════╦═══════════════╝
                                           │ HTTP proxy
                                           ▼
╔═══════════════════════════════════════════════════════════════╗
║                    本机 (127.0.0.1:18789)                      ║
║  ┌──────────────────────────────────────────────────────────┐ ║
║  │              OpenClaw Gateway  (Node.js)                  │ ║
║  │  ┌─────────┐  ┌──────────┐  ┌───────────────────────┐   │ ║
║  │  │ Control  │  │   Auth   │  │    Agent Engine        │   │ ║
║  │  │   UI     │  │ (密码模式) │  │ (Gemini 3 Flash/Pro) │   │ ║
║  │  └─────────┘  └──────────┘  └───────────────────────┘   │ ║
║  │  ┌──────────────────────────────────────────────────┐    │ ║
║  │  │               Channel Router                      │    │ ║
║  │  │  ┌──────────┐  ┌────────────┐  ┌──────────────┐  │    │ ║
║  │  │  │ Telegram  │  │ Google Chat │  │  Control UI  │  │    │ ║
║  │  │  │  Bot API  │  │ Service Acc │  │  WebSocket   │  │    │ ║
║  │  │  └──────────┘  └────────────┘  └──────────────┘  │    │ ║
║  │  └──────────────────────────────────────────────────┘    │ ║
║  └──────────────────────────────────────────────────────────┘ ║
║                                                               ║
║  ┌──────────────────────────────────────────────────────────┐ ║
║  │              Skills & Plugins (技能库)                     │ ║
║  │  gemini · github · himalaya · nano-pdf · whisper          │ ║
║  │  agent-browser · self-improving · session-logs            │ ║
║  └──────────────────────────────────────────────────────────┘ ║
╚═══════════════════════════════════════════════════════════════╝
```

**核心运行与看门狗心跳链路**（开机 → 启动 → 周期检测，全程零人工干预）：

```
Windows Boot → Task Scheduler "OpenClaw Gateway" (BootTrigger +30s)
  │  → wscript.exe (隐藏窗口) → openclaw_run_hidden.vbs → gateway.cmd
  │     → node.exe --max-old-space-size=512 (限制堆内存)
  │        → [OPENCLAW_LOG_LEVEL=warn] (过滤详细日志)
  │        → 输出及崩溃错误追加重定向到 gateway.log
  │        → 自动绑定端口 18789
  │
Windows Boot → Task Scheduler "OpenClaw Heartbeat" (BootTrigger +60s, 每 15 分钟循环)
     → powershell.exe -WindowStyle Hidden -File openclaw_heartbeat.ps1
        → 运行 Test-NetConnection 检测端口 18789
        ├─ [正常] 写入日志，退出
        └─ [无响应] 杀死并重启 "OpenClaw Gateway" 计划任务，恢复网关
```

---

## 2. 核心组件清单

| 组件 | 版本/路径 | 用途 |
|------|-----------|------|
| **OpenClaw** | v2026.6.6 | 个人智能体网关框架 |
| **Node.js** | `C:\Program Files\nodejs\node.exe` | OpenClaw 运行时 (配置 `--max-old-space-size=512`) |
| **OpenClaw 包** | `C:\Users\10979\AppData\Roaming\npm\node_modules\openclaw\dist\index.js` | npm 全局安装的执行入口 |
| **配置文件** | `C:\Users\10979\.openclaw\openclaw.json` | 网关核心配置 (已修复 Google Chat 凭据) |
| **启动脚本** | `C:\Users\10979\.openclaw\gateway.cmd` | 包含堆限制、日志级别、错误重定向的启动指令 |
| **日志文件** | `C:\Users\10979\.openclaw\gateway.log` | 重定向输出，便于分析系统崩溃与状态 |
| **工作空间** | `C:\Users\10979\.openclaw\workspace` | 智能体技能、会话数据和记忆库 |
| **Tailscale** | `C:\Program Files\Tailscale\` (服务模式, Automatic) | 提供 WireGuard 安全加密的 Funnel 公网隧道 |
| **网关任务** | `OpenClaw Gateway` (计划任务) | 静默开机自启调度 |
| **心跳任务** | `OpenClaw Heartbeat` (计划任务) | 每 15 分钟对端口 18789 进行可用性监测并自愈 |
| **VBS 包装器** | `E:\RamdiskGuardian\openclaw_run_hidden.vbs` | 隐藏命令提示符窗口运行器 |
| **任务 XML** | `E:\RamdiskGuardian\openclaw_task.xml` | 任务计划定义 (备份用) |

---

## 3. 静默自启与心跳自愈方案

### 3.1 方案原理

OpenClaw 的 Windows 静默开机自启同时解决了三个维度的问题：

| 维度 | 问题 | 解法 |
|------|------|------|
| **何时启动** | 必须在系统引导时运行，且不依赖任何用户登录 | `BootTrigger` (非 `LogonTrigger`) |
| **以谁身份** | 必须有权限读写用户目录，但不允许持有交互桌面 | `S4U` LogonType (非 `InteractiveToken`) |
| **窗口隐藏** | Windows 环境下不能有命令提示符黑框闪烁 | VBScript 脚本包装器 `WScript.Shell.Run windowStyle=0` |

### 3.2 任务定义详情 (OpenClaw Gateway)

```xml
<Task version="1.2">
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-21-1536040469-1817842872-232824913-1001</UserId>
      <LogonType>S4U</LogonType>                    <!-- 无交互/无窗口运行 -->
      <RunLevel>HighestAvailable</RunLevel>          <!-- 最高管理员权限 -->
    </Principal>
  </Principals>
  <Triggers>
    <BootTrigger>
      <Delay>PT30S</Delay>                           <!-- 等待系统和网络就绪 -->
    </BootTrigger>
  </Triggers>
  <Settings>
    <Hidden>true</Hidden>                            <!-- 任务列表中隐藏 -->
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>     <!-- 永不超时 -->
    <RestartOnFailure>
      <Count>3</Count>                               <!-- 失败自动重启3次 -->
      <Interval>PT1M</Interval>                      <!-- 重启间隔60秒 -->
    </RestartOnFailure>
    <StartWhenAvailable>true</StartWhenAvailable>     <!-- 错过时间点则补执行 -->
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>                 <!-- VBS 隐藏启动 -->
      <Arguments>"E:\RamdiskGuardian\openclaw_run_hidden.vbs"</Arguments>
      <WorkingDirectory>C:\Users\10979\.openclaw</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
```

### 3.3 S4U LogonType 说明

`S4U` (Service-for-User) 是 Windows 任务计划程序的一种安全执行机制：
- **免密运行**: 使用 Kerberos S4U 协议扩展，不需要在本地任务中存储用户的明文开机密码。
- **完全隐藏**: 在非交互式 Window Station 中运行进程，天然无法显示任何 UI 窗口，实现真正的无感后台运行。
- **环境隔离**: 任务启动时依然会载入该用户的 Profile，因此 `%USERPROFILE%`、`%APPDATA%` 以及 User 级别的注册表项可以正常加载。

### 3.4 启动延迟设计

网关的启动延迟设定为 `PT30S` (30 秒)：
1. **等待 Tailscale 建立隧道**: 系统开机时，物理网卡和 Tailscale 服务需要 10~20 秒完成路由握手并获取证书。
2. **保证外部渠道的解析与连接**: Telegram Bot API / Google Chat 等需要 DNS 解析器正常工作后才能成功建立轮询/会话。

### 3.5 看门狗心跳自愈 (OpenClaw Heartbeat)

由于网关进程可能因为长时间运行下的内存泄漏、底层网络闪断引发死锁，我们需要一个独立的守护进程。
- **守护脚本**: `E:\RamdiskGuardian\openclaw_heartbeat.ps1`
- **执行逻辑**: 每 15 分钟触发一次，运行 `Test-NetConnection -ComputerName 127.0.0.1 -Port 18789`。
- **自愈行为**: 如果 TCP 端口无响应，则脚本会判定网关挂死，自动调用 `Stop-ScheduledTask` 和 `Start-ScheduledTask` 对 `OpenClaw Gateway` 任务进行强制关闭并拉起重建，同时将错误和恢复事件记录到 `E:\RamdiskGuardian\logs\openclaw_heartbeat.log`。
- **计划配置**: 心跳任务同样在 `S4U` 模式下完全静默运行，无需人工干预。

---

## 4. 安全认证与免登录运行

### 4.1 认证模式

```json
{
  "gateway": {
    "auth": { "mode": "password" },
    "controlUi": { "allowInsecureAuth": true }
  }
}
```

- **`mode: "password"`**: 启用静态密码保护，放弃 `browser` 免密登录。
- **完全 Headless**: 启动和运行时不需要手动开启浏览器去做任何 SSO/OAuth 二次校验。
- **`allowInsecureAuth: true`**: 允许在本地 loopback 链路中使用非 HTTPS 协议验证密码。公网暴露的 Tailscale Funnel 已强制实施 TLS 传输层加密，因此此配置在安全和免登录运行之间取得了完美平衡。

### 4.2 环境变量提升

| 变量名 | 原有级别 | 提升后级别 | 值 | 作用 |
|--------|------|-----|------|------|
| `OPENCLAW_GATEWAY_PASSWORD` | User 环境变量 | **Machine 环境变量** | `wlySecureClaw2026!` | 静态密码安全凭据 |

> **修复缘由**: 在 S4U 引导启动的极早期，用户环境上下文可能还未加载完全，Node.js 极大概率无法读取 User 级别的环境变量。通过提升为 **Machine (系统) 级别**，变量直接写入注册表 `HKLM`，系统开机加载内核时即对所有会话生效。

---

## 5. Tailscale Funnel 公网隧道

### 5.1 隧道拓扑

```
Tailscale 状态:
  主机名:   wly
  IP:       100.115.124.21
  Funnel:   ON
  公网域名: https://wly.tailbe620b.ts.net

路由映射:
  https://wly.tailbe620b.ts.net (公网)  ➜  http://127.0.0.1:18789 (本地 Loopback)
```

### 5.2 Gateway 与 Funnel 的配合

```json
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback",
    "tailscale": {
      "mode": "funnel",
      "resetOnExit": false
    }
  }
}
```

- **`bind: "loopback"`**: 网关进程仅监听本地回环地址 `127.0.0.1`，机器物理网卡在局域网内不向任何设备暴露该端口。
- **`resetOnExit: false`**: 在网关重启或自愈重建时，不向 Tailscale 协调服务器注销 Funnel 路由规则，消除了公网 DNS 与 SSL 握手层面的重置延迟，提升了秒级重新上线的响应率。

---

## 6. Telegram 渠道配置

```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "8857353244:AAHswW0qeNXsUJAFBAxOT7-LO0M6ekrUQiI",
      "dmPolicy": "open",
      "allowFrom": [8320970051]
    }
  }
}
```

- **`allowFrom` 保护限制**: 强白名单策略。只有配置了 `8320970051` 的 Telegram 账户才能在私聊和群组中向机器人投递交互请求，其他任何人即使拿到了 Bot Token 也无法触发底层命令。

---

## 7. Google Chat 渠道配置

Google Chat 渠道目前配置处于启用状态，并且服务账号凭据已完成修复：

```json
{
  "channels": {
    "googlechat": {
      "enabled": true,
      "serviceAccount": "{\"type\":\"service_account\",\"project_id\":\"gen-lang-client-0162131477\",\"private_key_id\":\"b4975dc3eb967bb6131c6a628b364d5d09414456\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\\nMIIEvgIBADANBg...\\n-----END PRIVATE KEY-----\\n\",\"client_email\":\"openclaw-agent@gen-lang-client-0162131477.iam.gserviceaccount.com\", ...}",
      "audienceType": "app-url",
      "audience": "https://wly.tailbe620b.ts.net/googlechat"
    }
  }
}
```

> **已修复内容**: 修复了此前 `serviceAccount` 字段仅残留 `\"{\"` 导致 Google Chat 渠道启动时解析 JSON 失败的故障。现已使用保存在 `E:\Downloads` 的谷歌服务账号凭证进行了全字段序列化单行转义写入。

---

## 8. 技能与插件生态

### 8.1 技能清单

- **gemini**: Gemini API 交互
- **github**: 代码仓操作与审计
- **himalaya**: 邮件客户端收发
- **nano-pdf**: PDF 工具集
- **openai-whisper**: 语音模型支持
- **agent-browser**: 无头浏览器上网自动化与爬虫
- **self-improving**: 核心自愈与周期运行脚本
- **session-logs**: 会话流程收集

### 8.2 插件

- `google`, `googlechat`, `parallel` (支持多代理并行并发调度)

### 8.3 安全禁用规则

```json
{
  "gateway": {
    "nodes": {
      "denyCommands": [
        "camera.snap", "camera.clip", "screen.record",
        "contacts.add", "calendar.add", "reminders.add",
        "sms.send", "sms.search"
      ]
    }
  }
}
```

---

## 9. 缺陷审计与已修复项

网关经历了几轮深度调试，目前所有发现的缺陷已全数修复：

| # | 缺陷描述 | 原状态 | 修复后状态 | 严重度 | 状态 |
|---|----------|------|------------|--------|------|
| 1 | 触发器使用 LogonTrigger，未登录时不启动 | `LogonTrigger` | `BootTrigger +30s` | 🔴 致命 | ✅ 已修复 |
| 2 | LogonType 设为交互导致开机报黑框/无响应 | `InteractiveToken` | `S4U` (完全静默后台运行) | 🔴 致命 | ✅ 已修复 |
| 3 | 网关进程权限受限，无法执行网络路由等特权操作 | Limited 权限 | `Highest` (以管理员上下文运行) | 🔴 严重 | ✅ 已修复 |
| 4 | 密码变量写在 User 级别，S4U 早期读取不到 | User 注册表 | **Machine 系统环境变量** | 🟡 中等 | ✅ 已修复 |
| 5 | Google Chat `serviceAccount` JSON 破损 | `\"{\"` (不完整) | 完整的 Service Account JSON 转义串 | 🟡 中等 | ✅ 已修复 |
| 6 | 端口 18789 挂死时缺乏有效手段自愈 | 无 | 15分钟看门狗 `openclaw_heartbeat.ps1` | 🟡 中等 | ✅ 已修复 |
| 7 | Node.js 内存无约束，长期运行可能爆物理内存 | 无控制 | `gateway.cmd` 限定为 512MB 堆空间 | 🟡 中等 | ✅ 已修复 |
| 8 | 网关控制台输出未重定向，挂死后找不到报错日志 | 输出直接废弃 | 重定向至 `gateway.log` 2>&1 | 🟡 中等 | ✅ 已修复 |
| 9 | 运行日志量过大，日志暴涨 | 默认 debug | `OPENCLAW_LOG_LEVEL=warn` 变量过滤 | 🟢 低 | ✅ 已修复 |

---

## 10. 已实施的调优项与安全配置

### 10.1 性能与稳定性调优（已全数实施）
- **`--max-old-space-size=512`**: 约束 Node.js 在 512MB 物理堆范围内做垃圾回收，避免垃圾积攒导致内存泄漏膨胀。
- **日志文件归档重定向**: 确保有历史日志可查。
- **`OPENCLAW_LOG_LEVEL=warn`**: 避免在生产阶段输出冗余的调试日志。
- **看门狗服务循环自愈**: 彻底消除了进程无响应时必须人工介入的情况。

### 10.2 安全防护
- **密码保护**: Machine 级别环境变量 + HTTPS 链路。
- **最小权限暴露**: Loopback 绑定 + Tailscale 设备授权网络隔离。
- **执行命令黑名单**: 全面拦截调用短信、摄像头、屏幕录像等风险指令。

---

## 11. 灾难恢复与重装指南

### 11.1 重装 Windows 系统后恢复 OpenClaw

```powershell
# 1. 以管理员权限打开 PowerShell，安装 Node.js LTS
winget install OpenJS.NodeJS.LTS

# 2. 安装全局网关
npm install -g openclaw

# 3. 将原备份的 .openclaw 文件夹复制回 $HOME\.openclaw\ 目录下

# 4. 在系统级别注册网关的静态认证密码
[System.Environment]::SetEnvironmentVariable('OPENCLAW_GATEWAY_PASSWORD', 'wlySecureClaw2026!', 'Machine')

# 5. 执行本仓库的自愈部署脚本重新组装计划任务
powershell -ExecutionPolicy Bypass -File "E:\RamdiskGuardian\openclaw_silent_boot_guardian.ps1"

# 6. 安装看门狗心跳检测计划任务
Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -NoProfile -File "E:\RamdiskGuardian\logs\_elevate_heartbeat.ps1"' -Verb RunAs -Wait

# 7. 重启电脑，网关和看门狗就会在 1 分钟内自动进入静默运行状态
```

---

## 12. 运维速查命令

### 12.1 状态与日志排查

```powershell
# ──── 网关运行排查 ──────────────────────────────────────
# 测试本地网关端口响应
Test-NetConnection -ComputerName 127.0.0.1 -Port 18789

# 实时查看网关的运行日志 (已过滤为 warning 和以上级别)
Get-Content -Path "C:\Users\10979\.openclaw\gateway.log" -Tail 50 -Wait

# 实时查看心跳守护日志
Get-Content -Path "E:\RamdiskGuardian\logs\openclaw_heartbeat.log" -Tail 50 -Wait

# ──── 计划任务手动干预 ──────────────────────────────────
# 手动强制重启网关任务
Stop-ScheduledTask -TaskName "OpenClaw Gateway"
Start-ScheduledTask -TaskName "OpenClaw Gateway"

# 手动触发看门狗心跳自愈检测
powershell.exe -ExecutionPolicy Bypass -File "E:\RamdiskGuardian\openclaw_heartbeat.ps1"
```

### 12.2 网关更新维护

```powershell
# 运行自动升级脚本 (升级包、重启任务、执行健康检测)
powershell.exe -ExecutionPolicy Bypass -File "E:\RamdiskGuardian\openclaw_update.ps1"
```

---

## 13. 文件清单

```
E:\RamdiskGuardian\
├── OPENCLAW.md                         ← 本运维手册
├── OPENCLAW.pdf                        ← 导出的 PDF 运维手册
├── openclaw_silent_boot_guardian.ps1    ← 静默启动自愈配置脚本
├── openclaw_heartbeat.ps1               ← [NEW] 心跳看门狗周期检测脚本
├── openclaw_update.ps1                  ← [NEW] 自动化全局更新与测试脚本
├── openclaw_run_hidden.vbs             ← VBScript 隐藏黑窗拉起工具
├── openclaw_task.xml                   ← 网关任务备份配置 XML
└── logs\
    ├── openclaw_guardian.log           ← 自愈配置运行日志
    └── openclaw_heartbeat.log          ← [NEW] 15 分钟心跳检测日志
```

---

## 14. 变更历史

| 日期 | 类型 | 修改概要 |
|------|------|----------|
| **2026-06-16** | 🔴 缺陷修复 | 修复 Google Chat `serviceAccount` 凭据 JSON 不完整的问题 |
| **2026-06-16** | 🔴 新增守护 | 创建 15 分钟间隔看门狗心跳任务 `OpenClaw Heartbeat` 及检测脚本 |
| **2026-06-16** | 🟡 运维加固 | `gateway.cmd` 增加 Node.js 内存堆上限 512MB，添加 `gateway.log` 输出重定向 |
| **2026-06-16** | 🟡 环境变量 | 将网关认证密码由用户级提升为系统 Machine 级注册表级 |
| **2026-06-16** | 🟢 升级工具 | 编写 `openclaw_update.ps1` 脚本，支持静默全局安全升级与热重启校验 |
| **2026-06-16** | 🟢 计划任务 | 重建 `OpenClaw Gateway` 任务，采用 `BootTrigger +30s` 延迟和 `S4U` logon 隐藏窗口 |
