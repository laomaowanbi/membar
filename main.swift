import Cocoa
import UserNotifications

// ============================================================
// MemBar v2.1 — 内存 + CPU 菜单栏监控（P0-P3 全量版）
// ============================================================

// MARK: - 配置文件

struct Config: Codable {
    var refreshIntervalSec: Double = 2      // 正常刷新间隔
    var redRefreshIntervalSec: Double = 1   // 红色告警区刷新间隔
    var memBlueThreshold: Double = 0.70     // 内存黄阈值(键名兼容旧配置)
    var memRedThreshold: Double = 0.95      // 内存红阈值
    var memRedFreeGB: Double = 5            // 剩余 < 此值(GB) 也触发红色
    var cpuOrangeThreshold: Double = 0.50   // CPU 橙阈值
    var cpuRedThreshold: Double = 0.90      // CPU 红阈值
    var swapWarnThreshold: Double = 0.50    // Swap 警示灯阈值(占比)
    var alertEnabled: Bool = true           // 是否允许系统通知
    var alertSustainSec: Double = 15        // 红色持续多少秒后通知
    var usageMode: String = "system"        // 已用内存口径: "system"=同 memory_pressure(已用=Wired+压缩) / "app"=活动监视器口径(活跃+Wired+压缩)
    var sysBlueThreshold: Double = 0.60     // 系统口径黄阈值(键名兼容旧配置)
    var sysRedThreshold: Double = 0.85      // 系统口径红阈值
    var sysRedFreeGB: Double = 3            // 系统口径: 剩余 < 此值(GB) 也触发红色
}

var cfg = Config()

func ensureDataDir() {
    let dir = NSHomeDirectory() + "/membar"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

func configPath() -> String {
    return NSHomeDirectory() + "/membar/config.json"
}

func loadConfig() {
    ensureDataDir()
    let path = configPath()
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let decoded = try? JSONDecoder().decode(Config.self, from: data) {
        cfg = decoded
        log("读取配置文件成功")
        return
    }
    // 不存在或解析失败 → 写默认配置
    if let d = try? JSONEncoder().encode(cfg) {
        try? d.write(to: URL(fileURLWithPath: path))
        log("已写入默认配置: \(path)")
    }
}

// MARK: - 日志

func log(_ msg: String) {
    let path = NSHomeDirectory() + "/membar/membar.log"
    let date = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
    let line = "[\(date)] \(msg)\n"
    // 超过 1MB 重置
    if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(atPath: path)
    }
    ensureDataDir()
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8) ?? Data())
        try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 内存统计

struct MemStats {
    var totalGB: Double = 0
    var usedGB: Double = 0
    var freeGB: Double = 0
    var wiredGB: Double = 0
    var compressedGB: Double = 0
    var activeGB: Double = 0
    var swapUsedGB: Double = 0
    var swapTotalGB: Double = 0
    var usage: Double = 0 // 0...1
}

func readMemStats() -> MemStats {
    var s = MemStats()

    var total: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &total, &size, nil, 0)
    s.totalGB = Double(total) / 1_073_741_824.0

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let page = Double(vm_kernel_page_size)
        let wiredPg = Double(stats.wire_count)
        let compPg = Double(stats.compressor_page_count)
        let activePg = Double(stats.active_count)

        s.wiredGB = wiredPg * page / 1_073_741_824.0
        s.compressedGB = compPg * page / 1_073_741_824.0
        s.activeGB = activePg * page / 1_073_741_824.0

        // 口径选择（与系统 memory_pressure 工具实测校准一致）：
        //   "system": 已用 = Wired + 压缩；其余页(活跃/非活跃/可清除)视为可回收 → 贴近系统真实压力
        //   "app"   : 已用 = 活跃 + Wired + 压缩 → 活动监视器口径(在 VM/GPU 大内存机器上明显偏高)
        let usedPg = cfg.usageMode == "system" ? wiredPg + compPg : activePg + wiredPg + compPg
        s.usedGB = usedPg * page / 1_073_741_824.0
        s.freeGB = max(s.totalGB - s.usedGB, 0)
        s.usage = min(max(s.usedGB / s.totalGB, 0), 1)
    }

    // 交换空间
    var xsw = xsw_usage()
    var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
    var xswSize = MemoryLayout<xsw_usage>.size
    if sysctl(&mib, 2, &xsw, &xswSize, nil, 0) == 0 {
        s.swapUsedGB = Double(xsw.xsu_used) / 1_073_741_824.0
        s.swapTotalGB = Double(xsw.xsu_total) / 1_073_741_824.0
    }
    return s
}

// MARK: - CPU 统计

var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

func readCPUUsage() -> Double {
    var cpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    var numCPUs: natural_t = 0
    let res = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
    guard res == KERN_SUCCESS, let info = cpuInfo else { return 0 }
    defer {
        let bytes = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
    }

    var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
    for i in 0..<Int(numCPUs) {
        let base = Int(CPU_STATE_MAX) * i
        user += UInt64(info[base + Int(CPU_STATE_USER)])
        system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
        idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
        nice += UInt64(info[base + Int(CPU_STATE_NICE)])
    }
    let total = user + system + idle + nice
    guard total > 0 else { return 0 }
    guard let last = lastCPUTicks else {
        lastCPUTicks = (user, system, idle, nice)
        return 0
    }
    let dTotal = total - (last.user + last.system + last.idle + last.nice)
    let dIdle = idle - last.idle
    lastCPUTicks = (user, system, idle, nice)
    if dTotal > 0 {
        return min(max(Double(dTotal - dIdle) / Double(dTotal), 0), 1)
    }
    return 0
}

// 前缀文字固定白色（深色/浅色菜单栏下均清晰可见）
func prefixTextColor() -> NSColor {
    return .white
}

// MARK: - 进度条渲染

func renderBarImage(stats: MemStats, cpuUsage: Double, swapRatio: Double,
                    memEnabled: Bool, cpuEnabled: Bool, swapEnabled: Bool,
                    scale: Int) -> NSImage {
    let height: CGFloat = 22
    // 三档比例：0=小(紧凑) 1=大(标准) 2=极大
    let profile: (barW: CGFloat, barH: CGFloat, font: NSFont)
    switch scale {
    case 2: profile = (62, 12, NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium))
    case 1: profile = (46, 10, NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium))
    default: profile = (22, 8, NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium))
    }
    let barW = profile.barW
    let barH = profile.barH
    let font = profile.font
    let textY = (height - font.pointSize * 1.4) / 2
    let y = (height - barH) / 2
    let prefixColor = prefixTextColor()

    let memLabel = "内存"
    let memNum = String(format: " %.0f%%", stats.usage * 100)
    let memW = (memLabel as NSString).size(withAttributes: [.font: font]).width
        + (memNum as NSString).size(withAttributes: [.font: font]).width
    let cpuLabel = "CPU"
    let cpuNum = String(format: " %.0f%%", cpuUsage * 100)
    let cpuW = (cpuLabel as NSString).size(withAttributes: [.font: font]).width
        + (cpuNum as NSString).size(withAttributes: [.font: font]).width
    let showSwap = swapEnabled && swapRatio > cfg.swapWarnThreshold
    let swapText = String(format: "SWAP %.1fG", stats.swapUsedGB)
    let swapW = (swapText as NSString).size(withAttributes: [.font: font]).width

    // 计算总宽（紧凑布局）
    var w: CGFloat = 3
    if memEnabled { w += barW + 3 + memW + 5 }
    if cpuEnabled { w += barW + 3 + cpuW + 5 }
    if showSwap { w += swapW + 5 }
    let totalW = max(w - 5 + 3, 20)

    let img = NSImage(size: NSSize(width: totalW, height: height))
    img.lockFocus()

    var x: CGFloat = 3
    if memEnabled {
        drawBar(x: x, y: y, w: barW, h: barH, usage: stats.usage, color: memoryColor(for: stats))
        x += barW + 3
        let ls = (memLabel as NSString).size(withAttributes: [.font: font]).width
        (memLabel as NSString).draw(at: NSPoint(x: x, y: textY),
                                    withAttributes: [.font: font, .foregroundColor: prefixColor])
        (memNum as NSString).draw(at: NSPoint(x: x + ls, y: textY),
                                  withAttributes: [.font: font, .foregroundColor: memoryColor(for: stats)])
        x += memW + 5
    }
    if cpuEnabled {
        drawBar(x: x, y: y, w: barW, h: barH, usage: cpuUsage, color: cpuBarColor(for: cpuUsage))
        x += barW + 3
        let ls = (cpuLabel as NSString).size(withAttributes: [.font: font]).width
        (cpuLabel as NSString).draw(at: NSPoint(x: x, y: textY),
                                    withAttributes: [.font: font, .foregroundColor: prefixColor])
        (cpuNum as NSString).draw(at: NSPoint(x: x + ls, y: textY),
                                  withAttributes: [.font: font, .foregroundColor: cpuBarColor(for: cpuUsage)])
        x += cpuW + 5
    }
    if showSwap {
        (swapText as NSString).draw(at: NSPoint(x: x, y: textY),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.systemOrange])
    }

    img.unlockFocus()
    return img
}

// 画一条进度条（轨道 + 彩色填充）
func drawBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, usage: Double, color: NSColor) {
    let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2)
    NSColor.labelColor.withAlphaComponent(0.18).setFill()
    track.fill()
    let fw = w * CGFloat(usage)
    if fw > 1.5 {
        let fill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fw, height: h), xRadius: h / 2, yRadius: h / 2)
        color.setFill()
        fill.fill()
    }
}

// 内存颜色：红色区红；警告区黄（与系统"内存压力"图的黄色档统一）；其余 绿
func memoryColor(for stats: MemStats) -> NSColor {
    switch memoryLevel(stats) {
    case 2: return .systemRed
    case 1: return .systemYellow
    default: return .systemGreen
    }
}

// 红色区迟滞（hysteresis）：已在红区时须回落到更低阈值才退出，
// 避免指标在阈值边界震荡（如占用 85%~90%）导致状态/日志反复抖动
let redHysteresisRate: Double = 0.03    // 占用率迟滞：如 85% 进红，<82% 才退出
let redHysteresisFree: Double = 1.0     // 剩余 GB 迟滞：如 <3GB 进红，≥4GB 才退出

// 上一次采样是否处于红色区（供迟滞判定）
var memInRed = false

// 内存级别：0=绿 1=黄(警告) 2=红。阈值随"已用内存口径"切换：
//   system: 同 memory_pressure（已用=Wired+压缩）
//   app   : 活动监视器口径（活跃+Wired+压缩）
func memoryLevel(_ s: MemStats) -> Int {
    let redRate = cfg.usageMode == "system" ? cfg.sysRedThreshold : cfg.memRedThreshold
    let redFree = cfg.usageMode == "system" ? cfg.sysRedFreeGB : cfg.memRedFreeGB
    let blueRate = cfg.usageMode == "system" ? cfg.sysBlueThreshold : cfg.memBlueThreshold
    // 进入红区：任一条件触发（OR）；已在红区：两条件都回落到迟滞线以下才退出（AND）
    let inRedNow = memInRed
        ? (s.freeGB < redFree + redHysteresisFree || s.usage >= redRate - redHysteresisRate)
        : (s.freeGB < redFree || s.usage >= redRate)
    if inRedNow { return 2 }
    if s.usage >= blueRate { return 1 }
    return 0
}

// CPU 颜色：>红 红；>橙 橙；其余 绿
func cpuBarColor(for usage: Double) -> NSColor {
    if usage > cfg.cpuRedThreshold { return .systemRed }
    if usage > cfg.cpuOrangeThreshold { return .systemOrange }
    return .systemGreen
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var detailMenu: NSMenu!
    var detailSubmenuItems: [NSMenuItem] = []
    var reclaimItem: NSMenuItem!

    var memOff: NSMenuItem!, memOn: NSMenuItem!
    var cpuOff: NSMenuItem!, cpuOn: NSMenuItem!
    var swapOff: NSMenuItem!, swapOn: NSMenuItem!
    var modeSys: NSMenuItem!, modeApp: NSMenuItem!
    var scaleSmall: NSMenuItem!, scaleLarge: NSMenuItem!, scaleXLarge: NSMenuItem!

    var memEnabled = true
    var cpuEnabled = true
    var swapEnabled = true
    var barScale = 0 // 0=小 1=大 2=极大

    var timer: Timer?
    var redSince: Date?
    var alertArmed = true

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfig()
        memEnabled = UserDefaults.standard.object(forKey: "memEnabled") as? Bool ?? true
        cpuEnabled = UserDefaults.standard.object(forKey: "cpuEnabled") as? Bool ?? true
        swapEnabled = UserDefaults.standard.object(forKey: "swapEnabled") as? Bool ?? true
        barScale = UserDefaults.standard.object(forKey: "scale") as? Int ?? 0
        if let m = UserDefaults.standard.string(forKey: "usageMode"), m == "system" || m == "app" {
            cfg.usageMode = m
        }

        NSApp.setActivationPolicy(.accessory)

        // 通知权限
        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        let openAction = UNNotificationAction(identifier: "OPEN_AM", title: "打开活动监视器", options: [.foreground])
        let cat = UNNotificationCategory(identifier: "MEM_ALERT", actions: [openAction], intentIdentifiers: [], options: [])
        nc.setNotificationCategories([cat])
        nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
            log("通知权限: \(granted ? "已授予" : "未授予") \(err.map { "\($0)" } ?? "")")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "左键：打开活动监视器 · 右键：菜单"

        // ---- 右键菜单 ----
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "MemBar 监控", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        menu.addItem(withTitle: "打开活动监视器", action: #selector(openActivityMonitor), keyEquivalent: "a")
        menu.addItem(.separator())

        // 详细信息子菜单（打开时刷新）
        let detailSub = NSMenu()
        let dLabels = ["总内存", "已使用", "剩余", "Wired", "压缩", "活跃", "交换空间", "进程 TOP"]
        for l in dLabels {
            let item = NSMenuItem(title: l, action: nil, keyEquivalent: "")
            item.isEnabled = false
            detailSub.addItem(item)
            detailSubmenuItems.append(item)
        }
        let detailItem = NSMenuItem(title: "详细信息", action: nil, keyEquivalent: "")
        detailItem.submenu = detailSub
        menu.addItem(detailItem)
        menu.addItem(.separator())

        // 内存监视（子菜单：关闭/打开）
        memOff = makeToggleItem(title: "关闭", on: false, action: #selector(toggleMem(_:)))
        memOn = makeToggleItem(title: "打开", on: true, action: #selector(toggleMem(_:)))
        let memItem = NSMenuItem(title: "内存监视", action: nil, keyEquivalent: "")
        let memSub = NSMenu(); memSub.addItem(memOff); memSub.addItem(memOn)
        memItem.submenu = memSub
        menu.addItem(memItem)

        // CPU 监视（子菜单：关闭/打开）
        cpuOff = makeToggleItem(title: "关闭", on: false, action: #selector(toggleCPU(_:)))
        cpuOn = makeToggleItem(title: "打开", on: true, action: #selector(toggleCPU(_:)))
        let cpuItem = NSMenuItem(title: "CPU监视", action: nil, keyEquivalent: "")
        let cpuSub = NSMenu(); cpuSub.addItem(cpuOff); cpuSub.addItem(cpuOn)
        cpuItem.submenu = cpuSub
        menu.addItem(cpuItem)

        // Swap 警示（子菜单：关闭/打开）
        swapOff = makeToggleItem(title: "关闭", on: false, action: #selector(toggleSwap(_:)))
        swapOn = makeToggleItem(title: "打开", on: true, action: #selector(toggleSwap(_:)))
        let swapItem = NSMenuItem(title: "Swap警示", action: nil, keyEquivalent: "")
        let swapSub = NSMenu(); swapSub.addItem(swapOff); swapSub.addItem(swapOn)
        swapItem.submenu = swapSub
        menu.addItem(swapItem)

        // 已用内存口径（子菜单：系统口径 / 活动监视器口径）
        modeSys = makeToggleItem(title: "系统口径（同 memory_pressure）", on: true, action: #selector(toggleMode(_:)))
        modeApp = makeToggleItem(title: "活动监视器口径", on: false, action: #selector(toggleMode(_:)))
        let modeItem = NSMenuItem(title: "已用内存口径", action: nil, keyEquivalent: "")
        let modeSub = NSMenu(); modeSub.addItem(modeSys); modeSub.addItem(modeApp)
        modeItem.submenu = modeSub
        menu.addItem(modeItem)

        // 显示比例（子菜单：小/大/极大）
        scaleSmall = makeIntItem(title: "小", value: 0, action: #selector(setScale(_:)))
        scaleLarge = makeIntItem(title: "大", value: 1, action: #selector(setScale(_:)))
        scaleXLarge = makeIntItem(title: "极大", value: 2, action: #selector(setScale(_:)))
        let scaleItem = NSMenuItem(title: "显示比例", action: nil, keyEquivalent: "")
        let scaleSub = NSMenu()
        scaleSub.addItem(scaleSmall)
        scaleSub.addItem(scaleLarge)
        scaleSub.addItem(scaleXLarge)
        scaleItem.submenu = scaleSub
        menu.addItem(scaleItem)

        menu.addItem(.separator())
        // 一键回收压缩内存（触发系统内存压力回收，无需 root）
        reclaimItem = NSMenuItem(title: "回收压缩内存", action: #selector(reclaimCompressedMemory), keyEquivalent: "r")
        reclaimItem.target = self
        menu.addItem(reclaimItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MemBar", action: #selector(quitApp), keyEquivalent: "q")

        updateMenuStates()

        // 左键：打开活动监视器；右键：手动弹出菜单
        detailMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        refresh()
        reschedule(cfg.refreshIntervalSec)
        log("MemBar 启动完成")
    }

    func makeToggleItem(title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = on
        return item
    }

    func makeIntItem(title: String, value: Int, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    func reschedule(_ interval: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 刷新与告警

    @objc func refresh() {
        let s = readMemStats()
        let cpu = readCPUUsage()
        let swapRatio = s.swapTotalGB > 0 ? s.swapUsedGB / s.swapTotalGB : 0
        let level = memoryLevel(s)

        statusItem.button?.image = renderBarImage(stats: s, cpuUsage: cpu, swapRatio: swapRatio,
                                                  memEnabled: memEnabled, cpuEnabled: cpuEnabled,
                                                  swapEnabled: swapEnabled, scale: barScale)

        // 告警状态机
        if level >= 2 {
            if redSince == nil {
                redSince = Date()
                log("⚠️ 进入红色区: 剩余 \(String(format: "%.1f", s.freeGB))GB · 占用 \(Int(s.usage * 100))%")
            }
            if alertArmed && cfg.alertEnabled,
               let rs = redSince,
               Date().timeIntervalSince(rs) >= cfg.alertSustainSec {
                sendMemoryAlert(s)
                alertArmed = false
            }
        } else {
            if memInRed {
                log("✅ 离开红色区: 剩余 \(String(format: "%.1f", s.freeGB))GB · 占用 \(Int(s.usage * 100))%")
            }
            redSince = nil
            if level == 0 { alertArmed = true }
        }
        memInRed = (level >= 2)

        // 自适应刷新间隔：红色区加快
        let interval = level >= 2 ? cfg.redRefreshIntervalSec : cfg.refreshIntervalSec
        if let t = timer, abs(t.timeInterval - interval) > 0.01 {
            reschedule(interval)
        }
    }

    func sendMemoryAlert(_ s: MemStats) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ 内存告警"
        content.body = String(format: "剩余 %.1f GB · 占用 %.0f%%\nSwap %.1f / %.1f GB",
                              s.freeGB, s.usage * 100, s.swapUsedGB, s.swapTotalGB)
        content.sound = .default
        content.categoryIdentifier = "MEM_ALERT"
        let req = UNNotificationRequest(
            identifier: "mem-alert-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { log("通知发送失败: \(err.localizedDescription)") }
            else { log("已发送内存告警通知") }
        }
    }

    // MARK: 菜单动作

    @objc func toggleMem(_ sender: NSMenuItem) {
        memEnabled = (sender.representedObject as? Bool) ?? memEnabled
        UserDefaults.standard.set(memEnabled, forKey: "memEnabled")
        updateMenuStates()
    }

    @objc func toggleCPU(_ sender: NSMenuItem) {
        cpuEnabled = (sender.representedObject as? Bool) ?? cpuEnabled
        UserDefaults.standard.set(cpuEnabled, forKey: "cpuEnabled")
        updateMenuStates()
    }

    @objc func toggleSwap(_ sender: NSMenuItem) {
        swapEnabled = (sender.representedObject as? Bool) ?? swapEnabled
        UserDefaults.standard.set(swapEnabled, forKey: "swapEnabled")
        updateMenuStates()
    }

    @objc func toggleMode(_ sender: NSMenuItem) {
        cfg.usageMode = (sender.representedObject as? Bool) == true ? "system" : "app"
        UserDefaults.standard.set(cfg.usageMode, forKey: "usageMode")
        updateMenuStates()
        refresh()
    }

    @objc func setScale(_ sender: NSMenuItem) {
        barScale = (sender.representedObject as? Int) ?? 0
        UserDefaults.standard.set(barScale, forKey: "scale")
        updateMenuStates()
        refresh()
    }

    func updateMenuStates() {
        memOff.state = memEnabled ? .off : .on
        memOn.state = memEnabled ? .on : .off
        cpuOff.state = cpuEnabled ? .off : .on
        cpuOn.state = cpuEnabled ? .on : .off
        swapOff.state = swapEnabled ? .off : .on
        swapOn.state = swapEnabled ? .on : .off
        modeSys.state = cfg.usageMode == "system" ? .on : .off
        modeApp.state = cfg.usageMode == "app" ? .on : .off
        scaleSmall.state = barScale == 0 ? .on : .off
        scaleLarge.state = barScale == 1 ? .on : .off
        scaleXLarge.state = barScale == 2 ? .on : .off
    }

    @objc func quitApp() {
        log("退出 MemBar")
        NSApp.terminate(nil)
    }

    // 一键回收压缩内存：以管理员权限执行 purge + 手动触发内存压力回收
    @objc func reclaimCompressedMemory() {
        let before = readMemStats().compressedGB
        log(String(format: "开始回收内存（需输入管理员密码），回收前压缩: %.1f GB", before))

        DispatchQueue.global().async {
            // purge: 清空磁盘缓存；memorypressure_manual_trigger: 强制触发一次内存压力回收
            let script = "do shell script \"purge; sysctl kern.memorypressure_manual_trigger=1\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                log("回收执行失败: \(error.localizedDescription)")
                return
            }
            if p.terminationStatus != 0 {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log("回收被取消或失败: \(err)")
                return
            }
            log("purge + 压力回收已执行，等待系统回收完成...")

            // 后台轮询：等待压缩内存下降并连续 3 次稳定（最多 45 秒）
            var last = before
            var stable = 0
            for _ in 0..<45 {
                Thread.sleep(forTimeInterval: 1)
                let cur = readMemStats().compressedGB
                if abs(cur - last) < 0.1 { stable += 1 } else { stable = 0 }
                last = cur
                if stable >= 3 { break }
            }
            let after = readMemStats().compressedGB
            let freed = max(before - after, 0)
            let msg = String(format: "压缩内存: %.1f GB → %.1f GB（释放 %.1f GB）", before, after, freed)
            log(msg)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "内存回收完成"
                alert.informativeText = msg
                alert.runModal()
            }
        }
    }

    @objc func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error { log("打开活动监视器失败: \(error.localizedDescription)") }
        }
    }

    // 区分左键/右键：左键开活动监视器，右键弹详情菜单
    @objc func handleClick() {
        guard let ev = NSApp.currentEvent else {
            openActivityMonitor()
            return
        }
        let isRight = ev.type == .rightMouseUp ||
            (ev.type == .leftMouseUp && ev.modifierFlags.contains(.control))
        if isRight {
            if let b = statusItem.button {
                detailMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: b)
            }
        } else {
            openActivityMonitor()
        }
    }

    // 打开菜单时刷新详细信息
    func menuWillOpen(_ menu: NSMenu) {
        let s = readMemStats()
        let fmt = { (v: Double) -> String in String(format: "%.1f GB", v) }
        let cpu = readCPUUsage()
        reclaimItem?.title = String(format: "回收压缩内存（当前压缩 %.1f GB）", s.compressedGB)

        let lines = [
            "总内存:   \(fmt(s.totalGB))",
            "已使用:   \(fmt(s.usedGB))（\(Int(s.usage * 100))%，\(cfg.usageMode == "system" ? "系统口径" : "活动监视器口径")）",
            "剩余:     \(fmt(s.freeGB))",
            "Wired:    \(fmt(s.wiredGB))",
            "压缩:     \(fmt(s.compressedGB))",
            "活跃:     \(fmt(s.activeGB))",
            "交换空间: \(fmt(s.swapUsedGB)) / \(fmt(s.swapTotalGB))",
            "CPU 占用: \(Int(cpu * 100))%",
            "进程 TOP: \(topCPUProcessLine())"
        ]
        for (i, item) in detailSubmenuItems.enumerated() where i < lines.count {
            item.title = lines[i]
        }
    }

    func topCPUProcessLine() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pcpu,comm", "-r"]
        p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "—"
        }
        guard let data = (p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
              let s = String(data: data, encoding: .utf8) else {
            return "—"
        }
        let lines = s.split(separator: "\n")
        guard lines.count >= 2 else { return "—" }
        let parts = lines[1].split(whereSeparator: { $0 == " " }).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return "—" }
        let raw = String(parts[1])
        let name = raw.split(separator: "/").last ?? Substring(raw)
        return "\(String(name).prefix(24)) \(parts[0])%"
    }

    // MARK: 通知代理

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "OPEN_AM" {
            openActivityMonitor()
        }
        completionHandler()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
