# RamdiskGuardian

维护 cache-only RAM Disk 的目录骨架、根使用说明、空间与宿主内存健康，并在持续压力且允许恢复时执行有界的 Primo 重建。它不备份数据，不把 Z 当源码盘，也不自动清理其它程序的未知缓存。

## 日常使用

使用 PowerShell 7。只读查看状态：

```powershell
pwsh -NoProfile -File .\Get-RamdiskHealth.ps1 -Json
pwsh -NoProfile -File .\zguardian.ps1 -Inspect -Json
```

图形入口为 PCConfig 的 `tools\Show-StreamingMaintenance.ps1`。窗口显示健康、新鲜度、最近和下次任务执行、恢复冷却与活动消费者；可分别暂停自动重建或停止守护。关闭窗口不停止既有守护，也不会更改电源、显示器或驱动。

## 自动运行与状态

调用链：`RAMDisk_Code_Backup` → `run_hidden.vbs` → `zguardian.ps1`。兼容任务名保留，不代表仍有数据备份。任务使用实际交互式用户、PowerShell 7、登录触发和独立的每 15 分钟触发，禁止重叠运行；全局互斥锁同样保护手动调用和部署。

`logs\health.json` 是结构化观察；`logs\STATUS.txt` 为兼容的人类状态；`guardian.log`、`alerts.log` 有界轮转。健康文件使用同目录原子替换和一个 previous。退出码 0 只表示本轮完成，WARN 可以成功完成但不等于健康；关键错误必须返回非零。仅 ERROR 状态变化弹一次消息，WARN 保持静默。

只读健康入口还验证任务启用状态、周期、观察时间、实际源码哈希、卷和说明文件，过时的 OK 不会当成当前正常。

## 磁盘与缓存合同

当前机器配置是 12 GiB、NTFS、卷标 RAMDISK 的 Primo 动态内存盘；默认 Z，自定义盘符通过部署入口配置。开始写盘前同时验证盘符、卷标和 Primo 当前唯一磁盘编号；拒绝依靠固定 0 号盘。缓存目录若意外变成重解析链接则报错，不沿链接写其它位置。

创建 Personal/Work 的 Caches 和 Scratch、兼容 Chrome/360/WeFlow 缓存目录以及 TEMP。根说明来自唯一的 `Z_使用说明.md`，复制后核对哈希，全部必要步骤成功后才建立就绪标记。不要把任何 Git 正式仓库、worktree 或唯一资料放在 Z；个人新仓库使用 `V:\Personal\Projects`。

缓存生产者拥有自己的生命周期：在任务成功、失败或接管收口时清理或迁出已确认失效对象。不做整盘盲目定时清空，不删除其它 owner 或活动中的未知缓存。机器级策略由 PCConfig 的 `docs\governance\dev_storage_policy.md` 拥有。

## 有界自动重建

保留既定阈值：盘内占用不超过 8 GiB，宿主可用内存低于 5 GiB，或者不可归属内存达到 8 GiB。触发前至少 10 秒取得 3 次连续样本；样本间隔超过 30 秒重新确认。一般资源提醒仍为盘剩余小于 2 GiB、盘使用超过 8 GiB、宿主可用内存小于 8 GiB、提交余量小于 4 GiB、不可归属内存达到 4 GiB。

活动消费者、消费者证据不明、用户暂停或恢复冷却均阻止重建。尝试间隔至少 1 小时；失败暂缓 1 小时；回读无法证明至少 1 GiB 的内存改善，暂缓 6 小时。重建前重新核对 Primo 编号和卷身份，重建后验证目录、说明、卷与原生命令结果；内存改善未知不伪装成有效释放。

可再生成不等于活动任务不会受影响。租约接入是合作式的，不声称未接入的旧浏览器或程序已具备占用保护。长任务应登记真实消费者 PID，续租并在结束时释放：

```powershell
.\Use-RamdiskCacheLease.ps1 -Mode Acquire -Name build -ConsumerProcessId $PID -Seconds 3600
.\Use-RamdiskCacheLease.ps1 -Mode Renew -Name build -ConsumerProcessId $PID -Seconds 3600
.\Use-RamdiskCacheLease.ps1 -Mode Release -Name build -ConsumerProcessId $PID
```

租约记录 PID、进程创建时间及期限，防止 PID 复用；注册与重建使用同一互斥锁。只暂停自动重建而继续维护目录和健康：

```powershell
.\Set-RamdiskRecoveryMode.ps1 -Mode Pause -Apply -Json
.\Set-RamdiskRecoveryMode.ps1 -Mode Resume -Apply -Json
```

恢复开关不清空冷却期。纯查看无需 `-Apply`。

## 部署、恢复与验证

详见 `DEPLOY.md`。部署默认只读预检；`-Apply` 执行，`-TaskOnly` 只恢复任务。快速启动和 Chrome 缓存迁移为独立显式选项。不会因重装任务而默认清空缓存、改系统电源或重启机器。

```powershell
pwsh -NoProfile -File tests\Assert-RamdiskGuardianStatic.ps1
pwsh -NoProfile -File tests\Test-RamdiskGuardianRecovery.ps1
pwsh -NoProfile -File tests\Test-RamdiskReliability.ps1
pwsh -NoProfile -File tests\Test-RamdiskDeployRollback.ps1
```

测试使用隔离临时目录和假 Primo，不初始化实际磁盘。一次 `zguardian.ps1 -NoRecovery -WaitSeconds 0` 可以验证维护与错误传播，但不能证明真实重建或自然重启恢复；这些验收必须单独记录。