# RamdiskGuardian — Z: 有界热缓存守护

本仓库维护这台机器的 32 GiB 动态 RAM Disk。Z 的当前合同是 **cache-only**：只放丢失后可自动重建的缓存和 scratch，不承载正式项目、唯一数据或备份。机器级放置策略以 `E:\PCConfig\docs\governance\dev_storage_policy.md` 为权威。

最后更新：2026-07-20。

## 当前职责

调用链：计划任务 `RAMDisk_Code_Backup` → `run_hidden.vbs` → `zguardian.ps1`。任务在登录时及以后每 15 分钟运行。

任务名是历史兼容名称；当前守护器不执行备份或恢复，只负责：

- 等待 Z 出现并记录健康；
- 自恢复 `Caches/Personal`、`Caches/Work`、`Scratch/Personal`、`Scratch/Work`、`TEMP` 及现有应用缓存目录；
- 把仓库内 `Z_使用说明.md` 同步为 `Z:\使用说明.md`；
- 监控 Z 占用、系统可用内存和提交余量；
- 状态变化为 WARN/ERROR 时写日志并弹一次消息。

历史 `projects/docs/others` 通道及其追加式备份逻辑已在确认盘内和旧备份均为空后退役。守护器不再创建这些目录，也不依赖 `E:\Backups\Z_Drive_Backup`。

## 目录合同

```text
Z:\
├─ 使用说明.md
├─ Caches\
│  ├─ Personal\
│  ├─ Work\
│  ├─ ChromeCache\
│  ├─ ChromeCodeCache\
│  ├─ ChromeGPUCache\
│  ├─ 360zip_temp\
│  └─ WeFlow\
├─ Scratch\
│  ├─ Personal\
│  └─ Work\
├─ TEMP\
└─ .ramdisk_ready
```

个人与工作目录只是组织边界。共享 RAM Disk 和镜像不是安全隔离。

## 资源策略

- 新缓存总量以 8 GiB 为软上限；32 GiB 是盘容量，不是使用目标。
- 系统可用物理内存低于 8 GiB、提交余量低于 4 GiB、Z 剩余空间低于 2 GiB或占用超过软上限时告警。
- 不自动删除未知缓存，避免打断仍在运行的 Chrome、WeFlow 或开发工具。
- 本机已有高速 NVMe、9950X3D 和 5090D。只有真实工作负载计时证明 I/O 是瓶颈时，才新增 Z 缓存；没有可感知收益就保持原位。
- 大型包缓存、正式 Git 项目和需要跨重启的构建状态放 V；个人新仓库默认 `V:\Personal\Projects`。

## Primo 与启动

本机预期为 Z: / NTFS / 32 GiB / 动态内存 / 非临时盘，镜像位于 `E:\RamdiskImage\Z.vdf`。Windows 快速启动已关闭。Primo 的“非临时盘 + 启用镜像”负责启动重建，守护器不冒充驱动层自动挂载证明。

自动恢复的最终验收需要一次自然重启后读回。没有明确重启授权时，不为这项验证中断当前工作。

## 健康与运维

```powershell
# 手动运行一次
powershell -NoProfile -ExecutionPolicy Bypass -File E:\Projects\Tools\RamdiskGuardian\zguardian.ps1

# 查看状态和最新日志
Get-Content E:\Projects\Tools\RamdiskGuardian\logs\STATUS.txt
Get-Content E:\Projects\Tools\RamdiskGuardian\logs\guardian.log -Tail 20

# 查看计划任务
Get-ScheduledTask RAMDisk_Code_Backup | Format-List TaskName,State
Get-ScheduledTaskInfo RAMDisk_Code_Backup | Format-List LastRunTime,LastTaskResult
```

`STATUS.txt` 中 `OK` 表示本轮成功；Windows 计划任务 `LastTaskResult = 0` 表示任务成功。Z 不存在时守护器等待最多 150 秒，随后记录 ERROR。

## 文件清单

```text
RamdiskGuardian/
├─ README.md
├─ DEPLOY.md
├─ Z_使用说明.md
├─ deploy.ps1
├─ zguardian.ps1
├─ run_hidden.vbs
├─ tests/Assert-RamdiskGuardianStatic.ps1
├─ archive/sync_code.bat.bak_20260614
└─ logs/                         运行态，不入库
```

归档脚本仅作历史证据，不是入口。曾经的 `/MIR` 方案在掉盘后把空源镜像到备份并造成数据丢失；当前 cache-only 设计从根上消除了“把 RAM Disk 当数据源并备份”的需求。
