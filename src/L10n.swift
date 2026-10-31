import Foundation

// MARK: - Language
// Follows the same "static current value set at the top of each root view body"
// pattern as `Theme.mode`, so switching language re-renders every view that
// observes `ConfigStore` (config change → body re-runs → L.t reads new strings).
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, zhHans, en, zhHant, ja
    var id: String { rawValue }

    /// Native display name for the picker (self-describing, never translated).
    var displayName: String {
        switch self {
        case .system: return L.t("lang.system")
        case .zhHans: return "简体中文"
        case .en:     return "English"
        case .zhHant: return "繁體中文"
        case .ja:     return "日本語"
        }
    }

    /// Concrete language used for lookup; `.system` resolves via the OS preference.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        for p in Locale.preferredLanguages {
            let l = p.lowercased()
            if l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo") { return .zhHant }
            if l.hasPrefix("zh") { return .zhHans }
            if l.hasPrefix("ja") { return .ja }
            if l.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// For locale-formatted names (e.g. weekday symbols) in the app's language.
    var localeIdentifier: String {
        switch resolved {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ja:     return "ja"
        default:      return "en"
        }
    }
}

// MARK: - String table
enum L {
    static var lang: AppLanguage = .system

    static func t(_ key: String) -> String {
        guard let s = table[key] else { return key }
        switch lang.resolved {
        case .zhHans: return s.zhHans
        case .zhHant: return s.zhHant
        case .ja:     return s.ja
        case .en, .system: return s.en
        }
    }
    /// Formatted variant, e.g. L.f("a.currentVersion", "1.0.0").
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    private struct S { let zhHans, en, zhHant, ja: String }
    private static let table: [String: S] = [
        "network.showDetails": S(zhHans: "展开网络详情", en: "Show network details", zhHant: "展開網路詳細資訊", ja: "ネットワークの詳細を表示"),
        "network.hideDetails": S(zhHans: "收起网络详情", en: "Hide network details", zhHant: "收合網路詳細資訊", ja: "ネットワークの詳細を閉じる"),
        "network.lastHour": S(zhHans: "最近 1 小时", en: "Last hour", zhHant: "最近 1 小時", ja: "過去1時間"),
        "refresh.title": S(zhHans: "采样与能耗", en: "Sampling & energy", zhHant: "取樣與耗能", ja: "サンプリングと省電力"),
        "refresh.mode": S(zhHans: "后台刷新", en: "Background refresh", zhHant: "背景重新整理", ja: "バックグラウンド更新"),
        "refresh.responsive": S(zhHans: "快速", en: "Fast", zhHant: "快速", ja: "高速"),
        "refresh.balanced": S(zhHans: "默认", en: "Default", zhHant: "預設", ja: "標準"),
        "refresh.economical": S(zhHans: "省电", en: "Eco", zhHant: "省電", ja: "省電力"),
        "refresh.body": S(zhHans: "后台温度 / 网络 / 进程间隔：快速 3 / 1 / 5 秒，默认 10 / 3 / 10 秒，省电 30 / 10 / 30 秒。打开面板使用默认频率；后台低电量模式使用省电。曲线保护独立采样，历史显示不会加速。", en: "Background temperature / network / process intervals: Fast 3 / 1 / 5s, Default 10 / 3 / 10s, Eco 30 / 10 / 30s. Open panels use Default; background Low Power Mode uses Eco. Curve safety samples independently without speeding up history updates.", zhHant: "背景溫度 / 網路 / 程序間隔：快速 3 / 1 / 5 秒，預設 10 / 3 / 10 秒，省電 30 / 10 / 30 秒。開啟面板使用預設頻率；背景低耗電模式使用省電。曲線保護獨立取樣，歷史顯示不會加速。", ja: "バックグラウンドの温度 / 通信 / プロセス間隔：高速 3 / 1 / 5秒、標準 10 / 3 / 10秒、省電力 30 / 10 / 30秒。パネル表示中は標準、バックグラウンドの低電力モードは省電力を使用します。カーブ保護は表示更新とは独立して測定します。"),
        "control.failed": S(zhHans: "控制指令失败，已停止本次指令并请求系统接管。", en: "Control failed; the command was stopped and automatic control requested.", zhHant: "控制指令失敗，已停止本次指令並請求系統接管。", ja: "制御に失敗しました。コマンドを中止し、自動制御を要求しました。"),
        "control.installFailed": S(zhHans: "控制服务安装或移除未完成，请重试。", en: "Control service setup did not complete. Please retry.", zhHant: "控制服務安裝或移除未完成，請重試。", ja: "制御サービスの設定が完了しませんでした。再試行してください。"),
        "control.sensorPaused": S(zhHans: "温度过期或风扇范围无效，曲线控制已暂停并请求系统接管。", en: "Temperature is stale or fan limits are invalid. Control is paused and automatic control requested.", zhHant: "溫度過期或風扇範圍無效，曲線控制已暫停並請求系統接管。", ja: "温度が古いかファン範囲が無効です。制御を一時停止し自動制御を要求しました。"),
        "control.update": S(zhHans: "更新风扇控制服务", en: "Update fan-control service", zhHant: "更新風扇控制服務", ja: "ファン制御サービスを更新"),
        "control.updateShort": S(zhHans: "更新服务", en: "Update service", zhHant: "更新服務", ja: "サービスを更新"),
        "control.updateBody": S(zhHans: "服务仍为旧版。更新后可启用最新的安全与防护机制，需要管理员授权。", en: "The installed service is older. Update it for the latest safety and security protections; administrator authorization is required.", zhHant: "服務仍為舊版。更新後可啟用最新的安全與防護機制，需要管理員授權。", ja: "インストール済みサービスは旧版です。最新の安全・セキュリティ保護には更新と管理者認証が必要です。"),
        "network.warmingUp": S(zhHans: "正在采集进程速率…", en: "Collecting process rates…", zhHant: "正在收集程序速率…", ja: "プロセス通信速度を収集中…"),
        "network.unavailable": S(zhHans: "进程速率暂不可用，重新展开后重试。", en: "Process rates unavailable. Collapse and expand to retry.", zhHant: "程序速率暫時無法使用，重新展開後重試。", ja: "プロセス通信速度を取得できません。閉じてから再度開いてください。"),
        "toggle.on": S(zhHans: "已开启", en: "On", zhHant: "已開啟", ja: "オン"),
        "toggle.off": S(zhHans: "已关闭", en: "Off", zhHant: "已關閉", ja: "オフ"),
        "resource.cpuHelp": S(zhHans: "整机 CPU 使用率：采样期间所有核心的非空闲时间占比，100% 表示全部核心满负载。", en: "System CPU usage: non-idle time across all cores over the sampling interval. 100% means all cores are fully busy.", zhHant: "整機 CPU 使用率：取樣期間所有核心的非閒置時間佔比，100% 表示全部核心滿載。", ja: "システム CPU 使用率。サンプリング間隔における全コアの非アイドル時間の割合で、100% は全コアのフル稼働を示します。"),
        "resource.memory": S(zhHans: "内存", en: "Memory", zhHant: "記憶體", ja: "メモリ"),
        "resource.disk": S(zhHans: "启动盘", en: "Startup disk", zhHant: "啟動磁碟", ja: "起動ディスク"),
        "resource.loading": S(zhHans: "采集中…", en: "Loading…", zhHant: "取樣中…", ja: "取得中…"),
        "resource.unavailable": S(zhHans: "不可用", en: "Unavailable", zhHant: "無法取得", ja: "取得不可"),
        "resource.memoryHelp": S(zhHans: "系统已用 / 总物理内存（GiB）。含应用、联动和压缩内存，排除可回收文件缓存；不是内存压力。", en: "Used / total physical memory (GiB). Includes anonymous, wired and compressed memory, excluding reclaimable file cache. This is usage, not memory pressure.", zhHant: "系統已用 / 總物理記憶體（GiB）。含應用程式、固定與壓縮記憶體，排除可回收檔案快取；不是記憶體壓力。", ja: "使用済み / 物理メモリ合計（GiB）。アプリ、固定、圧縮メモリを含み、回収可能なファイルキャッシュを除きます。メモリプレッシャーとは異なります。"),
        "resource.diskHelp": S(zhHans: "启动盘已用 / 总容量（GB），按总容量减可用空间计算，不重复累加共享 APFS 卷，不含可清理空间估算。", en: "Startup disk used / total capacity (GB): total minus free space, without double-counting shared APFS volumes or estimating purgeable space.", zhHant: "啟動磁碟已用 / 總容量（GB），以總容量減可用空間計算，不重複累加共享 APFS 卷，不含可清除空間估算。", ja: "起動ディスク使用済み / 合計（GB）。空き容量を差し引き、共有 APFS ボリュームの重複や消去可能容量の推定は含みません。"),
        "resource.gpuHelp": S(zhHans: "GPU 驱动报告的设备使用率；不支持的设备或无法读取时显示不可用，不需要管理员权限。", en: "Device utilization reported by the GPU driver. Unsupported or unreadable counters show Unavailable. No administrator access required.", zhHant: "GPU 驅動程式回報的裝置使用率；不支援或無法讀取時顯示無法取得，無需管理員權限。", ja: "GPU ドライバのデバイス使用率。非対応または取得不能時は取得不可と表示します。管理者権限は不要です。"),
        // Language
        "lang.system": S(zhHans: "跟随系统", en: "System", zhHant: "跟隨系統", ja: "システムに従う"),

        // Settings window
        "settings.window": S(zhHans: "OmniStats 设置", en: "OmniStats Settings", zhHant: "OmniStats 設定", ja: "OmniStats 設定"),

        // Settings sections
        "section.fans":    S(zhHans: "风扇", en: "Fans",    zhHant: "風扇", ja: "ファン"),
        "section.battery": S(zhHans: "电池", en: "Battery", zhHant: "電池", ja: "バッテリー"),
        "section.menuBar": S(zhHans: "菜单栏图标", en: "Menu Bar Icons", zhHant: "選單列圖示", ja: "メニューバーアイコン"),
        "section.apps": S(zhHans: "应用卸载", en: "Uninstall Apps", zhHant: "應用程式解除安裝", ja: "アプリのアンインストール"),
        "section.general": S(zhHans: "通用", en: "General", zhHant: "通用", ja: "一般"),
        "section.about":   S(zhHans: "关于", en: "About",   zhHant: "關於", ja: "情報"),

        // Fan modes
        "fanmode.auto":   S(zhHans: "自动", en: "Auto",   zhHant: "自動", ja: "自動"),
        "fanmode.manual": S(zhHans: "手动", en: "Manual", zhHant: "手動", ja: "手動"),
        "fanmode.curve":  S(zhHans: "曲线", en: "Curve",  zhHant: "曲線", ja: "カーブ"),

        // Appearance
        "appearance.dark":  S(zhHans: "深色", en: "Dark",  zhHant: "深色", ja: "ダーク"),
        "appearance.light": S(zhHans: "浅色", en: "Light", zhHant: "淺色", ja: "ライト"),

        // Menu panel + menu bar
        "m.socAvg":   S(zhHans: "SoC 平均", en: "SoC avg", zhHant: "SoC 平均", ja: "SoC 平均"),
        "m.battery":  S(zhHans: "电池温度", en: "Battery temp", zhHant: "電池溫度", ja: "バッテリー温度"),
        "m.batteryCharge": S(zhHans: "电池", en: "Battery", zhHant: "電池", ja: "バッテリー"),
        "m.flowHelp": S(zhHans: "电源输入 · 系统功耗 · 电池(正为充电,负为放电)", en: "Adapter input · system load · battery (+ charging, − discharging)", zhHant: "電源輸入 · 系統功耗 · 電池(正為充電,負為放電)", ja: "アダプタ入力 · システム消費 · バッテリー(+ 充電 / − 放電)"),
        "m.power":    S(zhHans: "总功耗", en: "Power", zhHant: "總功耗", ja: "消費電力"),
        "m.voltage":  S(zhHans: "电压", en: "Voltage", zhHant: "電壓", ja: "電圧"),
        "m.fanLeft":  S(zhHans: "左风扇", en: "Left fan", zhHant: "左風扇", ja: "左ファン"),
        "m.fanRight": S(zhHans: "右风扇", en: "Right fan", zhHant: "右風扇", ja: "右ファン"),
        "m.fanN":     S(zhHans: "风扇%d", en: "Fan %d", zhHant: "風扇%d", ja: "ファン%d"),
        "m.enableControl": S(zhHans: "启用风扇控制…", en: "Enable fan control…", zhHant: "啟用風扇控制…", ja: "ファン制御を有効化…"),
        "m.enabling": S(zhHans: "正在启用…", en: "Enabling…", zhHant: "正在啟用…", ja: "有効化中…"),
        "m.settings": S(zhHans: "设置…", en: "Settings…", zhHant: "設定…", ja: "設定…"),
        "m.mode":     S(zhHans: "模式", en: "Mode", zhHant: "模式", ja: "モード"),
        "m.quit":     S(zhHans: "退出", en: "Quit", zhHant: "結束", ja: "終了"),
        "m.network":  S(zhHans: "网络", en: "Network", zhHant: "網路", ja: "ネットワーク"),
        "m.procHeader": S(zhHans: "CPU 占用最高", en: "Top CPU", zhHant: "CPU 佔用最高", ja: "CPU 使用率トップ"),
        "m.idle":     S(zhHans: "空闲", en: "Idle", zhHant: "閒置", ja: "アイドル"),
        "m.netProcHeader": S(zhHans: "网速占用最高", en: "Top network", zhHant: "網速佔用最高", ja: "通信量トップ"),
        "m.netIdle":  S(zhHans: "暂无网络活动", en: "No traffic", zhHant: "暫無網路活動", ja: "通信なし"),

        // Charts / visualization
        "chart.style.ring": S(zhHans: "环状", en: "Ring", zhHant: "環狀", ja: "リング"),
        "chart.style.line": S(zhHans: "折线", en: "Line", zhHant: "折線", ja: "折れ線"),
        "chart.style.bars": S(zhHans: "柱状", en: "Bars", zhHant: "柱狀", ja: "バー"),
        "chart.win.5m":     S(zhHans: "5 分钟", en: "5 min", zhHant: "5 分鐘", ja: "5 分"),
        "chart.win.30m":    S(zhHans: "30 分钟", en: "30 min", zhHant: "30 分鐘", ja: "30 分"),
        "chart.win.1h":     S(zhHans: "1 小时", en: "1 hour", zhHant: "1 小時", ja: "1 時間"),

        // Fans pane
        "f.title":    S(zhHans: "风扇控制", en: "Fan control", zhHant: "風扇控制", ja: "ファン制御"),
        "f.subtitle": S(zhHans: "温度驱动的转速策略 · 渐进调速,不伤硬件",
                        en: "Temperature-driven speed policy · gradual ramping, hardware-friendly",
                        zhHant: "溫度驅動的轉速策略 · 漸進調速,不傷硬件",
                        ja: "温度連動の回転制御 · 緩やかに変化しハードに優しい"),
        "f.noFan.title": S(zhHans: "本机没有风扇", en: "No fans on this Mac", zhHant: "本機沒有風扇", ja: "このMacにファンはありません"),
        "f.noFan.body":  S(zhHans: "如 MacBook Air 采用无风扇被动散热,仅提供温度监控。",
                           en: "Fanless Macs (e.g. MacBook Air) use passive cooling — temperature monitoring only.",
                           zhHant: "如 MacBook Air 採用無風扇被動散熱,僅提供溫度監控。",
                           ja: "MacBook Air などファンレス機は温度監視のみ対応します。"),
        "f.autoTitle": S(zhHans: "固件自动控制", en: "Firmware auto control", zhHant: "韌體自動控制", ja: "ファームウェア自動制御"),
        "f.autoBody":  S(zhHans: "交回 macOS 固件的散热策略,风扇随负载与温度自动调节。切到「手动」或「曲线」即可接管。",
                         en: "Hands control back to macOS firmware — fans track load and temperature automatically. Switch to Manual or Curve to take over.",
                         zhHant: "交回 macOS 韌體的散熱策略,風扇隨負載與溫度自動調節。切到「手動」或「曲線」即可接管。",
                         ja: "macOS ファームウェアに制御を委ね、負荷と温度に応じてファンが自動調整されます。手動 / カーブに切り替えると引き継げます。"),
        "f.manualTitle": S(zhHans: "固定转速", en: "Fixed speed", zhHant: "固定轉速", ja: "固定回転数"),
        "f.manualBody":  S(zhHans: "按各风扇量程的百分比换算,自动适配左右风扇不同上限。",
                           en: "Percent of each fan's range — left/right upper limits handled automatically.",
                           zhHant: "按各風扇量程的百分比換算,自動適配左右風扇不同上限。",
                           ja: "各ファンの可動域に対する割合。左右で異なる上限も自動対応します。"),
        "f.preset":         S(zhHans: "预设", en: "Presets", zhHant: "預設", ja: "プリセット"),
        "f.presetQuiet":    S(zhHans: "静音", en: "Quiet", zhHant: "靜音", ja: "静音"),
        "f.presetBalanced": S(zhHans: "均衡", en: "Balanced", zhHant: "均衡", ja: "バランス"),
        "f.presetCool":     S(zhHans: "高性能", en: "Cooler", zhHant: "高效能", ja: "冷却重視"),
        "f.dragHint":       S(zhHans: "拖拽控制点微调", en: "Drag points to fine-tune", zhHant: "拖曳控制點微調", ja: "点をドラッグして微調整"),
        "f.drivingTemp":    S(zhHans: "驱动温度 %1$@ → 目标转速 %2$d%%",
                              en: "Driving %1$@ → target %2$d%%",
                              zhHant: "驅動溫度 %1$@ → 目標轉速 %2$d%%",
                              ja: "駆動温度 %1$@ → 目標回転 %2$d%%"),
        "f.operatingHint":  S(zhHans: "光点=当前工作点", en: "Dot = live operating point", zhHant: "光點=目前工作點", ja: "光点=現在の動作点"),
        "f.advanced":       S(zhHans: "高级配置", en: "Advanced", zhHant: "進階設定", ja: "詳細設定"),
        "f.rampUp":         S(zhHans: "升速", en: "Ramp up", zhHant: "升速", ja: "上昇"),
        "f.rampDown":       S(zhHans: "降速", en: "Ramp down", zhHant: "降速", ja: "下降"),
        "f.deadband":       S(zhHans: "抖动抑制", en: "Deadband", zhHant: "抖動抑制", ja: "デッドバンド"),
        "f.advancedBody":   S(zhHans: "温度已平滑过滤尖峰;目标变化小于「抖动抑制」不调整;升/降速限制每秒最大变化,渐进不瞬跳。",
                              en: "Temperature is smoothed against spikes; changes below the deadband are ignored; ramp limits cap the per-second change so fans never jump.",
                              zhHant: "溫度已平滑過濾尖峰;目標變化小於「抖動抑制」不調整;升/降速限制每秒最大變化,漸進不瞬跳。",
                              ja: "温度はスパイクを平滑化。デッドバンド未満の変化は無視し、上昇/下降速度で毎秒の変化量を制限して急変を防ぎます。"),
        "f.restoreDefaults": S(zhHans: "还原推荐默认", en: "Restore defaults", zhHant: "還原建議預設", ja: "推奨値に戻す"),
        "f.defaultsSummary": S(zhHans: "已使用推荐默认值 · 升速 %1$d / 降速 %2$d / 抖动 %3$d",
                               en: "Using recommended defaults · up %1$d / down %2$d / deadband %3$d",
                               zhHant: "已使用建議預設值 · 升速 %1$d / 降速 %2$d / 抖動 %3$d",
                               ja: "推奨値を使用中 · 上昇 %1$d / 下降 %2$d / デッドバンド %3$d"),
        "f.liveRpm":         S(zhHans: "实时转速", en: "Live RPM", zhHant: "即時轉速", ja: "リアルタイム回転数"),
        "f.enableBannerTitle": S(zhHans: "风扇控制未启用", en: "Fan control not enabled", zhHant: "風扇控制未啟用", ja: "ファン制御は未有効"),
        "f.enableBannerBody":  S(zhHans: "可先设计曲线;点击授权一次安装 root 助手后即生效。",
                                 en: "Design the curve now; one authorization installs the root helper and it takes effect.",
                                 zhHant: "可先設計曲線;點擊授權一次安裝 root 助手後即生效。",
                                 ja: "先にカーブを設計できます。一度だけ認証して root ヘルパーを入れると有効になります。"),
        "f.enableShort":     S(zhHans: "启用…", en: "Enable…", zhHant: "啟用…", ja: "有効化…"),

        // General pane
        "g.title":       S(zhHans: "通用", en: "General", zhHant: "通用", ja: "一般"),
        "g.subtitle":    S(zhHans: "显示、语言与配色", en: "Display, language & colors", zhHant: "顯示、語言與配色", ja: "表示・言語・配色"),
        "g.sectionDisplay": S(zhHans: "显示", en: "Display", zhHant: "顯示", ja: "表示"),
        "g.sectionMenubar": S(zhHans: "菜单栏", en: "Menu bar", zhHant: "選單列", ja: "メニューバー"),
        "g.sectionStartup": S(zhHans: "启动", en: "Startup", zhHant: "啟動", ja: "起動"),
        "g.launchAtLogin":  S(zhHans: "登录时启动", en: "Launch at login", zhHant: "登入時啟動", ja: "ログイン時に起動"),
        "g.loginApproval":  S(zhHans: "需要在「系统设置 › 通用 › 登录项」中允许 OmniStats。", en: "Allow OmniStats in System Settings › General › Login Items.", zhHant: "需要在「系統設定 › 一般 › 登入項目」中允許 OmniStats。", ja: "「システム設定 › 一般 › ログイン項目」で OmniStats を許可してください。"),
        "g.openLoginItems": S(zhHans: "打开登录项", en: "Open Login Items", zhHant: "打開登入項目", ja: "ログイン項目を開く"),
        "g.loginNeedsApplications": S(zhHans: "请先将 OmniStats 移到「应用程序」文件夹再开启。", en: "Move OmniStats to the Applications folder to turn this on.", zhHant: "請先將 OmniStats 移到「應用程式」檔案夾再開啟。", ja: "有効にするには OmniStats を「アプリケーション」フォルダへ移動してください。"),
        "g.loginFailed":    S(zhHans: "无法更改登录项:%@", en: "Couldn't change the login item: %@", zhHant: "無法更改登入項目:%@", ja: "ログイン項目を変更できません:%@"),
        "g.language":    S(zhHans: "语言", en: "Language", zhHant: "語言", ja: "言語"),
        "g.theme":       S(zhHans: "主题", en: "Theme", zhHant: "主題", ja: "テーマ"),
        "g.tempUnit":    S(zhHans: "温度单位", en: "Temperature unit", zhHant: "溫度單位", ja: "温度単位"),
        "g.accent":      S(zhHans: "主题色", en: "Accent color", zhHant: "主題色", ja: "アクセントカラー"),
        "g.numberColor": S(zhHans: "菜单栏数字配色", en: "Menu-bar number color", zhHant: "選單列數字配色", ja: "メニューバー数字の配色"),
        "g.numColor.temp":   S(zhHans: "随温度", en: "By temp", zhHant: "隨溫度", ja: "温度連動"),
        "g.numColor.accent": S(zhHans: "主题色", en: "Accent", zhHant: "主題色", ja: "アクセント"),
        "g.numColor.mono":   S(zhHans: "单色", en: "Mono", zhHant: "單色", ja: "モノクロ"),
        "g.showTemp":        S(zhHans: "菜单栏显示温度", en: "Show temperature", zhHant: "選單列顯示溫度", ja: "温度を表示"),
        "g.showNetwork":     S(zhHans: "菜单栏显示网速", en: "Show network speed", zhHant: "選單列顯示網速", ja: "ネット速度を表示"),
        "g.showNetworkPanel": S(zhHans: "面板显示网络", en: "Network in panel", zhHant: "面板顯示網路", ja: "パネルにネットワーク"),
        "g.showProcesses":   S(zhHans: "面板显示进程占用", en: "Top processes in panel", zhHant: "面板顯示行程佔用", ja: "パネルにプロセス使用率"),
        "g.showBatteryPanel": S(zhHans: "面板显示电池", en: "Battery in panel", zhHant: "面板顯示電池", ja: "パネルにバッテリー"),
        "g.cpuWindow":       S(zhHans: "CPU 统计窗口", en: "CPU window", zhHant: "CPU 統計視窗", ja: "CPU 統計期間"),
        "g.sectionCharts":   S(zhHans: "图表", en: "Charts", zhHant: "圖表", ja: "チャート"),
        "g.topWidgetStyle":  S(zhHans: "顶部部件样式", en: "Top widgets", zhHant: "頂部部件樣式", ja: "上部ウィジェット"),
        "g.topWidgetWindow": S(zhHans: "图表时间窗口", en: "Chart window", zhHant: "圖表時間視窗", ja: "チャート期間"),
        "g.netChartKind":    S(zhHans: "网络展开图形态", en: "Network chart", zhHant: "網路展開圖形態", ja: "ネットワークチャート"),
        "cpuwin.realtime":   S(zhHans: "实时", en: "Live", zhHant: "即時", ja: "リアルタイム"),
        "cpuwin.10m":        S(zhHans: "10 分钟", en: "10 min", zhHant: "10 分鐘", ja: "10 分"),
        "cpuwin.30m":        S(zhHans: "30 分钟", en: "30 min", zhHant: "30 分鐘", ja: "30 分"),

        // Accent presets
        "accent.teal":     S(zhHans: "青", en: "Teal", zhHant: "青", ja: "ティール"),
        "accent.graphite": S(zhHans: "石墨", en: "Graphite", zhHant: "石墨", ja: "グラファイト"),
        "accent.aurora":   S(zhHans: "极光", en: "Aurora", zhHant: "極光", ja: "オーロラ"),
        "accent.sunset":   S(zhHans: "落日", en: "Sunset", zhHant: "落日", ja: "サンセット"),
        "accent.indigo":   S(zhHans: "靛蓝", en: "Indigo", zhHant: "靛藍", ja: "インディゴ"),

        // Battery pane
        "b.title":    S(zhHans: "电池", en: "Battery", zhHant: "電池", ja: "バッテリー"),
        "b.subtitle": S(zhHans: "电量、健康度与功率流向", en: "Charge, health & power flow", zhHant: "電量、健康度與功率流向", ja: "充電・状態・電力の流れ"),
        "b.status":   S(zhHans: "状态", en: "Status", zhHant: "狀態", ja: "状態"),
        "b.state.charging":    S(zhHans: "正在充电", en: "Charging", zhHant: "正在充電", ja: "充電中"),
        "b.state.notCharging": S(zhHans: "已接电源,未充电", en: "Plugged in, not charging", zhHant: "已接電源,未充電", ja: "電源接続中・充電停止"),
        "b.state.charged":     S(zhHans: "已充满", en: "Fully charged", zhHant: "已充滿", ja: "充電完了"),
        "b.state.discharging": S(zhHans: "使用电池", en: "On battery", zhHant: "使用電池", ja: "バッテリー駆動"),
        "b.hardwarePercent": S(zhHans: "硬件电量", en: "Hardware charge", zhHant: "硬體電量", ja: "ハードウェア残量"),
        "b.hardwareHelp":    S(zhHans: "电池实际剩余容量 ÷ 当前满充容量。macOS 显示的百分比经过平滑,可能略有不同。", en: "Raw remaining capacity ÷ current full-charge capacity. The macOS percentage is smoothed and can differ slightly.", zhHant: "電池實際剩餘容量 ÷ 目前滿充容量。macOS 顯示的百分比經過平滑,可能略有不同。", ja: "実際の残容量 ÷ 現在のフル充電容量。macOS の表示は平滑化されているため、わずかに異なることがあります。"),
        "b.timeToFull":  S(zhHans: "充满还需", en: "Time to full", zhHant: "充滿還需", ja: "満充電まで"),
        "b.timeToEmpty": S(zhHans: "剩余使用时间", en: "Time remaining", zhHant: "剩餘使用時間", ja: "残り時間"),
        "b.powerSource": S(zhHans: "电源", en: "Power source", zhHant: "電源", ja: "電源"),
        "b.noAdapter":   S(zhHans: "未连接", en: "Not connected", zhHant: "未連接", ja: "未接続"),
        "b.adapterConnected": S(zhHans: "已连接", en: "Connected", zhHant: "已連接", ja: "接続中"),
        "b.powerFlow":   S(zhHans: "功率流向", en: "Power flow", zhHant: "功率流向", ja: "電力の流れ"),
        "b.fromAdapter": S(zhHans: "电源输入", en: "From adapter", zhHant: "電源輸入", ja: "アダプタから"),
        "b.systemLoad":  S(zhHans: "系统功耗", en: "System load", zhHant: "系統功耗", ja: "システム消費"),
        "b.batteryFlow": S(zhHans: "电池", en: "Battery", zhHant: "電池", ja: "バッテリー"),
        "b.batteryFlowHelp": S(zhHans: "正值为充电,负值为放电(电压 × 电流)。", en: "Positive while charging, negative while discharging (voltage × current).", zhHant: "正值為充電,負值為放電(電壓 × 電流)。", ja: "正の値は充電、負の値は放電(電圧 × 電流)。"),
        "b.adapterLoss": S(zhHans: "转换损耗", en: "Conversion loss", zhHant: "轉換損耗", ja: "変換ロス"),
        "b.voltageCurrent": S(zhHans: "电压 / 电流", en: "Voltage / current", zhHant: "電壓 / 電流", ja: "電圧 / 電流"),
        "b.health":      S(zhHans: "健康度", en: "Health", zhHant: "健康度", ja: "バッテリーの状態"),
        "b.maxCapacity": S(zhHans: "最大容量", en: "Maximum capacity", zhHant: "最大容量", ja: "最大容量"),
        "b.capacityHelp": S(zhHans: "额定满充容量 ÷ 设计容量。macOS 按自己的周期更新「最大容量」,可能相差一两个百分点。", en: "Nominal full-charge capacity ÷ design capacity. macOS updates its own Maximum Capacity figure on its own schedule, so it can differ by a point or two.", zhHant: "額定滿充容量 ÷ 設計容量。macOS 依自己的週期更新「最大容量」,可能相差一兩個百分點。", ja: "公称フル充電容量 ÷ 設計容量。macOS の「最大容量」は独自の周期で更新されるため、1〜2 ポイント異なることがあります。"),
        "b.fullCharge":  S(zhHans: "满充容量", en: "Full-charge capacity", zhHant: "滿充容量", ja: "フル充電容量"),
        "b.design":      S(zhHans: "设计容量", en: "Design capacity", zhHant: "設計容量", ja: "設計容量"),
        "b.cycles":      S(zhHans: "循环次数", en: "Cycle count", zhHant: "循環次數", ja: "充放電回数"),
        "b.temperature": S(zhHans: "温度", en: "Temperature", zhHant: "溫度", ja: "温度"),
        "b.loading":     S(zhHans: "读取中…", en: "Reading…", zhHant: "讀取中…", ja: "読み込み中…"),
        "b.unavailable": S(zhHans: "无法读取电池信息", en: "Battery information unavailable", zhHant: "無法讀取電池資訊", ja: "バッテリー情報を取得できません"),
        "b.hm": S(zhHans: "%d 小时 %d 分钟", en: "%d h %d min", zhHant: "%d 小時 %d 分鐘", ja: "%d 時間 %d 分"),
        "b.m":  S(zhHans: "%d 分钟", en: "%d min", zhHant: "%d 分鐘", ja: "%d 分"),

        // Charge control
        "cc.title":   S(zhHans: "充电上限", en: "Charge limit", zhHant: "充電上限", ja: "充電上限"),
        "cc.enable":  S(zhHans: "限制充电", en: "Limit charging", zhHant: "限制充電", ja: "充電を制限"),
        "cc.stopAt":  S(zhHans: "充到 %d%% 时停止", en: "Stop charging at %d%%", zhHant: "充到 %d%% 時停止", ja: "%d%% で充電を停止"),
        "cc.resumeAt": S(zhHans: "降到 %d%% 时恢复充电", en: "Resume charging at %d%%", zhHant: "降到 %d%% 時恢復充電", ja: "%d%% で充電を再開"),
        "cc.resumeHelp": S(zhHans: "两者之间既不充电也不补电,电池不会在上限附近反复充放(航行模式)。", en: "In between, the battery neither charges nor tops up, so it doesn't cycle around the limit (sailing mode).", zhHant: "兩者之間既不充電也不補電,電池不會在上限附近反覆充放(航行模式)。", ja: "その間は充電も補充もしないため、上限付近で充放電を繰り返しません(セーリングモード)。"),
        "cc.nativeBelow": S(zhHans: "macOS 自身的充电上限为 %d%%,会先停止充电。要充到 %d%%,请在「系统设置 › 电池」中提高它。", en: "macOS's own charge limit is %d%% and stops charging first. To charge to %d%%, raise it in System Settings › Battery.", zhHant: "macOS 自身的充電上限為 %d%%,會先停止充電。要充到 %d%%,請在「系統設定 › 電池」中提高它。", ja: "macOS 自体の充電上限 %d%% で先に充電が止まります。%d%% まで充電するには「システム設定 › バッテリー」で引き上げてください。"),
        "cc.nativeSafety": S(zhHans: "macOS 自身的充电上限(%d%%)保留为安全兜底。", en: "macOS's own charge limit (%d%%) stays as a safety net.", zhHant: "macOS 自身的充電上限(%d%%)保留為安全備援。", ja: "macOS 自体の充電上限(%d%%)は安全策として残ります。"),
        "cc.openBattery": S(zhHans: "打开电池设置", en: "Open Battery Settings", zhHant: "打開電池設定", ja: "バッテリー設定を開く"),
        "cc.unsupported": S(zhHans: "这台 Mac 的固件不允许 App 控制充电。可在「系统设置 › 电池」中使用 macOS 自带的充电上限(80–100%)。", en: "This Mac's firmware doesn't let apps control charging. Use macOS's own charge limit (80–100%) in System Settings › Battery.", zhHant: "這台 Mac 的韌體不允許 App 控制充電。可在「系統設定 › 電池」中使用 macOS 內建的充電上限(80–100%)。", ja: "この Mac のファームウェアはアプリによる充電制御を許可していません。「システム設定 › バッテリー」の macOS 標準の充電上限(80〜100%)を使ってください。"),
        "cc.conflict": S(zhHans: "%@ 正在控制充电。退出它后 OmniStats 才会接管。", en: "%@ is controlling charging. Quit it to let OmniStats take over.", zhHant: "%@ 正在控制充電。結束它後 OmniStats 才會接手。", ja: "%@ が充電を制御しています。終了すると OmniStats が引き継ぎます。"),
        "cc.needsHelper": S(zhHans: "控制充电需要 OmniStats 服务(需要管理员授权一次)。", en: "Controlling charging needs the OmniStats service (one administrator authorization).", zhHant: "控制充電需要 OmniStats 服務(需要管理員授權一次)。", ja: "充電の制御には OmniStats サービスが必要です(管理者認証は 1 回のみ)。"),
        "cc.install":  S(zhHans: "安装服务", en: "Install service", zhHant: "安裝服務", ja: "サービスをインストール"),
        "cc.paused":   S(zhHans: "已在 %d%% 暂停充电", en: "Charging paused at %d%%", zhHant: "已在 %d%% 暫停充電", ja: "%d%% で充電を一時停止中"),
        "cc.chargingTo": S(zhHans: "将充电至 %d%%", en: "Charging up to %d%%", zhHant: "將充電至 %d%%", ja: "%d%% まで充電します"),
        "cc.onBattery": S(zhHans: "正在使用电池,接上电源后生效", en: "On battery; applies when you plug in", zhHant: "正在使用電池,接上電源後生效", ja: "バッテリー駆動中。電源接続時に適用されます"),
        "cc.toppingUp": S(zhHans: "正在充满,拔掉电源后恢复上限", en: "Charging to full; the limit returns when you unplug", zhHant: "正在充滿,拔掉電源後恢復上限", ja: "フル充電中。電源を外すと上限に戻ります"),
        "cc.topUp":    S(zhHans: "立即充满", en: "Charge to full now", zhHant: "立即充滿", ja: "今すぐフル充電"),
        "cc.cancelTopUp": S(zhHans: "取消充满", en: "Cancel full charge", zhHant: "取消充滿", ja: "フル充電を取り消す"),
        "cc.topUpNative": S(zhHans: "macOS 自身的上限(%d%%)仍会生效。", en: "macOS's own limit (%d%%) still applies.", zhHant: "macOS 自身的上限(%d%%)仍會生效。", ja: "macOS 自体の上限(%d%%)は引き続き有効です。"),
        "cc.sleepStop": S(zhHans: "睡眠时暂停充电", en: "Pause charging while asleep", zhHant: "睡眠時暫停充電", ja: "スリープ中は充電を停止"),
        "cc.sleepStopHelp": S(zhHans: "Mac 睡眠时无法在上限处停止充电;开启后会在睡眠前暂停充电。", en: "While the Mac sleeps nothing can stop at the limit; this pauses charging before sleep.", zhHant: "Mac 睡眠時無法在上限處停止充電;開啟後會在睡眠前暫停充電。", ja: "スリープ中は上限で止められないため、スリープ前に充電を停止します。"),
        "cc.stayAwake": S(zhHans: "充到上限前不进入闲置睡眠", en: "Stay awake until the limit is reached", zhHant: "充到上限前不進入閒置睡眠", ja: "上限に達するまでアイドルスリープしない"),
        "cc.writeFailed": S(zhHans: "写入 SMC 失败,固件更新可能已禁止充电控制。", en: "Writing to the SMC failed; a firmware update may have blocked charge control.", zhHant: "寫入 SMC 失敗,韌體更新可能已禁止充電控制。", ja: "SMC への書き込みに失敗しました。ファームウェア更新で充電制御が無効になった可能性があります。"),
        "cc.error":   S(zhHans: "设置未生效:%@", en: "Couldn't apply the setting: %@", zhHant: "設定未生效:%@", ja: "設定を適用できません:%@"),
        "cc.unreachable": S(zhHans: "无法连接服务", en: "service unreachable", zhHant: "無法連接服務", ja: "サービスに接続できません"),
        "cc.heat":     S(zhHans: "高温保护", en: "Heat protection", zhHant: "高溫保護", ja: "高温保護"),
        "cc.heatHelp": S(zhHans: "电池过热时暂停充电,降温 3 °C 后恢复;在「立即充满」时同样生效。", en: "Pauses charging while the battery is hot and resumes once it has cooled by 3 °C, even during a full charge.", zhHant: "電池過熱時暫停充電,降溫 3 °C 後恢復;在「立即充滿」時同樣生效。", ja: "バッテリーが高温の間は充電を停止し、3 °C 下がると再開します。フル充電中も有効です。"),
        "cc.heatAbove": S(zhHans: "电池高于 %@ 时暂停充电", en: "Pause charging above %@", zhHant: "電池高於 %@ 時暫停充電", ja: "%@ を超えたら充電を停止"),
        "cc.heatNow":  S(zhHans: "电池当前 %@", en: "Battery is %@ now", zhHant: "電池目前 %@", ja: "現在のバッテリー温度 %@"),
        "cc.heatPaused": S(zhHans: "电池温度 %@,已暂停充电", en: "Charging paused: battery at %@", zhHant: "電池溫度 %@,已暫停充電", ja: "バッテリーが %@ のため充電を停止中"),
        "cc.led":      S(zhHans: "MagSafe 指示灯", en: "MagSafe LED", zhHant: "MagSafe 指示燈", ja: "MagSafe LED"),
        "cc.led.system": S(zhHans: "系统", en: "System", zhHant: "系統", ja: "システム"),
        "cc.led.status": S(zhHans: "充电状态", en: "Charge state", zhHant: "充電狀態", ja: "充電状態"),
        "cc.led.off":  S(zhHans: "关闭", en: "Off", zhHant: "關閉", ja: "オフ"),
        "cc.ledHelp":  S(zhHans: "「充电状态」:正在充电时橙色,暂停或充满时绿色。", en: "Charge state: orange while charging, green while paused or full.", zhHant: "「充電狀態」:正在充電時橙色,暫停或充滿時綠色。", ja: "充電状態:充電中はオレンジ、停止中や満充電時はグリーン。"),
        "b.state.heat": S(zhHans: "温度过高,暂停充电", en: "Too warm, not charging", zhHant: "溫度過高,暫停充電", ja: "高温のため充電停止中"),
        "sched.title":  S(zhHans: "定时计划", en: "Schedule", zhHant: "定時計畫", ja: "スケジュール"),
        "sched.add":    S(zhHans: "添加", en: "Add", zhHant: "新增", ja: "追加"),
        "sched.delete": S(zhHans: "删除", en: "Delete", zhHant: "刪除", ja: "削除"),
        "sched.empty":  S(zhHans: "还没有计划。例如:工作日 7:00「立即充满」,出门前电量充足。", en: "No schedules yet. For example, \"Charge to full\" at 7:00 on weekdays so the battery is full when you leave.", zhHant: "還沒有計畫。例如:工作日 7:00「立即充滿」,出門前電量充足。", ja: "スケジュールはありません。例:平日 7:00 に「フル充電」で、出かける前に満充電にできます。"),
        "sched.note":   S(zhHans: "OmniStats 运行时执行;睡眠期间错过的计划会在唤醒后补做(12 小时内)。", en: "Runs while OmniStats is running; anything missed during sleep runs on wake (within 12 hours).", zhHant: "OmniStats 執行時運作;睡眠期間錯過的計畫會在喚醒後補做(12 小時內)。", ja: "OmniStats の実行中に動作します。スリープ中に過ぎた予定は復帰後に実行されます(12 時間以内)。"),
        "sched.shortcuts": S(zhHans: "快捷指令:用「打开 URL」,例如 omnistats://battery/limit?value=80、omnistats://battery/topup", en: "Shortcuts: use \"Open URL\", e.g. omnistats://battery/limit?value=80 or omnistats://battery/topup", zhHant: "捷徑:使用「打開 URL」,例如 omnistats://battery/limit?value=80、omnistats://battery/topup", ja: "ショートカット:「URL を開く」で、例 omnistats://battery/limit?value=80、omnistats://battery/topup"),
        "sched.action.setLimit": S(zhHans: "设置上限", en: "Set limit", zhHant: "設定上限", ja: "上限を設定"),
        "sched.action.topUp":    S(zhHans: "立即充满", en: "Charge to full", zhHant: "立即充滿", ja: "フル充電"),
        "sched.action.enable":   S(zhHans: "开启限制", en: "Turn limit on", zhHant: "開啟限制", ja: "制限をオン"),
        "sched.action.disable":  S(zhHans: "关闭限制", en: "Turn limit off", zhHant: "關閉限制", ja: "制限をオフ"),
        // Menu bar icons
        "mb.title":     S(zhHans: "菜单栏图标", en: "Menu Bar Icons", zhHant: "選單列圖示", ja: "メニューバーアイコン"),
        "mb.subtitle":  S(zhHans: "收起不常用的菜单栏图标", en: "Tuck away menu bar icons you rarely use", zhHant: "收起不常用的選單列圖示", ja: "あまり使わないメニューバーアイコンをしまう"),
        "mb.enable":    S(zhHans: "隐藏菜单栏图标", en: "Hide menu bar icons", zhHant: "隱藏選單列圖示", ja: "メニューバーアイコンを隠す"),
        "mb.howto":     S(zhHans: "按住 ⌘ 把图标拖到分隔线「|」左侧即可隐藏;点击「‹」显示或收起。不需要任何系统权限。", en: "Hold ⌘ and drag icons to the left of the | divider to hide them. Click ‹ to show or hide them. No system permissions needed.", zhHant: "按住 ⌘ 把圖示拖到分隔線「|」左側即可隱藏;點擊「‹」顯示或收起。不需要任何系統權限。", ja: "⌘ を押しながらアイコンを区切り線「|」の左へドラッグすると隠れます。「‹」をクリックで表示/非表示。システム権限は不要です。"),
        "mb.misordered": S(zhHans: "分隔线「|」需要在「‹」左侧才能隐藏图标,按住 ⌘ 把它拖回去。", en: "The | divider must sit left of ‹ to hide icons. Hold ⌘ and drag it back.", zhHant: "分隔線「|」需要在「‹」左側才能隱藏圖示,按住 ⌘ 把它拖回去。", ja: "アイコンを隠すには区切り線「|」が「‹」の左にある必要があります。⌘ を押しながら戻してください。"),
        "mb.alwaysHidden": S(zhHans: "始终隐藏区", en: "Always-hidden section", zhHant: "始終隱藏區", ja: "常に隠すセクション"),
        "mb.alwaysHiddenHelp": S(zhHans: "拖到虚线「┆」左侧的图标平时不显示;按住 ⌥ 点击(或右键点击)「‹」才会一起显示。", en: "Icons left of the dashed divider stay hidden; ⌥-click (or right-click) ‹ to show them as well.", zhHant: "拖到虛線「┆」左側的圖示平時不顯示;按住 ⌥ 點擊(或右鍵點擊)「‹」才會一起顯示。", ja: "点線の区切りより左のアイコンは常に隠れます。「‹」を ⌥ クリック(または右クリック)すると一緒に表示します。"),
        "mb.autoHide":  S(zhHans: "自动收起", en: "Hide again after", zhHant: "自動收起", ja: "自動で隠す"),
        "mb.never":     S(zhHans: "从不", en: "Never", zhHant: "從不", ja: "しない"),
        "mb.seconds":   S(zhHans: "%d 秒", en: "%d s", zhHant: "%d 秒", ja: "%d 秒"),
        "mb.minute":    S(zhHans: "1 分钟", en: "1 min", zhHant: "1 分鐘", ja: "1 分"),
        "mb.shortcut":  S(zhHans: "快捷键", en: "Shortcut", zhHant: "快速鍵", ja: "ショートカット"),
        "mb.record":    S(zhHans: "录制快捷键", en: "Record shortcut", zhHant: "錄製快速鍵", ja: "ショートカットを記録"),
        "mb.recording": S(zhHans: "请按下组合键…", en: "Type a shortcut…", zhHant: "請按下組合鍵…", ja: "キーを押してください…"),
        "mb.clear":     S(zhHans: "清除", en: "Clear", zhHant: "清除", ja: "消去"),
        "mb.shortcutHint": S(zhHans: "快捷键需要包含 ⌘、⌥ 或 ⌃;按 ⎋ 取消。", en: "A shortcut needs ⌘, ⌥ or ⌃; press ⎋ to cancel.", zhHant: "快速鍵需要包含 ⌘、⌥ 或 ⌃;按 ⎋ 取消。", ja: "⌘・⌥・⌃ のいずれかを含めてください。⎋ で取り消し。"),
        "mb.shortcutTaken": S(zhHans: "这个快捷键已被占用,请换一个。", en: "That shortcut is already taken; choose another.", zhHant: "這個快速鍵已被占用,請換一個。", ja: "このショートカットは使用中です。別のものを選んでください。"),
        "mb.systemNote": S(zhHans: "要彻底移除某个 App 的图标,可在「系统设置 › 菜单栏」中关闭它。", en: "To remove an app's icon entirely, turn it off in System Settings › Menu Bar.", zhHant: "要徹底移除某個 App 的圖示,可在「系統設定 › 選單列」中關閉它。", ja: "アプリのアイコンを完全に消すには「システム設定 › メニューバー」でオフにします。"),
        "mb.openSettings": S(zhHans: "打开菜单栏设置", en: "Open Menu Bar Settings", zhHant: "打開選單列設定", ja: "メニューバー設定を開く"),
        "mb.unsupported": S(zhHans: "macOS 27 重新设计了菜单栏,这一功能暂不支持。", en: "macOS 27 rebuilt the menu bar; this feature isn't supported there yet.", zhHant: "macOS 27 重新設計了選單列,這項功能暫不支援。", ja: "macOS 27 ではメニューバーが作り直されたため、この機能はまだ対応していません。"),
        "mb.toggleHelp": S(zhHans: "显示或隐藏菜单栏图标(⌥ 点击:包括始终隐藏的图标)", en: "Show or hide menu bar icons (⌥-click: include always-hidden ones)", zhHant: "顯示或隱藏選單列圖示(⌥ 點擊:包括始終隱藏的圖示)", ja: "メニューバーアイコンの表示/非表示(⌥ クリックで常に隠すものも)"),
        "mb.show":      S(zhHans: "显示隐藏的图标", en: "Show hidden icons", zhHant: "顯示隱藏的圖示", ja: "隠したアイコンを表示"),
        "mb.hide":      S(zhHans: "隐藏图标", en: "Hide icons", zhHant: "隱藏圖示", ja: "アイコンを隠す"),
        // Discharge & calibration
        "dc.title":   S(zhHans: "放电与校准", en: "Discharge & calibration", zhHant: "放電與校準", ja: "放電とキャリブレーション"),
        "dc.note":    S(zhHans: "放电时 OmniStats 会暂停电源适配器,由电池为 Mac 供电;拔掉电源、Mac 睡眠或服务停止时会立即恢复供电。", en: "Discharging pauses the power adapter so the Mac runs from its battery. Power returns at once if you unplug, the Mac sleeps, or the service stops.", zhHant: "放電時 OmniStats 會暫停電源轉接器,由電池為 Mac 供電;拔掉電源、Mac 睡眠或服務停止時會立即恢復供電。", ja: "放電中は電源アダプタを一時停止し、Mac をバッテリーで動かします。電源を外す、スリープする、サービスが止まると即座に給電を戻します。"),
        "dc.auto":    S(zhHans: "高于上限时放电到上限", en: "Discharge down to the limit when above it", zhHant: "高於上限時放電到上限", ja: "上限を超えたら上限まで放電"),
        "dc.target":  S(zhHans: "放电到 %d%%", en: "Discharge to %d%%", zhHant: "放電到 %d%%", ja: "%d%% まで放電"),
        "dc.start":   S(zhHans: "开始放电", en: "Discharge now", zhHant: "開始放電", ja: "今すぐ放電"),
        "dc.stop":    S(zhHans: "停止", en: "Stop", zhHant: "停止", ja: "停止"),
        "dc.active":  S(zhHans: "正在放电至 %d%%,电源已暂停", en: "Discharging to %d%%; adapter paused", zhHant: "正在放電至 %d%%,電源已暫停", ja: "%d%% まで放電中(アダプタ停止中)"),
        "dc.activeAuto": S(zhHans: "正在放电至上限 %d%%,电源已暂停", en: "Discharging to your %d%% limit; adapter paused", zhHant: "正在放電至上限 %d%%,電源已暫停", ja: "上限 %d%% まで放電中(アダプタ停止中)"),
        "dc.needsPlug": S(zhHans: "接上电源后才能放电或校准。", en: "Plug in the adapter to discharge or calibrate.", zhHant: "接上電源後才能放電或校準。", ja: "放電・キャリブレーションには電源の接続が必要です。"),
        "dc.calibrate": S(zhHans: "校准电池…", en: "Calibrate battery…", zhHant: "校準電池…", ja: "バッテリーをキャリブレーション…"),
        "dc.calibrateTitle": S(zhHans: "开始校准?", en: "Start calibration?", zhHant: "開始校準?", ja: "キャリブレーションを開始しますか?"),
        "dc.calibrateBody": S(zhHans: "校准会充满并保持 1 小时、放电到 15%、再充满并保持 1 小时,然后回到上限。放电快慢取决于用电量,轻度使用时全程可能接近一天。每一步都会自动进行,无需手动操作;放电时若开着低电量模式,会暂时换成「自动」,结束后恢复。期间请保持接通电源,Mac 不会进入闲置睡眠。", en: "Calibration charges to 100% and holds for an hour, discharges to 15%, charges to 100% and holds again, then returns to your limit. Discharging takes as long as your use takes; with light use the whole run can take most of a day. Every step runs on its own; Low Power Mode is switched to Automatic while discharging and restored afterwards. Keep the Mac plugged in; it won't idle-sleep meanwhile.", zhHant: "校準會充滿並保持 1 小時、放電到 15%、再充滿並保持 1 小時,然後回到上限。放電快慢取決於用電量,輕度使用時全程可能接近一天。每一步都會自動進行,無需手動操作;放電時若開著低耗電模式,會暫時換成「自動」,結束後恢復。期間請保持接通電源,Mac 不會進入閒置睡眠。", ja: "100% まで充電して 1 時間保持、15% まで放電、再び 100% で 1 時間保持した後、上限に戻ります。放電の速さは使い方次第で、軽い使用では全体で 1 日近くかかることがあります。各ステップは自動で進みます。放電中は低電力モードを一時的に「自動」にし、終了後に元に戻します。電源を接続したままにしてください。その間アイドルスリープしません。"),
        "dc.calibrateStart": S(zhHans: "开始校准", en: "Start", zhHant: "開始校準", ja: "開始"),
        "dc.cancel":  S(zhHans: "取消", en: "Cancel", zhHant: "取消", ja: "キャンセル"),
        "dc.needsNative100": S(zhHans: "校准需要充到 100%%:请先在「系统设置 › 电池」中把 macOS 的充电上限设为 100%%(当前 %d%%)。", en: "Calibration needs a full charge: first set macOS's charge limit to 100%% in System Settings › Battery (now %d%%).", zhHant: "校準需要充到 100%%:請先在「系統設定 › 電池」中把 macOS 的充電上限設為 100%%(目前 %d%%)。", ja: "キャリブレーションには満充電が必要です。先に「システム設定 › バッテリー」で macOS の充電上限を 100%% にしてください(現在 %d%%)。"),
        "dc.calibrating": S(zhHans: "正在校准", en: "Calibrating", zhHant: "正在校準", ja: "キャリブレーション中"),
        "dc.progress.charge": S(zhHans: "当前 %d%%,已 %d 分钟", en: "now %d%%, %d min so far", zhHant: "目前 %d%%,已 %d 分鐘", ja: "現在 %d%%、経過 %d 分"),
        "dc.progress.now": S(zhHans: "当前 %d%%", en: "now %d%%", zhHant: "目前 %d%%", ja: "現在 %d%%"),
        "dc.calibrateAuto": S(zhHans: "全程自动进行,无需手动操作。接近充满时最后 1% 可能要充很久,这是正常的;充到 99% 且充电结束也算充满。轻度使用时放电到 15% 可能要十几个小时,最长等 24 小时。中途拔掉电源或点「停止」会结束这次校准。", en: "Every step runs on its own; there is nothing to do. The last percent before full can take a long time, which is normal; 99% with charging finished counts as full. With light use, discharging to 15% can take well over ten hours; it gets up to 24. Unplugging or Stop ends this calibration.", zhHant: "全程自動進行,無需手動操作。接近充滿時最後 1% 可能要充很久,這是正常的;充到 99% 且充電結束也算充滿。輕度使用時放電到 15% 可能要十幾個小時,最長等 24 小時。中途拔掉電源或點「停止」會結束這次校準。", ja: "すべて自動で進むため、操作は不要です。満充電直前の最後の 1% には時間がかかることがありますが正常です。99% で充電が終わった場合も満充電とみなします。軽い使用では 15% までの放電に 10 時間以上かかることがあり、最長 24 時間待ちます。電源を外すか「停止」を押すと、このキャリブレーションは終了します。"),
        "dc.phase.charge1": S(zhHans: "第 1/5 步:充电到 100%", en: "Step 1/5: charging to 100%", zhHant: "第 1/5 步:充電到 100%", ja: "ステップ 1/5:100% まで充電"),
        "dc.phase.hold1": S(zhHans: "第 2/5 步:保持 100%%,还剩 %d 分钟", en: "Step 2/5: holding at 100%%, %d min left", zhHant: "第 2/5 步:保持 100%%,還剩 %d 分鐘", ja: "ステップ 2/5:100%% を保持、残り %d 分"),
        "dc.phase.discharge": S(zhHans: "第 3/5 步:放电到 15%", en: "Step 3/5: discharging to 15%", zhHant: "第 3/5 步:放電到 15%", ja: "ステップ 3/5:15% まで放電"),
        "dc.phase.charge2": S(zhHans: "第 4/5 步:充电到 100%", en: "Step 4/5: charging to 100%", zhHant: "第 4/5 步:充電到 100%", ja: "ステップ 4/5:100% まで充電"),
        "dc.phase.hold2": S(zhHans: "第 5/5 步:保持 100%%,还剩 %d 分钟", en: "Step 5/5: holding at 100%%, %d min left", zhHant: "第 5/5 步:保持 100%%,還剩 %d 分鐘", ja: "ステップ 5/5:100%% を保持、残り %d 分"),
        "dc.phase.toLimit": S(zhHans: "收尾:放电回到上限", en: "Finishing: discharging to your limit", zhHant: "收尾:放電回到上限", ja: "仕上げ:上限まで放電"),
        "dc.resultDone": S(zhHans: "上次校准已完成。", en: "The last calibration finished.", zhHant: "上次校準已完成。", ja: "前回のキャリブレーションは完了しました。"),
        "dc.resultStopped": S(zhHans: "上次校准提前结束(拔掉电源、手动停止或某一步超时)。", en: "The last calibration stopped early (unplugged, stopped, or a step took too long).", zhHant: "上次校準提前結束(拔掉電源、手動停止或某一步逾時)。", ja: "前回のキャリブレーションは途中で終了しました(電源の取り外し、停止、またはタイムアウト)。"),
        "b.state.adapterPaused": S(zhHans: "放电中,电源已暂停", en: "Discharging, adapter paused", zhHant: "放電中,電源已暫停", ja: "放電中(アダプタ停止)"),
        // App uninstaller
        "un.title":    S(zhHans: "应用卸载", en: "Uninstall Apps", zhHant: "應用程式解除安裝", ja: "アプリのアンインストール"),
        "un.subtitle": S(zhHans: "连同设置、缓存和后台服务一起移到废纸篓", en: "Move apps to the Trash together with their settings, caches and background services", zhHant: "連同設定、快取和背景服務一起移到垃圾桶", ja: "設定・キャッシュ・バックグラウンドサービスごとゴミ箱へ移動"),
        "un.search":   S(zhHans: "搜索应用", en: "Search apps", zhHant: "搜尋應用程式", ja: "アプリを検索"),
        "un.empty":    S(zhHans: "选择左侧的应用,查看它留下的文件。", en: "Select an app to see the files it leaves behind.", zhHant: "選擇左側的應用程式,查看它留下的檔案。", ja: "アプリを選ぶと、残っているファイルが表示されます。"),
        "un.scanning": S(zhHans: "正在查找相关文件…", en: "Looking for related files…", zhHant: "正在尋找相關檔案…", ja: "関連ファイルを検索中…"),
        "un.nothing":  S(zhHans: "没有找到其他文件。", en: "No other files found.", zhHant: "沒有找到其他檔案。", ja: "ほかのファイルは見つかりませんでした。"),
        "un.appStore": S(zhHans: "App Store", en: "App Store", zhHant: "App Store", ja: "App Store"),
        "un.running":  S(zhHans: "正在运行", en: "Running", zhHant: "正在執行", ja: "実行中"),
        "un.admin":    S(zhHans: "需管理员", en: "Admin", zhHant: "需管理員", ja: "管理者"),
        "un.fdaBadge": S(zhHans: "需完全磁盘访问", en: "Needs Full Disk Access", zhHant: "需完整磁碟取用", ja: "フルディスクアクセスが必要"),
        "un.total":    S(zhHans: "已选 %d 项 · %@", en: "%d items selected · %@", zhHant: "已選 %d 項 · %@", ja: "%d 項目を選択 · %@"),
        "un.remove":   S(zhHans: "移到废纸篓…", en: "Move to Trash…", zhHant: "移到垃圾桶…", ja: "ゴミ箱に入れる…"),
        "un.confirmTitle": S(zhHans: "将「%@」移到废纸篓?", en: "Move \"%@\" to the Trash?", zhHant: "將「%@」移到垃圾桶?", ja: "「%@」をゴミ箱に入れますか?"),
        "un.confirmBody": S(zhHans: "%d 项将移到废纸篓,可以从废纸篓恢复。其中 %d 项位于系统文件夹,需要管理员授权。", en: "%d items go to the Trash, where you can restore them. %d of them are in system folders and need administrator authorization.", zhHant: "%d 項將移到垃圾桶,可以從垃圾桶復原。其中 %d 項位於系統檔案夾,需要管理員授權。", ja: "%d 項目をゴミ箱に入れます(ゴミ箱から戻せます)。うち %d 項目はシステムフォルダにあり、管理者の認証が必要です。"),
        "un.confirmBodyUser": S(zhHans: "%d 项将移到废纸篓,可以从废纸篓恢复。", en: "%d items go to the Trash, where you can restore them.", zhHant: "%d 項將移到垃圾桶,可以從垃圾桶復原。", ja: "%d 項目をゴミ箱に入れます(ゴミ箱から戻せます)。"),
        "un.confirm":  S(zhHans: "移到废纸篓", en: "Move to Trash", zhHant: "移到垃圾桶", ja: "ゴミ箱に入れる"),
        "un.cancel":   S(zhHans: "取消", en: "Cancel", zhHant: "取消", ja: "キャンセル"),
        "un.quitTitle": S(zhHans: "「%@」正在运行", en: "\"%@\" is running", zhHant: "「%@」正在執行", ja: "「%@」は実行中です"),
        "un.quitBody": S(zhHans: "请先退出它:运行中的应用会占用这些文件,还可能把它们重新写回。", en: "Quit it first: a running app keeps these files in use and may write them back.", zhHant: "請先結束它:執行中的應用程式會佔用這些檔案,還可能把它們重新寫回。", ja: "先に終了してください。実行中のアプリはこれらのファイルを使用中で、書き戻すこともあります。"),
        "un.quit":     S(zhHans: "退出", en: "Quit", zhHant: "結束", ja: "終了"),
        "un.forceQuit": S(zhHans: "强制退出", en: "Force Quit", zhHant: "強制結束", ja: "強制終了"),
        "un.done":     S(zhHans: "已将 %d 项移到废纸篓。", en: "Moved %d items to the Trash.", zhHant: "已將 %d 項移到垃圾桶。", ja: "%d 項目をゴミ箱に入れました。"),
        "un.partial":  S(zhHans: "%d 项未能移走:", en: "%d items couldn't be moved:", zhHant: "%d 項未能移走:", ja: "%d 項目を移動できませんでした:"),
        "un.showLog":  S(zhHans: "查看日志", en: "Show Log", zhHant: "查看紀錄", ja: "ログを表示"),
        "un.needsFDA": S(zhHans: "需要完全磁盘访问权限", en: "needs Full Disk Access", zhHant: "需要完整磁碟取用權限", ja: "フルディスクアクセスが必要"),
        "un.appBlocked": S(zhHans: "macOS 阻止了移除这个应用。可在 Finder 中把它拖到废纸篓,或在「系统设置 › 隐私与安全性 › App 管理」中允许 OmniStats 后重试。", en: "macOS blocked removing this app. Drag it to the Trash in Finder, or allow OmniStats under System Settings › Privacy & Security › App Management and try again.", zhHant: "macOS 阻止了移除這個應用程式。可在 Finder 中把它拖到垃圾桶,或在「系統設定 › 隱私權與安全性 › App 管理」中允許 OmniStats 後重試。", ja: "macOS がこのアプリの削除をブロックしました。Finder でゴミ箱にドラッグするか、「システム設定 › プライバシーとセキュリティ › App の管理」で OmniStats を許可して再試行してください。"),
        "un.toolMissing": S(zhHans: "缺少清理工具", en: "cleanup tool missing", zhHant: "缺少清理工具", ja: "クリーンアップツールがありません"),
        "un.adminCancelled": S(zhHans: "未获得管理员授权", en: "administrator authorization was cancelled", zhHant: "未取得管理員授權", ja: "管理者の認証がキャンセルされました"),
        "un.fdaBanner": S(zhHans: "OmniStats 没有完全磁盘访问权限,其他应用的容器(Containers)无法移除。请在「系统设置 › 隐私与安全性 › 完全磁盘访问」中添加 OmniStats;每次 OmniStats 更新后,macOS 会要求重新授权。", en: "OmniStats doesn't have Full Disk Access, so other apps' containers can't be removed. Add OmniStats under System Settings › Privacy & Security › Full Disk Access; macOS asks again after each OmniStats update.", zhHant: "OmniStats 沒有完整磁碟取用權限,其他應用程式的容器(Containers)無法移除。請在「系統設定 › 隱私權與安全性 › 完整磁碟取用權限」中加入 OmniStats;每次 OmniStats 更新後,macOS 會要求重新授權。", ja: "OmniStats にフルディスクアクセスがないため、ほかのアプリのコンテナは削除できません。「システム設定 › プライバシーとセキュリティ › フルディスクアクセス」で OmniStats を追加してください。OmniStats の更新後は再度許可が必要です。"),
        "un.openFDA":  S(zhHans: "打开设置", en: "Open Settings", zhHant: "打開設定", ja: "設定を開く"),
        "un.byName":   S(zhHans: "按名称", en: "By name", zhHant: "依名稱", ja: "名前で一致"),
        "un.byNameHelp": S(zhHans: "这个文件夹与应用同名,而不是通过标识符找到的;删除前请确认它属于这个应用。", en: "Found because the folder has the app's name, not its identifier; check that it belongs to this app.", zhHant: "這個檔案夾與應用程式同名,而不是透過識別碼找到的;刪除前請確認它屬於這個應用程式。", ja: "識別子ではなくアプリ名で見つかったフォルダです。このアプリのものか確認してください。"),
        "un.kind.app":          S(zhHans: "应用", en: "App", zhHant: "應用程式", ja: "アプリ"),
        "un.kind.support":      S(zhHans: "应用数据", en: "App data", zhHant: "應用程式資料", ja: "アプリデータ"),
        "un.kind.caches":       S(zhHans: "缓存", en: "Caches", zhHant: "快取", ja: "キャッシュ"),
        "un.kind.preferences":  S(zhHans: "偏好设置", en: "Preferences", zhHant: "偏好設定", ja: "環境設定"),
        "un.kind.container":    S(zhHans: "容器", en: "Container", zhHant: "容器", ja: "コンテナ"),
        "un.kind.groupContainer": S(zhHans: "共享容器", en: "Group container", zhHant: "共享容器", ja: "グループコンテナ"),
        "un.kind.launchAgent":  S(zhHans: "后台项", en: "Launch agent", zhHant: "背景項目", ja: "起動エージェント"),
        "un.kind.launchDaemon": S(zhHans: "系统服务", en: "Launch daemon", zhHant: "系統服務", ja: "起動デーモン"),
        "un.kind.helper":       S(zhHans: "特权助手", en: "Privileged helper", zhHant: "特權輔助程式", ja: "特権ヘルパー"),
        "un.kind.logs":         S(zhHans: "日志", en: "Logs", zhHant: "紀錄", ja: "ログ"),
        "un.kind.savedState":   S(zhHans: "窗口状态", en: "Saved state", zhHant: "視窗狀態", ja: "保存された状態"),
        "un.kind.webData":      S(zhHans: "网页数据", en: "Web data", zhHant: "網頁資料", ja: "Web データ"),
        "un.kind.receipt":      S(zhHans: "安装记录", en: "Install receipt", zhHant: "安裝紀錄", ja: "インストール記録"),
        "un.kind.scripts":      S(zhHans: "脚本", en: "Scripts", zhHant: "腳本", ja: "スクリプト"),
        "un.kind.other":        S(zhHans: "其他", en: "Other", zhHant: "其他", ja: "その他"),
        "un.mode.installed": S(zhHans: "已安装的应用", en: "Installed apps", zhHant: "已安裝的應用程式", ja: "インストール済みのアプリ"),
        "un.mode.leftovers": S(zhHans: "已删除应用的残留", en: "Leftovers of deleted apps", zhHant: "已刪除應用程式的殘留", ja: "削除したアプリの残り"),
        "un.resetButton": S(zhHans: "重置…", en: "Reset…", zhHant: "重置…", ja: "リセット…"),
        "un.reset":    S(zhHans: "重置", en: "Reset", zhHant: "重置", ja: "リセット"),
        "un.resetHelp": S(zhHans: "保留应用,只把所选的数据、缓存和设置移到废纸篓,让它像刚安装一样。", en: "Keep the app and move only the selected data, caches and settings to the Trash, as if freshly installed.", zhHant: "保留應用程式,只把所選的資料、快取和設定移到垃圾桶,讓它像剛安裝一樣。", ja: "アプリは残し、選んだデータ・キャッシュ・設定だけをゴミ箱に入れて、インストール直後の状態にします。"),
        "un.resetTitle": S(zhHans: "重置「%@」?", en: "Reset \"%@\"?", zhHant: "重置「%@」?", ja: "「%@」をリセットしますか?"),
        "un.resetBody": S(zhHans: "应用本身、它的后台服务和安装记录会保留;所选的数据与设置会丢失,下次打开时就像刚安装一样。", en: "The app, its background services and its install receipt stay; the selected data and settings go, so it starts as if freshly installed.", zhHant: "應用程式本身、它的背景服務和安裝紀錄會保留;所選的資料與設定會遺失,下次打開時就像剛安裝一樣。", ja: "アプリ本体・バックグラウンドサービス・インストール記録は残ります。選んだデータと設定は消え、次回はインストール直後の状態で起動します。"),
        "un.brewHint": S(zhHans: "这个应用由 Homebrew 安装,它的清理清单已包含在下方(标为 Homebrew)。在这里移除后,Homebrew 仍会记得它;若想让 Homebrew 一并忘掉,可以改在终端运行:", en: "Homebrew installed this app; its cask's cleanup list is included below (marked Homebrew). Removing it here leaves Homebrew's record behind. To have Homebrew forget it as well, run this in Terminal instead:", zhHant: "這個應用程式由 Homebrew 安裝,它的清理清單已包含在下方(標為 Homebrew)。在這裡移除後,Homebrew 仍會記得它;若想讓 Homebrew 一併忘掉,可以改在終端機執行:", ja: "このアプリは Homebrew でインストールされています。cask のクリーンアップ一覧も下に含めています(Homebrew の表示)。ここで削除すると Homebrew の記録は残ります。Homebrew からも消すには、代わりにターミナルで次を実行してください:"),
        "un.fromCaskHelp": S(zhHans: "来自这个应用的 Homebrew cask 清理清单(zap)。", en: "From this app's Homebrew cask cleanup list (zap).", zhHant: "來自這個應用程式的 Homebrew cask 清理清單(zap)。", ja: "このアプリの Homebrew cask のクリーンアップ一覧(zap)から。"),
        "un.copy":     S(zhHans: "复制", en: "Copy", zhHant: "拷貝", ja: "コピー"),
        "un.copied":   S(zhHans: "已复制", en: "Copied", zhHant: "已拷貝", ja: "コピーしました"),
        "un.orphanIntro": S(zhHans: "查找已不在 Mac 上的应用留下的设置、缓存和后台服务。默认不勾选任何项:请逐项确认后再移除。", en: "Find settings, caches and background services left by apps that are no longer on this Mac. Nothing is ticked by default: review each item before removing it.", zhHant: "尋找已不在 Mac 上的應用程式留下的設定、快取和背景服務。預設不勾選任何項目:請逐項確認後再移除。", ja: "この Mac にもうないアプリが残した設定・キャッシュ・バックグラウンドサービスを探します。初期状態では何も選択されません。確認してから削除してください。"),
        "un.scan":     S(zhHans: "扫描", en: "Scan", zhHant: "掃描", ja: "スキャン"),
        "un.rescan":   S(zhHans: "重新扫描", en: "Scan Again", zhHant: "重新掃描", ja: "再スキャン"),
        "un.orphanNone": S(zhHans: "没有找到已删除应用的残留。", en: "No leftovers of deleted apps found.", zhHant: "沒有找到已刪除應用程式的殘留。", ja: "削除したアプリの残りは見つかりませんでした。"),
        "un.orphanTitle": S(zhHans: "将 %d 项残留移到废纸篓?", en: "Move %d leftovers to the Trash?", zhHant: "將 %d 項殘留移到垃圾桶?", ja: "残り %d 項目をゴミ箱に入れますか?"),
        "m.limitChip": S(zhHans: "上限 %d%%", en: "Limit %d%%", zhHant: "上限 %d%%", ja: "上限 %d%%"),
        "b.state.held": S(zhHans: "已达上限,暂停充电", en: "Held at the limit", zhHant: "已達上限,暫停充電", ja: "上限で充電停止中"),

        // About pane
        "a.title":    S(zhHans: "关于", en: "About", zhHant: "關於", ja: "情報"),
        "a.subtitle": S(zhHans: "OmniStats %@ · Apple Silicon 系统监控",
                        en: "OmniStats %@ · Apple Silicon system monitor",
                        zhHant: "OmniStats %@ · Apple Silicon 系統監控",
                        ja: "OmniStats %@ · Apple Silicon システムモニター"),
        "a.body":     S(zhHans: "OmniStats 是一套轻量的 Apple Silicon 菜单栏系统监控工具。当前提供温度监控与风扇控制:温度取自 HID 传感器,风扇经 SMC 控制,采用温度平滑 + 限斜率渐进调速,并带安全看门狗。",
                        en: "OmniStats is a lightweight Apple Silicon menu-bar system monitor. It offers temperature monitoring and fan control: temperatures come from HID sensors, fans are driven via SMC with temperature smoothing, slew-rate limiting, and a safety watchdog.",
                        zhHant: "OmniStats 是一套輕量的 Apple Silicon 選單列系統監控工具。目前提供溫度監控與風扇控制:溫度取自 HID 感測器,風扇經 SMC 控制,採用溫度平滑 + 限斜率漸進調速,並帶安全看門狗。",
                        ja: "OmniStats は軽量な Apple Silicon 向けメニューバー システムモニターです。温度監視とファン制御に対応:温度は HID センサーから取得し、ファンは SMC 経由で温度平滑化・スルーレート制限・安全ウォッチドッグ付きで制御します。"),
        "a.githubRepo":     S(zhHans: "GitHub 仓库", en: "GitHub repo", zhHant: "GitHub 倉庫", ja: "GitHub リポジトリ"),
        "a.softwareUpdate": S(zhHans: "软件更新", en: "Software update", zhHant: "軟件更新", ja: "ソフトウェア更新"),
        "a.autoCheck":      S(zhHans: "自动检查更新", en: "Check for updates automatically", zhHant: "自動檢查更新", ja: "自動で更新を確認"),
        "a.autoDownload":   S(zhHans: "后台自动下载,就绪后提示安装", en: "Auto-download in the background, then prompt to install", zhHant: "背景自動下載,就緒後提示安裝", ja: "バックグラウンドで自動ダウンロードし、準備後にインストールを確認"),
        "a.checkNow":       S(zhHans: "立即检查", en: "Check now", zhHant: "立即檢查", ja: "今すぐ確認"),
        "a.currentVersion": S(zhHans: "当前版本 %@", en: "Current version %@", zhHant: "目前版本 %@", ja: "現在のバージョン %@"),
        "a.removeHelper":   S(zhHans: "移除风扇控制助手", en: "Remove fan-control helper", zhHant: "移除風扇控制助手", ja: "ファン制御ヘルパーを削除"),
        "a.license":        S(zhHans: "MIT License · 开源项目,欢迎 issue 与 PR。",
                              en: "MIT License · open source — issues & PRs welcome.",
                              zhHant: "MIT License · 開源專案,歡迎 issue 與 PR。",
                              ja: "MIT License · オープンソース。Issue・PR 歓迎。"),

        // Curve editor
        "c.addPoint":    S(zhHans: "添加点", en: "Add point", zhHant: "新增點", ja: "点を追加"),
        "c.removePoint": S(zhHans: "删除点", en: "Remove point", zhHant: "刪除點", ja: "点を削除"),
        "c.reset":       S(zhHans: "重置", en: "Reset", zhHant: "重設", ja: "リセット"),
        // Update UI is provided (and localized) by Sparkle itself.
    ]
}
