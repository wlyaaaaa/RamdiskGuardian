# RamdiskGuardian 部署 / 恢复

适用于系统重装、换电脑或计划任务丢失。Z 是 cache-only RAM Disk，不需要搬运缓存或旧备份。

## 前置配置

在 Primo Ramdisk 中创建：

- 盘符 `Z:`；
- NTFS、12 GiB、卷标 `RAMDISK`；
- 动态内存和紧凑模式；
- 非临时盘；
- 镜像启用，路径 `E:\RamdiskImage\Z.vdf`。

本仓库的部署脚本不代替 Primo 建盘；界面布局可参考 `docs/primo_setup.png`，其中旧容量不作为当前配置。当前容量固定为 12 GiB。

## 部署

在管理员 PowerShell 中运行：

```powershell
Set-Location E:\Projects\Tools\RamdiskGuardian
.\deploy.ps1
```

脚本会：

1. 关闭 Windows 快速启动；
2. 建立仓库 `logs`；
3. 注册兼容名称 `RAMDisk_Code_Backup` 的计划任务（登录 + 每 15 分钟）；
4. 运行一次守护器，建立 cache-only 骨架和 `Z:\使用说明.md`；
5. 在 Chrome 已关闭时，重建 Cache / Code Cache / GPUCache junction；
6. 提示把 360 压缩临时目录设为 `Z:\Caches\360zip_temp`。

任务名保留旧名称是为了避免不必要的任务注册、监控和恢复引用漂移；它不再执行数据备份。

## 验收

```powershell
Get-Content E:\Projects\Tools\RamdiskGuardian\logs\STATUS.txt
Get-ScheduledTaskInfo RAMDisk_Code_Backup | Format-List LastRunTime,LastTaskResult
Test-Path Z:\使用说明.md
```

当前运行验收需要同时看状态与任务结果：`STATUS.txt` 为 OK 表示本轮无资源警告；WARN 表示盘仍在工作但空间或内存达到提醒阈值，保持静默，不等于任务失败。`LastTaskResult` 为 0 仅表示脚本执行结束，不能单独证明健康。根说明与缓存目录应存在。

紧急重建前，守护器会从 Primo 当前列表查找配置盘符对应的唯一磁盘编号，避免把自定义盘符错误地重建为 0 号盘。初始化、恢复目录/说明或保存镜像失败时记录 ERROR 并返回非零，不继续报告重建完成。重建会丢弃可再生成缓存，活动应用可能需要重新加载；不得把唯一数据放进去。

启动恢复验收留到下一次自然重启：确认 Z 自动出现、容量约 12 GiB，并复核计划任务结果和最新健康记录；当前挂载、代码测试或一次手动运行都不能替代它。

## 回退计划任务

仅在明确不再使用本守护器时，以管理员身份运行：

```powershell
Unregister-ScheduledTask -TaskName RAMDisk_Code_Backup -Confirm:$false
```

删除任务不会删除 Primo 盘或缓存。重启、删盘、改镜像和删除缓存属于独立动作，不由本回退自动执行。
