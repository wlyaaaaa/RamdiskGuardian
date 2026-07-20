# RamdiskGuardian — Z: 有界热缓存 / 稳定性 / 自愈方案

> 本仓库是这台机器上 **Primo Ramdisk（Z 盘）** 的缓存优先稳定化方案：开机自启、镜像持久化、
> 掉盘自愈、旧数据通道兼容和内存压力告警。给本人和以后的 AI 维护者查阅。
> 最后更新：2026-07-20。
>
> 🚀 **系统重装 / 换电脑**：直接看 [`DEPLOY.md`](DEPLOY.md)（含 Primo 手动建盘 + `deploy.ps1` 一键部署）。

---

## 0. 一句话现状

`Z:` 是一块 **32GB 动态内存盘**（Primo Ramdisk 旗舰版 6.6.0，驱动 `FancyRd`，引导级）。
新用途为 cache-only：只允许缓存和 scratch，不再把正式项目、文档或唯一数据放入 Z。它与 `V:` Dev Drive 的机器级分工以
`E:\PCConfig\docs\governance\dev_storage_policy.md` 为权威。

```
① 存在性  : Primo「非临时盘」→ 每次开机由驱动自动重建（需关掉 Windows 快速启动）
② 持久化  : Primo 镜像文件 E:\RamdiskImage\Z.vdf → 开机加载内容 / 关机保存内容
③ 监控+自愈: 本仓库守护脚本 → 每 15 分钟检查盘、内存和提交余量；重建骨架；兼容旧通道恢复
```

---

## 1. ⚠️ 关于「开机自启」的真相（重要，之前理解错过）

**Primo Ramdisk 6.6.0 没有「随系统启动自动创建此磁盘」这个独立勾选框。**
它的开机自启机制是：

- 在「虚拟硬盘参数」对话框 → 「属性」里，**不勾选「临时」** ＝ 这是一块**持久盘** ＝
  系统每次启动时由引导驱动自动重建。勾了「临时」才是一次性、重启不回来的盘。
- 所以正确做法就是：**建盘时别勾「临时」**（本机已是非临时盘 ✅）。

**之前一直掉盘、配置写不进去的真凶 = Windows 快速启动（Fast Startup）。**
它让系统「假关机」（混合休眠 hiberboot），不是真正冷启动 / 冷关机，于是
Primo「关机保存配置、开机重建盘」的循环被破坏。

➡️ **已处理**：`HiberbootEnabled` 已设为 `0`（关闭快速启动）。
注册表位置：`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled`

### 如何最终验证开机自启是否生效
1. 正常**重启一次电脑**（关快速启动后是真正冷启动）。
2. 开机后不做任何操作，看 `Z:` 是否**自动出现且为 32GB**。
   - 出现 ✅ → 开机自启成功，三层防线齐活。
   - 没出现 ❌ → 打开 Primo → 工具栏齿轮「设置」里找是否有「随 Windows 启动 / 开机加载」之类
     的**全局开关**需要打开；仍不行就回来排查（守护脚本会在开机后 STATUS 标记 ERROR 并弹窗）。

---

## 2. 当前 Primo 盘配置（本机实际值）

| 项目 | 值 |
|---|---|
| 盘符 / 文件系统 / 卷标 | `Z:` / NTFS / `RAMDISK` |
| 容量 | 32768 MB（32GB） |
| 类型 | SCSI 硬盘 |
| 内存模式 | 动态内存管理 + 紧凑模式（按需占用，写多少占多少） |
| 临时属性 | **未勾选**（= 持久盘 / 开机自启） |
| 镜像 | 启用，紧凑镜像 `E:\RamdiskImage\Z.vdf`（开机加载 / 关机保存） |
| NTFS 权限 | Everyone：修改 / 读取执行 / 写入 |

> 镜像当前已位于 `E:\RamdiskImage\Z.vdf`。是否继续保存缓存镜像属于未来 Primo 专项调整；
> 当前不为追求理论性能改动已稳定的启动与镜像配置。

### 关于「镜像持久化没有设置项」
Primo 里只要**盘是非临时 + 勾了「启用镜像」**，默认行为就是
**创建时载入镜像内容、退出/关机时保存内容**——这就是持久化，不需要额外开关。
若想要「定时自动保存」，在「虚拟硬盘参数」里点 **「镜像设置」**。新设计不建议为缓存增加定时整盘写入；
第 ③ 层守护脚本只为旧版 `projects/docs/others` 通道保留兼容备份，新缓存不进入备份。

---

## 3. 第 ③ 层：守护脚本（本仓库核心）

**脚本**：`zguardian.ps1`
**调用链**：计划任务 `RAMDisk_Code_Backup` → `run_hidden.vbs`（隐藏窗口）→ `zguardian.ps1`
**触发**：用户登录时 + 之后每 **15 分钟**；身份 `10979` / **交互会话（不是会话0）** / 最高权限。

> 为什么是交互会话而不是会话0：备份要在你登录、真正改动文件时跑才有意义；而且 Z 是
> 全局盘（实测 SYSTEM/会话0 也能看到），交互会话同样看得到，所以放交互会话最合适。

### 逻辑（缓存优先，旧通道兼容）

脚本每次运行先确认 Z 存在并补齐 `Caches/Personal`、`Caches/Work`、`Scratch/Personal`、`Scratch/Work`
等目录。它不会自动删除未知缓存。旧版 `projects/docs/others` 保留以下兼容恢复，禁止新增正式内容：
- **就绪标记 `Z:\.ramdisk_ready` 不存在**（全新盘 / 中途掉盘被重建）→ 从备份**还原**。
- **每次开机后的首次运行**（盘刚从 Primo 镜像加载，镜像可能比备份旧）→ 按**新者为准**从备份
  **补齐**更新的文件（自动纠正"镜像滞后"——例如关机没存到最新镜像时）。
- 其余每次运行 → **只备份、不回拉**（你在 Z 上删的文件不会被复活）。

回拉只复制"备份比盘新"的文件（`robocopy /E /XO`）。备份方向永远是**只增不减 + 新覆盖旧**
（`/E /XO`，无 `/PURGE`）：掉盘或加载到旧镜像都**不可能删除/缩小/降级备份**。
代价：你**主动删除的文件会保留在 `E:\Backups\Z_Drive_Backup` 里**（为"绝不丢数据"做的取舍）；
想清理直接手动删 `E:\Backups\Z_Drive_Backup` 即可。

### 安全护栏（吸取过的教训）
旧脚本用 `robocopy /MIR`，某次掉盘后 `Z:\projects` 变空目录，`/MIR` 把"空"镜像到了
`E:\Backups\Z_Drive_Backup`，**把唯一备份整盘删光**（这就是历史数据丢失的真因）。
现脚本两道保险：① 对每个通道三重判断（Z 在？源目录在？源目录**递归含至少一个文件**？任一不满足就跳过）；
② 备份用 `/E /XO`（**无 `/PURGE`**），从根上杜绝"删除/覆盖"类破坏——这是比旧 `/MIR` 更安全的设计。

### 出错怎么让你知道（健康告警）
每次运行写 `logs\STATUS.txt`（一行：时间 + OK/WARN/ERROR + 详情）：
- `ERROR`：等待后 Z 仍未出现，或旧通道备份目标不可用。
- `WARN`：Z 剩余空间不足、实际占用超过 8GB 缓存软上限、系统可用内存不足 8GB、
  提交余量不足 4GB，或运行态查询失败。
- 状态从 OK 变 WARN/ERROR 时，**弹一次 `msg` 弹窗**，并追加 `logs\alerts.log`。

> 你随时双击 `E:\Projects\Tools\RamdiskGuardian\logs\STATUS.txt` 就能看最新健康状态。

---

## 4. 目录结构约定

```
Z:\
  Caches\
    Personal\  ← 个人热缓存新入口
    Work\      ← 未来工作热缓存新入口（当前为空）
    ChromeCache\ / ChromeCodeCache\ / ChromeGPUCache\  ← 现有兼容路径
    360zip_temp\ / WeFlow\                            ← 现有兼容路径
  Scratch\
    Personal\
    Work\
  projects\ / docs\ / others\  ← 旧版保护通道，只兼容，不新增
  TEMP\                           ← 旧临时目录；不作为全局 TEMP/TMP
  .ramdisk_ready  ← 守护脚本的就绪标记（隐藏）
```

约定：`Caches/*` 和 `Scratch/*` 易失且不备份；`projects/docs/others` 只保留旧版备份兼容。
个人与工作目录只是组织边界，共享 RAM 盘和镜像不是安全边界。

---

## 5. 四个功能的状态

| 功能 | 状态 | 说明 |
|---|---|---|
| ① Chrome 缓存完整搬迁 | ✅ 正常 | `deploy.ps1` 将 `Cache`、`Code Cache` 和 `GPUCache` 链接至 Z，守护器补齐目标骨架。它可减少 C 盘缓存写入；是否改善实际加载体验需要按真实使用观察。 |
| ② 360 压缩缓存 | ✅ 正常 | `360zip_config.ini` 的 `ExtractTmpDir = Z:\Caches\360zip_temp`，目录已就绪。 |
| ③ 开发加速 | 候选制 | 只有真实工作负载证明受 I/O 限制时，IDE 索引或小型构建 scratch 才进入 Z。 |
| ④ 旧数据通道 | 兼容 | `projects/docs/others` 当前为空，继续安全备份/恢复但禁止新增正式内容。 |

---

## 6. 内存挤占会不会掉盘？（结论 + 对策）

**结论：内存挤占本身不会掉盘，最多临时写入报错；内存一恢复就自动正常。**

- 盘写满 32GB → 报"磁盘已满"、写入失败，但盘在、已有文件不丢。
- 别的程序吃光系统内存、盘要不到内存 → 这次写入失败报错，但盘和已有数据都在
  （已占内存是非分页、驱动锁定的）；内存松了写入恢复。
- 真正"掉盘+数据没"的是：**断电/蓝屏/硬重启**（→ 第③层开机自动从备份还原）、
  **没开机自启**（→ §1 已解决）。

**保持动态内存**意味着只占实际用量，但被缓存占用的内存不能同时服务模型、浏览器和开发工具。
本机约 64GB 内存，Z 新缓存总量以 8GB 为软上限；32GB 是容量上限，不是使用目标。不建议改成固定内存。

**"出错我要知道"**：已由 §3 的 STATUS / alerts / 弹窗实现。

---

## 7. Z 与 V 的开发分工

### 放 Z（小而热、完全可丢）

- 浏览器代码/GPU 缓存、IDE 索引、解压临时目录；
- 小型测试 scratch；
- 经一次真实构建对比证明有收益，且有体积上限的增量构建目录。

### 放 V（大、持续增长、需要跨重启）

- 新 Git 项目和 worktree；
- npm、pip、NuGet、Maven、Cargo、vcpkg 等包缓存；
- `node_modules`、大型编译输出和开发 scratch。

### 不迁入 Z/V

- 四大基座、现有路径绑定项目、模型、数据库、Docker/WSL 运行盘、正式备份和唯一事实资料。

不要凭理论跑分启用 Z 缓存；用真实项目的 Git、依赖恢复、测试或构建时间判断。没有可感知收益就保持原位。

---

## 8. 增强项与配置建议

- **Chrome 缓存完整搬到 Z (已实现 ✅)**：
  已完全集成到 `deploy.ps1` 中。自动创建 `Cache`、`Code Cache` 和 `GPUCache` 的 Junction 软链接。掉盘自愈脚本 `zguardian.ps1` 会在开机时自动建立对应的骨架文件夹，确保软链接永远不会因为掉盘而悬空。
- **镜像挪到数据盘 (已迁移 ✅)**：
  镜像文件已由脚本安全复制到 `E:\RamdiskImage\Z.vdf`。
  当前 live 文件确认该路径存在；不再把“复制完成”冒充 Primo 关联状态，实际关联仍以 Primo 和重启读回为准。
- **定时保存镜像 (不推荐 ❌)**：
  **建议保持关闭**。守护器每 15 分钟只为旧版 `projects/docs/others` 做追加式兼容备份；新缓存无需持久化。Primo 定时保存会把缓存写回 E，只有明确需要跨重启保留缓存且收益大于额外写入时才考虑开启。

---

## 9. 文件清单（本仓库）

```
RamdiskGuardian/
├─ README.md                      本文件（原理与运维）
├─ README.pdf                     本文件导出的 PDF（自动同步到 GitHub）
├─ DEPLOY.md                      快速部署指南（系统重装 / 换电脑）
├─ DEPLOY.pdf                     快速部署指南的 PDF（自动同步到 GitHub）
├─ deploy.ps1                     一键部署（关快速启动/建目录/注册任务/Chrome junction，幂等）
├─ zguardian.ps1                  守护脚本（缓存骨架 + 旧通道兼容 + 内存/空间健康告警）
├─ run_hidden.vbs                 隐藏窗口启动器（被计划任务调用，自定位）
├─ ramdrive.txt                   可选：非 Z 盘符时由 deploy.ps1 写入
├─ .gitignore                     忽略 logs/ 等运行时产物
├─ archive/
│   └─ sync_code.bat.bak_20260614 原始备份脚本（含危险 /MIR，仅留档）
├─ docs/
│   └─ primo_setup.png            Primo 界面标注图
└─ logs/                          运行时日志（不入库）
    ├─ guardian.log  ├─ STATUS.txt  ├─ alerts.log
```

相关但**不在本仓库**（留在原位，各有其任务/用途）：
- 旧版兼容备份目标：`E:\Backups\Z_Drive_Backup\{projects,docs,others}`；新缓存不进入备份。
- 桌面其他脚本：`auto_backup.ps1`(H 盘软件清单备份任务)、`检查运行状态.vbs` 等，与本项目无关，未动。

---

## 10. 运维速查

```powershell
# 手动跑一次守护（重建骨架/备份/还原）
powershell -NoProfile -ExecutionPolicy Bypass -File E:\Projects\Tools\RamdiskGuardian\zguardian.ps1

# 看健康状态 / 日志
Get-Content E:\Projects\Tools\RamdiskGuardian\logs\STATUS.txt
Get-Content E:\Projects\Tools\RamdiskGuardian\logs\guardian.log -Tail 20

# 看/改备份频率（计划任务）
Get-ScheduledTask RAMDisk_Code_Backup | % { $_.Triggers }

# 改容量/内存模式/镜像：在 Primo 里删盘重建（盘空时零风险），按 §1/§2 设置
```

---

## 11. 变更历史 & 已知数据丢失

- **2026-06-15**：
  - 升级 `build_docs_pdf.py` 支持指定工作目录与自动推送到 GitHub，生成并同步了本项目的 PDF 文档。
  - 优化并增强了 `deploy.ps1`，自动将 Chrome 的 `Cache`、`Code Cache` 与 `GPUCache` 完整迁移至 Z 盘，提升网页加载与渲染性能，并减少 C 盘 SSD 写入。
  - 增强 `zguardian.ps1` 将上述 Chrome 缓存目录加入自愈创建队列，彻底规避掉盘后启动悬空问题。
  - 将 Primo 内存盘镜像安全复制迁移至高可靠的数据分区 `E:\RamdiskImage\Z.vdf`，方便重装系统后一键挂载。
- **2026-06-14**：发现并修复掉盘问题；重写安全备份脚本；加开机自愈+健康告警；
  关闭 Windows 快速启动；盘从 20GB→32GB、加镜像持久化（非临时盘）。
- **已知丢失**：本次接手前，`Z:\projects/docs/others` 原始数据已丢失——旧 `/MIR` 脚本
  在更早一次掉盘时把 `E:\Backups\Z_Drive_Backup` 清空了，本地无其他副本。若那些是 git 工程，
  可从 GitHub 远端找回。
