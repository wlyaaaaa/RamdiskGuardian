# RamdiskGuardian 项目规则

- 这是 cache-only RAMDisk 守护，不恢复退役的源码/文档备份通道。唯一资料放在持久存储；机器政策引用 PCConfig 的 `docs/governance/dev_storage_policy.md`，不要复制第二份机器权威。
- 使用 PowerShell 7，兼容任务名保留。默认诊断和部署预检不写入；部署、电源和 Chrome 缓存变更分别显式选择，不扩大任务恢复范围。
- 写盘前验证配置盘符、卷标及 Primo 唯一实际编号；重建前复核身份。关键写入必须报错并回读，ERROR 非零退出，不以日志或任务完成冒充健康。
- 自动重建遵循持续样本、消费者租约、暂停和冷却。不得把合作式租约宣传为所有旧应用均受保护；不初始化真实磁盘来运行测试。
- 健康快照、恢复状态与控制 JSON 同目录原子写入；日志有界。退出码、健康、部署、真实恢复、自然重启与 Git 发布分别验收。
- 测试至少覆盖 Static、Recovery 和 Reliability 三套脚本及 AST/git diff --check；所有假磁盘和假原生命令留在任务专属 TEMP，结束清理。