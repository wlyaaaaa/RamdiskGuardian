# 缓存放置与资源成本

## 决策原则

Z 只用于已有、体积有界且可重建的缓存，不为了利用剩余容量新增常驻缓存。现有 Chrome 网页、代码和 GPU 缓存可以保留；空的 360 压缩、WeFlow、Personal/Work 与 Scratch 目录不证明已有实际消费者或性能收益。不把唯一文件、整个用户目录、全局 TEMP/TMP、数据库、模型、包缓存大仓、Docker/WSL 数据盘迁入 Z。

先测用户真实慢任务的总耗时，再比较 NVMe 与 RAMDisk。磁盘跑分、低延迟或文件已经位于 Z，都不能替代实际业务提速证据。没有可重复的总耗时改善，就不扩大覆盖面；大规模可重建开发输出优先沿用 PCConfig 的 V/Dev Drive 策略。

## 只读成本检查

```powershell
pwsh -NoProfile -File .\Get-RamdiskEfficiency.ps1 -Json
# 需要管理员权限；只运行 Primo ls/view，不启动 GUI，不保存或重建磁盘。
pwsh -NoProfile -File .\Get-RamdiskEfficiency.ps1 -IncludePrimo -Json
```

`Get-RamdiskHealth.ps1` 负责是否健康；效率入口负责区分磁盘容量、卷已用空间、镜像逻辑长度、镜像实际磁盘分配、宿主物理内存和可用内存。当前 Primo CLI 不提供此盘独占的真实驱动分配值，`DriverAllocatedBytes` 保持 null，绝不拿容量或已用空间代替。`SpeedupPercent` 同样不会凭观察计算。

配置中的 Compact 与当前运行模式分别报告。它们不一致可能是尚未生效或驱动调整，原因未知时不猜测，不反复切换设置或重建磁盘让检查变绿。镜像缩小不证明已经释放相同大小的 RAM，也不证明自然启动已通过。

## 镜像维护

保留既有镜像路径与 Shutdown Save，避免每次启动丢掉有价值的浏览器代码缓存。镜像明显大于有效数据时，只在维护窗口使用厂商 `save <实际索引> -a <新候选> -F COMPACT -s` 重建紧凑副本。先通过 `ls` 验证唯一盘符与索引，再核对卷身份；不能假定始终是 0 号盘。

候选必须由成功的原生命令生成，检查大小、SHA-256 和同一次运行回执。原镜像未变化时才将候选移入目标同目录，用原子替换发布到原路径，并保留单份原镜像回滚副本。候选与发布后文件的哈希分别回读。原镜像可通过全文件哈希核对，或在禁止原文件写入的打开句柄下以原子替换保留，并验证回滚副本仍具有原 NTFS 文件身份和长度；后一种方式不把“没有重写原文件”夸称为完成了全文件校验。失败保留证据，不重复执行未知状态的事务。镜像与回滚副本可能包含浏览器缓存，均留在本机，不进入 Git 或网页。

不使用 Associate、init 或 rebuild 来压缩镜像，因为这些不是普通文件维护，会影响盘内数据或现有句柄。不强关浏览器、不停驱动、不主动重启电脑；本次运行态验证与自然重启加载验证分开。旧回滚镜像仅在替换镜像的自然加载经过验证后按既有授权清理，不通过新增定时任务盲删。

小于 1 GiB 的镜像保留直接加载；厂商说明延迟加载仍有首次访问开销，不应对很小镜像机械开启。12 GiB 是动态内存盘的容量上限，不以缩小容量冒充已经释放物理内存。机器路径、容量和共享策略仍由 PCConfig 持有。

## 验证

新增资源成本或解析逻辑后运行 `tests/Test-RamdiskEfficiency.ps1`，并保留 Health、Static、Recovery、Reliability、DeployRollback 全部既有回归。测试使用内存文本和任务 TEMP 中的独立文件，不加载真实镜像、不修改实际 RAMDisk。

参考：Romex 官方 Dynamic Memory Management、Image File Features、CLI 和 Manually Save Disk Contents 文档。使用前以安装版本的 `rxprd ? <command>` 核对语法，不照搬其他版本或未经证实的底层接口。
