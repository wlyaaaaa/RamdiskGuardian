# 快速部署指南（系统重装 / 换电脑）

> 目标：在一台**重装系统**或**全新电脑**上，把 Z 内存盘这套（开机自启 + 镜像持久化 +
> 守护备份/自愈）**最快速地重新搭起来**，并尽量不丢数据。
> 配合 `README.md`（原理与运维）一起看。

---

## 0. 先理解：哪些会丢、哪些能留

| 东西 | 在哪 | 重装 C 盘 | 换新电脑 |
|---|---|---|---|
| 仓库脚本 `RamdiskGuardian` | E 盘（或 GitHub） | ✅ 留 | 需拷贝/`git clone` |
| **数据备份 `E:\Z_Drive_Backup`** | E 盘 | ✅ 留（关键！） | **需手动拷到新机** |
| Primo 镜像 `*.vdf` | 取决于你放哪 | 放 C 会丢 / **放 E 不丢** | 需拷贝（或重建空镜像） |
| Primo 软件 + 授权 | C 盘 | ❌ 需重装+重新授权 | ❌ 需重装+授权 |
| Z 盘里的实时内容 | 内存 | ❌ 易失 | ❌ 易失 |

> **核心结论**：只要 **`E:\Z_Drive_Backup` 还在**（或已拷到新机），`projects/docs/others`
> 就能被守护脚本自动还原。所以：
> - **强烈建议把 Primo 镜像放到数据盘**（如 `E:\RamdiskImage\Z.vdf`），这样重装系统盘也不丢镜像。
>   （本机当前镜像在 `C:\PR-Image-Z.vdf`，重装前请先迁到 E 盘或确认 `E:\Z_Drive_Backup` 是最新的。）
> - 重装/换机**之前**，确认 `E:\Z_Drive_Backup` 是最新（守护脚本每 15 分钟在更新它），
>   且仓库已 `git push` 到 GitHub。

---

## 1. 前置条件

- 一块**数据盘**（本机是 `E:`，3TB+）。仓库和备份都放它上面，跨系统重装不丢。
- 管理员权限。
- 联网（用于 `git clone` 仓库，可选）。

---

## 2. Part A — 安装 Primo 并手动建盘（唯一不能脚本化的部分，约 2 分钟）

> Primo Ramdisk 没有命令行，建盘只能在它界面里点。参考仓库 `docs/primo_setup.png`。

1. **安装 Primo Ramdisk 旗舰版**（本机版本 6.6.0），输入授权码激活。
2. 打开 Primo → 点工具栏**绿色 ➕（创建磁盘）**，按下表设置（对应那几个子对话框）：

   | 对话框 | 设置 |
   |---|---|
   | 组件设置 → **内存盘** | 勾 **动态内存管理** + **紧凑模式** |
   | 虚拟硬盘参数 → 基本 | 硬盘容量 **32768 MB**；盘符 **Z** |
   | 虚拟硬盘参数 → 类型 | **SCSI 硬盘** |
   | 虚拟硬盘参数 → **属性** | **「临时」不要勾**（不勾 = 持久盘 = 开机自启，这就是关键！） |
   | 文件系统设置 → 基本 | **NTFS**；逻辑卷卷标 **RAMDISK**；勾「自动创建 TEMP 文件夹」 |
   | **启用镜像** | 勾上，浏览选镜像路径——**建议 `E:\RamdiskImage\Z.vdf`**（放数据盘，重装不丢） |

3. 点**确定**完成。列表里出现 `RAMDISK (Z:)` 即成功。

> 说明：6.6 没有独立的「随系统启动创建」勾选框——**不勾「临时」+ 关闭快速启动（Part B 自动做）** 就是开机自启。
> 「启用镜像」+ 非临时盘 = 默认开机加载、关机保存（持久化）。想要定时保存防断电，可在「镜像设置」里开。

---

## 3. Part B — 一键部署（自动完成其余全部）

1. 把仓库放到数据盘，例如 `E:\RamdiskGuardian`：
   ```powershell
   # 方式一：从 GitHub 拉
   git clone https://github.com/wlyaaaaa/RamdiskGuardian.git E:\RamdiskGuardian
   # 方式二：直接把备份的仓库文件夹拷过去
   ```
2. **以管理员身份**打开 PowerShell，运行部署脚本：
   ```powershell
   powershell -ExecutionPolicy Bypass -File E:\RamdiskGuardian\deploy.ps1
   ```
   它会自动：关闭快速启动 → 建 `Z_Drive_Backup`/`logs` → 注册计划任务（登录+每15分钟）→
   跑一次守护（建骨架、**从 `E:\Z_Drive_Backup` 还原你的数据**）→ 重建 Chrome 缓存 junctions (Cache, Code Cache, GPUCache)。

   - 盘符不是 Z？`-RamDrive R`（会自动写 `ramdrive.txt`，守护脚本随之适配）。
   - 用户名不同？脚本默认用**当前登录用户**，一般无需指定；要指定加 `-User 名字`。
   - 备份间隔改成 10 分钟？`-IntervalMinutes 10`。

3. **360 压缩**（如已装）：在 360 设置里把「解压缓存目录」设为 `Z:\Caches\360zip_temp`（脚本已建好该目录）。

---

## 4. Part C — 验证

```powershell
# 看健康状态（应 OK）
Get-Content E:\RamdiskGuardian\logs\STATUS.txt
# 看任务
Get-ScheduledTask RAMDisk_Code_Backup | Format-List TaskName,State
```
然后 **重启一次电脑**，开机后不操作，确认 `Z:` 自动出现且为 32GB。
- 出现 ✅ → 部署成功。
- 没出现 ❌ → 多半是 Primo 那块没设成"非临时"或快速启动没关；守护脚本也会在开机后把
  `STATUS.txt` 标 ERROR 并弹窗提醒你。

---

## 5. 不同环境的适配点（可移植性）

脚本已尽量自适配，无需改代码：
- **仓库位置**：守护脚本用 `$PSScriptRoot` 自动定位，放哪个盘哪个目录都行。
- **数据盘盘符**：自动取"仓库所在盘"，备份固定在 `<该盘>\Z_Drive_Backup`。
- **内存盘盘符**：默认 `Z`，用 `deploy.ps1 -RamDrive X` 覆盖（写入 `ramdrive.txt`）。
- **用户名**：计划任务用当前用户；Chrome junction 按当前用户路径自动找。
- **Chrome**：部署时若 Chrome 开着会跳过 junction（提示你关掉重跑）。

---

## 6. 卸载 / 回滚

```powershell
# 删计划任务
Unregister-ScheduledTask -TaskName RAMDisk_Code_Backup -Confirm:$false
# 还原快速启动（如需要）
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 1 -Type DWord
# Chrome 缓存 junction 还原：关闭 Chrome 后删除 junction，让 Chrome 自己重建本地 Cache
# (Default\Cache 是 junction，rmdir 它不会删到 Z 上的真实数据)
# Primo 盘：在 Primo 界面删除即可
```

---

## 7. 一句话清单（熟手版）

```
重装前: 确认 E:\Z_Drive_Backup 最新 + git push；镜像最好在 E 盘
重装后: 装Primo+授权 → 建非临时32G盘(启用镜像) → clone仓库 → 管理员跑 deploy.ps1 → 重启验证Z自动回来
```
