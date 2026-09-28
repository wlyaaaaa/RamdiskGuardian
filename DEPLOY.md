# RamdiskGuardian 部署 / 恢复

Z 是 cache-only RAM Disk；恢复守护不需要迁回旧缓存，也不恢复退役的数据备份通道。使用管理员 PowerShell 7。先在普通权限下预检，执行时再按实际权限要求提升。

## Primo 前置配置

在 Primo 中创建非临时盘：Z、NTFS、12 GiB、卷标 RAMDISK、动态内存和紧凑模式，启用镜像。当前机器登记的镜像路径为 `E:\RamdiskImage\Z.vdf`。部署脚本不代替 Primo 建盘。`docs/primo_setup.png` 仅展示界面布局，旧容量不代表当前配置。

## 先查看计划

```powershell
Set-Location E:\Projects\Tools\RamdiskGuardian
.\deploy.ps1 -Json
```

默认不写任务、不改注册表、不迁移 Chrome 缓存。实际任务必须属于真实交互式用户；SYSTEM 维护通道不能被误当成用户。已有任务可解析原用户；首次恢复时使用 `-User '<实际交互式账户>'`。

## 选择精确的部署范围

只恢复或升级任务，不改电源与缓存：

```powershell
.\deploy.ps1 -TaskOnly -Apply -Json
```

完整部署、核对盘符、运行无重建的初始化：

```powershell
.\deploy.ps1 -Apply -Json
```

需要修改 Windows 快速启动时显式加 `-DisableFastStartup`；需要迁移 Chrome 默认配置的 Cache、Code Cache、GPUCache 时显式加 `-WireChromeCaches`。两者不能与 `-TaskOnly` 混用。Chrome 运行时缓存迁移会延后，不强制结束浏览器。旧目录或链接先改名保留，再建立和回读 junction，不递归删除用户目录。

非默认盘符使用 `-RamDrive R`；从自定义盘符返回 Z 会移除旧覆盖配置。`-IntervalMinutes` 范围 1–1440，默认 15。调度由登录触发和独立的周期触发组成，部署后无需等待下次登录才有下一次周期检查。

360 压缩仍由用户在其设置中选择对应盘的 `Caches\360zip_temp`；部署不盲改其配置编码。任务名 `RAMDisk_Code_Backup` 仅为兼容保留，不执行数据备份。

## 回读与回滚

部署把原任务 XML、盘符覆盖、电源原值及缓存目录改名记录保存在本项目 `logs\deploy-*`，输出精确恢复路径；发生安装阶段错误时按修改逆序尝试恢复，并报告恢复失败。已安装任务后若初始化失败，会重新取得守护互斥锁并执行同一回滚路径；锁不可用时明确保留恢复材料并报告未完成，不以任务存在冒充成功。

```powershell
.\Get-RamdiskHealth.ps1 -Json
Get-ScheduledTaskInfo -TaskName RAMDisk_Code_Backup
```

同时检查任务启用、下一次执行、观察新鲜度、源码版本、卷健康、目录与根说明。OK 表示本轮无资源提醒；WARN 表示有明确资源压力或恢复延后；ERROR 必须非零退出。只有退出码为 0 不足以证明健康。

恢复任务不重启机器、不重新初始化真实内存盘。下一次自然重启后，再确认 Z 自动出现且容量约 12 GiB，任务和健康记录随之更新。当前挂载、测试或手动初始化不能替代启动恢复验收。

内存压力判断、相对基线、暖机与历史回放见 [内存压力判断与回放](docs/memory-recovery.md)。升级源码时在守护互斥锁内同时更新主脚本和模块，保留 `logs` 中的暂停、租约与冷却状态；先以 `-NoRecovery` 验证，再回读 `health.json` 的源码哈希与新指标。不要把计划任务指向临时工作副本，也不要为验收运行真实 `init`。第一次升级及机器重启后，相对基线至少需要三个有效观察、三十分钟；此时原始强信号和资源警告仍有效。

## 暂停与停止

日常通过“RAMDisk 与远程串流维护”窗口分别暂停自动重建或停止整个守护。暂停自动重建不停止目录维护，恢复不清空冷却。停止守护不卸载 Primo、不删除盘和缓存。需要彻底卸载守护任务时，独立明确执行 `Unregister-ScheduledTask`；这也不会删除实际 RAMDisk 或镜像。
