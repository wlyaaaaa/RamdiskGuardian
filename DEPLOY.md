# RamdiskGuardian 部署 / 恢复

适用于系统重装、换电脑或计划任务丢失。Z 是 cache-only RAM Disk，不需要搬运缓存或旧备份。

## 前置配置

在 Primo Ramdisk 中创建：

- 盘符 `Z:`；
- NTFS、32 GiB；
- 动态内存和紧凑模式；
- 非临时盘；
- 镜像启用，路径 `E:\RamdiskImage\Z.vdf`。

Primo 没有可依赖的本仓库命令行建盘流程；界面参考 `docs/primo_setup.png`。

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

当前运行验收：`STATUS.txt` 为 OK、`LastTaskResult` 为 0、根说明存在。启动恢复验收：下一次自然重启后，Z 自动出现、容量约 32 GiB，计划任务再次返回 0。

## 回退计划任务

仅在明确不再使用本守护器时，以管理员身份运行：

```powershell
Unregister-ScheduledTask -TaskName RAMDisk_Code_Backup -Confirm:$false
```

删除任务不会删除 Primo 盘或缓存。重启、删盘、改镜像和删除缓存属于独立动作，不由本回退自动执行。
