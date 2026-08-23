# MemBar v2.1 — 菜单栏内存 + CPU 监控

常驻 macOS 顶部菜单栏，内存/CPU/Swap 三指标监控 + 主动告警。

## 菜单栏显示

```
[内存条] 内存 51%  [CPU条] CPU 16%  [SWAP 12.3G(超50%时橙色显示)]
```

- 内存条颜色（默认系统口径）：🟢 <60% / 🟡 60~85%（警告档，与系统"内存压力"图黄色统一） / 🔴 ≥85% 或剩余<3G
- **已用内存口径**（右键菜单可切换）：
  - **系统口径（同 memory_pressure，默认）**：已用 = Wired + 压缩，其余页（活跃/非活跃/可清除）视为可回收 → 与系统"内存压力"一致，不会因 VM/GPU 的大块 Wired 内存虚高
  - **活动监视器口径**：已用 = 活跃 + Wired + 压缩 → 在跑虚拟机/GPU 模型的机器上会明显偏高、频繁误报
- CPU 条颜色：🟢 <50% / 🟠 50~90% / 🔴 >90%
- Swap 警示：swap 用量 >50% 时橙色显示
- 文字颜色自动适配深浅色模式

## 交互

| 操作 | 行为 |
| :--- | :--- |
| 左键 | 打开系统活动监视器 |
| 右键 | 菜单（打开活动监视器 / 详细信息 / 内存监视开关 / CPU监视开关 / Swap警示开关 / **已用内存口径** / **回收压缩内存** / 退出） |

开关状态持久化，重启后记忆。

## 一键回收压缩内存

菜单 → **回收压缩内存**（快捷键 `Cmd+R`）：

1. 弹出管理员密码框，以 root 执行 `purge` + 手动触发内存压力回收（`sysctl kern.memorypressure_manual_trigger=1`）
2. 清空磁盘缓存并强制系统淘汰压缩内存页
3. 等待回收稳定后弹窗显示前后对比：`压缩内存: X GB → Y GB（释放 Z GB）`

> ⚠️ 说明：压缩内存是 macOS 的正常优化机制，系统会在需要时自动回收。此功能用于快速释放大量压缩内存、让活动监视器压力尽快降级；执行后压缩内存会随使用重新累积。长期降低内存压力请退出占用大的应用。

## 主动告警（P0）

内存进入红色区 **持续 15 秒**（可配置）后，发送系统横幅通知：
- 内容：剩余内存、占用率、Swap 用量
- 通知带"打开活动监视器"快捷按钮
- 恢复绿色前不重复轰炸

## 配置文件 ~/membar/config.json

修改后需重启 MemBar 生效：

```json
{
  "refreshIntervalSec": 2,        // 正常刷新间隔(秒)
  "redRefreshIntervalSec": 1,     // 红色区刷新间隔(秒，自动加速)
  "memBlueThreshold": 0.70,       // 活动监视器口径：内存黄阈值(键名兼容旧版)
  "memRedThreshold": 0.95,        // 活动监视器口径：内存红阈值
  "memRedFreeGB": 5,              // 活动监视器口径：剩余小于此值(GB)即红
  "usageMode": "system",          // 已用内存口径: "system"=同 memory_pressure / "app"=活动监视器
  "sysBlueThreshold": 0.60,       // 系统口径：黄阈值(键名兼容旧版)
  "sysRedThreshold": 0.85,        // 系统口径：红阈值
  "sysRedFreeGB": 3,              // 系统口径：剩余小于此值(GB)即红
  "cpuOrangeThreshold": 0.50,     // CPU 橙阈值
  "cpuRedThreshold": 0.90,        // CPU 红阈值
  "swapWarnThreshold": 0.50,      // Swap 警示阈值(占比)
  "alertEnabled": true,           // 是否允许告警通知
  "alertSustainSec": 15           // 红色持续多久后通知(秒)
}
```

## 日志

`~/membar/membar.log`（自动轮转，超过 1MB 重置）

## 构建 / 打包 / 安装

```bash
bash ~/membar/build.sh          # 编译 + 安装 + 启动
bash ~/membar/make_dist.sh      # 打包为可分发的 zip
bash ~/membar/make_icon.sh      # 重新生成图标
```

分发安装到其他 Mac：
```bash
unzip MemBar-v2.0.zip -d ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/MemBar.app   # 如被拦截
open ~/Applications/MemBar.app
```

## 开机自启

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Users/nantiange/Applications/MemBar.app", hidden:false}'
```

## 源码文件

- `main.swift` — 全部逻辑（~600 行）
- `Info.plist` / `build.sh` / `make_icon.sh` / `make_dist.sh`
- `icon_gen.swift` — 图标生成器
