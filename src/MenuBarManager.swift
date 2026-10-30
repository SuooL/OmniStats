import AppKit
import Carbon.HIToolbox
import Combine

// A global shortcut, stored as Carbon key code + modifiers for RegisterEventHotKey
// (which needs no Accessibility permission, unlike event taps).
struct MenuBarHotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey, optionKey, controlKey, shiftKey
    var key: String         // printable key name, e.g. "B" or "Space"

    var display: String { Self.symbols(modifiers) + key }

    // At least ⌘, ⌥ or ⌃: a bare letter would swallow normal typing.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let modifiers = Self.carbonModifiers(flags)
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0,
              let key = Self.keyName(keyCode: keyCode, characters: characters) else { return nil }
        self.keyCode = UInt32(keyCode); self.modifiers = modifiers; self.key = key
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
    static func symbols(_ modifiers: UInt32) -> String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "")
            + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
    }
    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let name = named[Int(keyCode)] { return name }
        guard let characters = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              characters.count == 1 else { return nil }
        return characters
    }
}

enum MenuBarLayout {
    // macOS caps NSStatusItem.length at 10,000 pt; twice the widest screen pushes
    // everything left of a divider off every display.
    static func collapsedLength(screenWidths: [CGFloat]) -> CGFloat {
        min(10_000, max(500, (screenWidths.max() ?? 1000) * 2))
    }
    // Hiding is only safe while the dividers sit left of ‹ (and the always-hidden
    // one left of the other): otherwise ‹ itself would be pushed off-screen and
    // nothing could bring the icons back.
    static func isOrdered(toggle: CGFloat?, divider: CGFloat?, alwaysHidden: CGFloat?, usesAlwaysHidden: Bool) -> Bool {
        guard let toggle, let divider, divider < toggle else { return false }
        guard usesAlwaysHidden else { return true }
        guard let alwaysHidden else { return false }
        return alwaysHidden < divider
    }
    // macOS 27 draws the menu bar as one window and drops over-wide status items,
    // so the divider technique no longer works there.
    static func isSupported(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        majorVersion < 27
    }
    // Defer auto-hiding while the pointer is on a menu bar (e.g. a hidden app's menu is open).
    static func pointerInMenuBar(_ point: CGPoint, screens: [CGRect], barHeight: CGFloat = 40) -> Bool {
        screens.contains { $0.minX <= point.x && point.x <= $0.maxX && point.y >= $0.maxY - barHeight && point.y <= $0.maxY }
    }
}

private final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(_ hotKey: MenuBarHotKey, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, context, &handler)
        let identifier = EventHotKeyID(signature: OSType(0x4F4D_5342), id: 1)   // "OMSB"
        let registered = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, identifier,
                                             GetApplicationEventTarget(), 0, &reference)
        guard installed == noErr, registered == noErr else { return nil }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// Hides other apps' menu-bar icons behind OmniStats' ‹ control, Hidden-Bar style:
// a divider set to an enormous width pushes everything to its left off-screen.
// No permissions involved: the user arranges icons with ⌘-drag.
final class MenuBarManager: ObservableObject {
    @Published private(set) var expanded = false
    @Published private(set) var misordered = false
    @Published private(set) var hotKeyFailed = false

    static let toggleName = "omnistats.menubar.toggle"
    static let dividerName = "omnistats.menubar.divider"
    static let alwaysHiddenName = "omnistats.menubar.alwaysHidden"
    private static let dividerWidth: CGFloat = 12

    private let store: ConfigStore
    private let defaults: UserDefaults
    private let anchor: () -> CGFloat?
    private var applied: MenuBarSettings?
    private var toggle: NSStatusItem?
    private var divider: NSStatusItem?
    private var alwaysHidden: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var rehideTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?

    // `anchor`: OmniStats' own icon, as a distance from its screen's right edge.
    init(store: ConfigStore, defaults: UserDefaults = .standard, anchor: @escaping () -> CGFloat? = { nil }) {
        self.store = store
        self.defaults = defaults
        self.anchor = anchor
        store.$config
            .map { MenuBarSettings(hiding: $0.menuBarHiding, alwaysHidden: $0.menuBarAlwaysHidden, hotKey: $0.menuBarHotKey) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in self?.apply(settings) }
            .store(in: &bag)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.expanded else { return }
                self.collapse()
            }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        rehideTimer?.invalidate()
    }

    private struct MenuBarSettings: Equatable {
        var hiding: Bool, alwaysHidden: Bool, hotKey: MenuBarHotKey?
    }

    private func apply(_ settings: MenuBarSettings) {
        defer { applied = settings }
        guard settings.hiding, MenuBarLayout.isSupported() else {
            removeAll(); hotKey = nil; hotKeyFailed = false
            return
        }
        if settings.hotKey != applied?.hotKey || hotKey == nil {
            hotKey = nil
            hotKey = settings.hotKey.flatMap { GlobalHotKey($0) { [weak self] in self?.toggleExpanded(all: false) } }
            hotKeyFailed = settings.hotKey != nil && hotKey == nil
        }
        // A shortcut change alone leaves the icons where they are.
        guard settings.hiding != applied?.hiding || settings.alwaysHidden != applied?.alwaysHidden || toggle == nil else { return }
        if toggle == nil { createToggleAndDivider() }
        if settings.alwaysHidden, alwaysHidden == nil {
            alwaysHidden = makeItem(Self.alwaysHiddenName, leftOf: Self.dividerName, image: Self.dividerImage(dashed: true))
        } else if !settings.alwaysHidden, let item = alwaysHidden {
            remove(item); alwaysHidden = nil
        }
        // Start hidden once the status bar has laid the items out.
        expand(all: false, autoHide: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.collapse() }
    }

    private func createToggleAndDivider() {
        toggle = makeItem(Self.toggleName, leftOf: nil, image: nil)
        toggle?.button?.target = self
        toggle?.button?.action = #selector(toggleClicked)
        toggle?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle?.button?.toolTip = L.t("mb.toggleHelp")
        divider = makeItem(Self.dividerName, leftOf: Self.toggleName, image: Self.dividerImage(dashed: false))
    }

    // Preferred positions count from the right edge of the screen. A new item goes
    // just left of its neighbour (‹ just left of OmniStats' own icon), so it stays
    // visible on a crowded bar; afterwards the user's ⌘-drag position wins.
    private func makeItem(_ name: String, leftOf neighbour: String?, image: NSImage?) -> NSStatusItem {
        let key = "NSStatusItem Preferred Position \(name)"
        if defaults.object(forKey: key) == nil {
            let base = neighbour.flatMap { defaults.object(forKey: "NSStatusItem Preferred Position \($0)") as? Double }
                ?? anchor().map(Double.init)
                ?? defaults.object(forKey: "NSStatusItem Preferred Position Item-0") as? Double ?? 0
            defaults.set(base + 1, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: image == nil ? NSStatusItem.variableLength : Self.dividerWidth)
        item.autosaveName = name
        if let image { item.button?.image = image; item.button?.appearsDisabled = true }
        return item
    }

    // Removing an item deletes its stored position; keep the user's arrangement.
    private func remove(_ item: NSStatusItem) {
        let key = "NSStatusItem Preferred Position \(item.autosaveName ?? "")"
        let position = defaults.object(forKey: key)
        NSStatusBar.system.removeStatusItem(item)
        if let position { defaults.set(position, forKey: key) }
    }
    private func removeAll() {
        rehideTimer?.invalidate(); rehideTimer = nil
        [alwaysHidden, divider, toggle].compactMap { $0 }.forEach(remove)
        alwaysHidden = nil; divider = nil; toggle = nil
        expanded = false; misordered = false
    }

    @objc private func toggleClicked() {
        let all = NSEvent.modifierFlags.contains(.option) || NSApp.currentEvent?.type == .rightMouseUp
        toggleExpanded(all: all)
    }
    func toggleExpanded(all: Bool) {
        if expanded && !all { collapse() } else { expand(all: all, autoHide: true) }
    }

    func expand(all: Bool, autoHide: Bool) {
        guard let divider else { return }
        divider.length = Self.dividerWidth
        alwaysHidden?.length = all ? Self.dividerWidth : collapsedLength
        expanded = true
        updateToggle()
        rehideTimer?.invalidate(); rehideTimer = nil
        let seconds = store.config.menuBarAutoHide
        if autoHide && seconds > 0 { scheduleRehide(after: TimeInterval(seconds)) }
    }

    func collapse() {
        rehideTimer?.invalidate(); rehideTimer = nil
        guard let divider else { return }
        // Positions are only meaningful with every divider at its narrow width;
        // after widening one, read them once the status bar has re-laid out.
        let wide = [divider, alwaysHidden].compactMap { $0 }.contains { $0.length != Self.dividerWidth }
        divider.length = Self.dividerWidth
        alwaysHidden?.length = Self.dividerWidth
        if wide {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.collapseIfOrdered() }
        } else {
            collapseIfOrdered()
        }
    }

    private func collapseIfOrdered() {
        guard let divider else { return }
        let ordered = MenuBarLayout.isOrdered(toggle: toggle?.button?.window?.frame.minX,
                                              divider: divider.button?.window?.frame.minX,
                                              alwaysHidden: alwaysHidden?.button?.window?.frame.minX,
                                              usesAlwaysHidden: alwaysHidden != nil)
        if misordered == ordered { misordered = !ordered }
        guard ordered else { expanded = true; updateToggle(); return }
        divider.length = collapsedLength
        alwaysHidden?.length = collapsedLength
        expanded = false
        updateToggle()
    }

    private func scheduleRehide(after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            let screens = NSScreen.screens.map(\.frame)
            if MenuBarLayout.pointerInMenuBar(NSEvent.mouseLocation, screens: screens) {
                self.scheduleRehide(after: 3)
            } else {
                self.collapse()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rehideTimer = timer
    }

    private var collapsedLength: CGFloat {
        MenuBarLayout.collapsedLength(screenWidths: NSScreen.screens.map(\.frame.width))
    }
    private func updateToggle() {
        let name = expanded ? "chevron.right" : "chevron.left"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: L.t(expanded ? "mb.hide" : "mb.show"))
        image?.isTemplate = true
        toggle?.button?.image = image
    }
    private static func dividerImage(dashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: 2)); path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
            path.lineWidth = 1.5
            if dashed { path.setLineDash([2, 2], count: 2, phase: 0) }
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
