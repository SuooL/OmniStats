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
        // Language
        "lang.system": S(zhHans: "跟随系统", en: "System", zhHant: "跟隨系統", ja: "システムに従う"),

        // Settings window
        "settings.window": S(zhHans: "OmniStats 设置", en: "OmniStats Settings", zhHant: "OmniStats 設定", ja: "OmniStats 設定"),

        // Settings sections
        "section.fans":    S(zhHans: "风扇", en: "Fans",    zhHant: "風扇", ja: "ファン"),
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
        "m.battery":  S(zhHans: "电池", en: "Battery", zhHant: "電池", ja: "バッテリー"),
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
        "g.cpuWindow":       S(zhHans: "CPU 统计窗口", en: "CPU window", zhHant: "CPU 統計視窗", ja: "CPU 統計期間"),
        "cpuwin.realtime":   S(zhHans: "实时", en: "Live", zhHant: "即時", ja: "リアルタイム"),
        "cpuwin.10m":        S(zhHans: "10 分钟", en: "10 min", zhHant: "10 分鐘", ja: "10 分"),
        "cpuwin.30m":        S(zhHans: "30 分钟", en: "30 min", zhHant: "30 分鐘", ja: "30 分"),

        // Accent presets
        "accent.teal":     S(zhHans: "青", en: "Teal", zhHant: "青", ja: "ティール"),
        "accent.graphite": S(zhHans: "石墨", en: "Graphite", zhHant: "石墨", ja: "グラファイト"),
        "accent.aurora":   S(zhHans: "极光", en: "Aurora", zhHant: "極光", ja: "オーロラ"),
        "accent.sunset":   S(zhHans: "落日", en: "Sunset", zhHant: "落日", ja: "サンセット"),
        "accent.indigo":   S(zhHans: "靛蓝", en: "Indigo", zhHant: "靛藍", ja: "インディゴ"),

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
