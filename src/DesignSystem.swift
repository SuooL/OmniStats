import SwiftUI
import AppKit

// Shared building blocks for Settings and the panel. Pages compose these rather
// than styling cards, rows and notes by hand, so spacing, type and color stay the
// same on every page. Motion is used only for state changes, never on a timer.

extension Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let page: CGFloat = 26
    }
    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
    }
    // One type scale for every page: titles, card headings, rows, help text.
    enum Typo {
        static let pageTitle = Font.system(size: 21, weight: .bold)
        static let pageSubtitle = Font.system(size: 12)
        static let heading = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let secondary = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let micro = Font.system(size: 9)
    }
    enum Motion {
        static let quick = Animation.easeInOut(duration: 0.18)
        static let standard = Animation.easeInOut(duration: 0.25)
    }
    // Settings content is one column this wide at most, so cards and headers align.
    static let contentMaxWidth: CGFloat = 760

    // Status colors, reserved for state (never a chart series); always paired with
    // an icon or a label, never color alone.
    static var success: Color { pick(0x53D08A, 0x1E8F58) }
    static var warning: Color { pick(0xE3B341, 0xA86F00) }
    static var danger: Color { pick(0xF85149, 0xCF2233) }
    static var info: Color { pick(0x58A6FF, 0x0B6BCB) }
    // Recessed background for charts and editors inside a card.
    static var well: Color { pick(0x0B0E13, 0xE9EDF2) }
}

// MARK: - Page structure

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Typo.pageTitle).foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle).font(Theme.Typo.pageSubtitle).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// A titled group. The heading row carries an optional symbol and a trailing accessory.
struct Card<Content: View, Accessory: View>: View {
    let title: String?
    let icon: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String? = nil, icon: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon
        self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if title != nil || icon != nil {
                HStack(spacing: Theme.Space.s) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent).frame(width: 16)
                    }
                    if let title { Text(title).font(Theme.Typo.heading).foregroundStyle(Theme.ink) }
                    Spacer(minLength: Theme.Space.s)
                    accessory
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    func cardBackground() -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 7, y: 2)
    }
}

// MARK: - Rows

// Label (and optional detail line) on the left, the control right-aligned.
struct SettingRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    let control: Control

    init(_ label: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label; self.detail = detail; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            control
        }
    }
}

struct ToggleRow: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool

    init(_ label: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.label = label; self.detail = detail; _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.themed)
    }
}

struct RowDivider: View {
    var body: some View { Divider().overlay(Theme.line) }
}

// Help text under a row or a card.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Status

enum CalloutKind {
    case info, warning, error, action
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .action: return "lock.shield.fill"
        }
    }
    var tint: Color {
        switch self {
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .error: return Theme.danger
        case .action: return Theme.accent
        }
    }
}

// A tinted message with an icon, for permissions, errors and things to do.
struct Callout<Actions: View>: View {
    let kind: CalloutKind
    let title: String?
    let message: String?
    let actions: Actions

    init(_ kind: CalloutKind, title: String? = nil, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.kind = kind; self.title = title; self.message = message; self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: kind.icon).font(.system(size: 15)).foregroundStyle(kind.tint)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(Theme.Typo.heading).foregroundStyle(Theme.ink) }
                if let message {
                    Text(message).font(Theme.Typo.caption).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            actions
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous)
            .stroke(kind.tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

extension Callout where Actions == EmptyView {
    init(_ kind: CalloutKind, title: String? = nil, message: String? = nil) {
        self.init(kind, title: title, message: message, actions: { EmptyView() })
    }
}

// A small capsule label, e.g. a version or a state.
struct Badge: View {
    let text: String
    var icon: String? = nil
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Buttons
// Primary: the one main action of a card. Secondary: everything else.
// Destructive actions go through ConfirmButton.

extension View {
    func primaryButton() -> some View {
        buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent)
    }
    func secondaryButton() -> some View {
        buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
    }
}

// A destructive action that asks first and says what will happen.
struct ConfirmButton: View {
    let title: String
    var icon: String? = nil
    let confirmTitle: String
    let message: String
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        Button(role: .destructive) { asking = true } label: {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
        }
        .buttonStyle(.bordered).controlSize(.small).tint(Theme.danger)
        .confirmationDialog(confirmTitle, isPresented: $asking) {
            Button(title, role: .destructive, action: action)
            Button(L.t("dc.cancel"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
