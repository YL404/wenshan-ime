import Foundation
import UIKit

/// 键盘偏好：只存可以随键盘一起读的本机设置，App Group UserDefaults 里一份。
/// 键盘进程会被销毁重建，所以「沿用上次中英文」之类的记忆必须落盘。
enum KeyboardSettings {
    static let suiteName = AppGroup.identifier

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// 默认中英文（chinese / english），以及「沿用上次」开关。
    static var defaultMode: String {
        get { defaults.string(forKey: "defaultMode") ?? "chinese" }
        set { defaults.set(newValue, forKey: "defaultMode") }
    }

    static var rememberMode: Bool {
        get { defaults.bool(forKey: "rememberMode") }
        set { defaults.set(newValue, forKey: "rememberMode") }
    }

    /// 用户上次按中/英键选的模式，只在 rememberMode 打开时写。
    static var lastMode: String? {
        get { defaults.string(forKey: "lastMode") }
        set { defaults.set(newValue, forKey: "lastMode") }
    }

    /// 键盘出现时的模式：沿用上次优先，否则用默认。
    static var startupMode: String {
        rememberMode ? (lastMode ?? defaultMode) : defaultMode
    }

    /// 每页候选数，1...9，默认 9。
    static var candidatePageSize: Int {
        get {
            let value = defaults.integer(forKey: "candidatePageSize")
            return value == 0 ? 9 : min(max(1, value), 9)
        }
        set { defaults.set(min(max(1, newValue), 9), forKey: "candidatePageSize") }
    }

    /// 强调色：存系统色名，避免把动态色解析成固定 RGB 后深浅模式不跟随。
    static var accentName: String {
        get { defaults.string(forKey: "accentName") ?? "blue" }
        set { defaults.set(newValue, forKey: "accentName") }
    }

    /// 候选字号是否跟随系统的文字大小设置，默认开。
    static var dynamicCandidateFont: Bool {
        get { defaults.object(forKey: "dynamicCandidateFont") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dynamicCandidateFont") }
    }

    /// 中文标点后按空格改回 ASCII，默认关：它改写用户已经看到的字符。
    static var spaceRevertsPunctuation: Bool {
        get { defaults.bool(forKey: "spaceRevertsPunctuation") }
        set { defaults.set(newValue, forKey: "spaceRevertsPunctuation") }
    }

    /// 触感强度：system / light / medium / heavy，默认 medium。
    static var hapticStrength: String {
        get { defaults.string(forKey: "hapticStrength") ?? "medium" }
        set { defaults.set(newValue, forKey: "hapticStrength") }
    }

    /// 是否记录键盘诊断日志（需要完全访问才能写 App Group）。
    static var diagnosticLog: Bool {
        get { defaults.bool(forKey: "diagnosticLog") }
        set { defaults.set(newValue, forKey: "diagnosticLog") }
    }

    /// 强调色名对应的动态色，以及可选的自定义 RGB（custom 时读这里）。
    static func accentColor(traits: UITraitCollection) -> UIColor {
        if accentName == "custom" {
            let red = defaults.double(forKey: "accentRed")
            let green = defaults.double(forKey: "accentGreen")
            let blue = defaults.double(forKey: "accentBlue")
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        }
        let resolved = UITraitCollection(userInterfaceStyle: traits.userInterfaceStyle)
        return namedAccent(accentName).resolvedColor(with: resolved)
    }

    static func namedAccent(_ name: String) -> UIColor {
        switch name {
        case "blue": return .systemBlue
        case "orange": return .systemOrange
        case "pink": return .systemPink
        case "purple": return .systemPurple
        case "green": return .systemGreen
        case "teal": return .systemTeal
        case "red": return .systemRed
        default: return .systemBlue
        }
    }

    static func setCustomAccent(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        defaults.set(Double(red), forKey: "accentRed")
        defaults.set(Double(green), forKey: "accentGreen")
        defaults.set(Double(blue), forKey: "accentBlue")
        accentName = "custom"
    }

    /// 候选字号：按 Dynamic Type 的 body 缩放，再夹到当前设备档位的上下限。
    static func candidateFontSize(base: CGFloat, traits: UITraitCollection, isPad: Bool) -> CGFloat {
        guard dynamicCandidateFont else { return base }
        let metrics = UIFontMetrics(forTextStyle: .body)
        let scaled = metrics.scaledValue(for: base, compatibleWith: traits)
        let upper: CGFloat = isPad ? 32 : 24
        return min(max(12, scaled), upper)
    }

    /// 触感反馈样式和力度。system 用不带参数的 .light，交给系统默认。
    static func hapticStyle() -> (UIImpactFeedbackGenerator.FeedbackStyle, CGFloat?) {
        switch hapticStrength {
        case "system": return (.light, nil)
        case "light": return (.light, 0.5)
        case "heavy": return (.heavy, 1.0)
        default: return (.medium, 0.8)
        }
    }
}
