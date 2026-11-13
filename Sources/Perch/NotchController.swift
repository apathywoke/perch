import AppKit
import Combine
import SwiftUI

final class NotchModel: ObservableObject {
    enum Phase { case collapsed, peek, expanded }

    @Published var phase: Phase = .collapsed
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var hasNotch = true
    /// A track is present and has not been paused for too long.
    @Published var active = false
    @Published var visible = true
    /// The cursor is resting on the collapsed island (it swells slightly before opening).
    @Published var hovering = false
    /// Volume / brightness indicator currently shown, if any.
    @Published var hud: HUDState?
}

enum NotchLayout {
    /// Radius of the concave corners that blend the island into the screen edge.
    static let earRadius: CGFloat = 6

    static let peekRow: CGFloat = 44
    static let peekArtwork: CGFloat = 52
    static let peekSide: CGFloat = 70
    // Expanded player metrics, multiplied by the size setting.
    static let artwork: CGFloat = 58
    static let inset: CGFloat = 22
    static let insetTop: CGFloat = 8

    static func wing(_ notch: CGSize) -> CGFloat { notch.height + 4 }
    static func topInset(hasNotch: Bool, notch: CGSize) -> CGFloat { hasNotch ? notch.height : 10 }

    static let hudWing: CGFloat = 96
    static let hudRow: CGFloat = 36

    static func hudSize(style: HUDStyle, notch: CGSize, hasNotch: Bool) -> CGSize {
        if !hasNotch { return CGSize(width: 290, height: notch.height) }
        switch style {
        case .beside: return CGSize(width: notch.width + 2 * hudWing, height: notch.height)
        case .below: return CGSize(width: max(notch.width + 2 * wing(notch), 330), height: notch.height + hudRow)
        }
    }

    static func size(phase: NotchModel.Phase, notch: CGSize, hasNotch: Bool, active: Bool, scale: CGFloat,
                     hud: HUDStyle? = nil) -> CGSize {
        if let hud, phase != .expanded { return hudSize(style: hud, notch: notch, hasNotch: hasNotch) }
        switch phase {
        case .expanded:
            return CGSize(width: max(388 * scale, notch.width + 60),
                          height: topInset(hasNotch: hasNotch, notch: notch) + 168 * scale)
        case .peek where active:
            return CGSize(width: max(notch.width + 2 * peekSide, 330), height: notch.height + peekRow)
        default:
            return active ? CGSize(width: notch.width + 2 * wing(notch), height: notch.height) : notch
        }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// AppKit would otherwise push the window down, out of the menu bar area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Owns the island window: where it sits, when it opens and closes, and the
/// mouse / gesture handling. The SwiftUI views only draw `NotchModel`.
final class NotchController {
    static let shared = NotchController()

    let model = NotchModel()
    private let media = MediaService.shared
    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var track: Track?
    private var pausedTooLong = false
    private var fullscreen = false

    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var isInside = false
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var hudWork: DispatchWorkItem?
    private var pauseWork: DispatchWorkItem?
    private var swipeAccumulated: CGFloat = 0
    private var swipeFired = false
    private var seenFirstTrack = false

    private static let panelSize = CGSize(width: 760, height: 380)

    // MARK: Setup

    func start() {
        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // after isFloatingPanel, which resets it
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NotchHostingView(rootView: IslandView(model: model, media: media))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel

        media.$track
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.trackChanged($0) }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .merge(with: center.publisher(for: UserDefaults.didChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
                // The space switch animation finishes a moment after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh() }
            }
            .store(in: &cancellables)

        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in self?.evaluateMouse() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
            self?.evaluateMouse()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleScroll(event)
            return event
        }) { monitors.append(monitor) }

        refresh()
        panel.orderFrontRegardless()
    }

    // MARK: Screen & visibility

    private func pickScreen() -> NSScreen? {
        switch Pref.value(Pref.display, DisplayChoice.auto) {
        case .auto: return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        case .main: return NSScreen.screens.first
        case .active: return NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// Recomputes everything that depends on the screen and on settings.
    func refresh() {
        guard let panel, let screen = pickScreen() else { return }
        self.screen = screen

        let hasNotch = screen.safeAreaInsets.top > 0
        var notch = CGSize(width: 184, height: 32)
        if hasNotch {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = screen.frame.width - left - right
            notch = CGSize(width: width > 60 ? width : 200, height: screen.safeAreaInsets.top)
        }
        fullscreen = Pref.bool(Pref.hideInFullscreen) && Self.isFullscreen(screen)
        let active = track != nil && !pausedTooLong
        let visible = model.hud != nil || !fullscreen
            && (hasNotch || (Pref.bool(Pref.showOnNonNotch) && (active || model.phase == .expanded)))

        let frame = CGRect(x: screen.frame.midX - Self.panelSize.width / 2,
                           y: screen.frame.maxY - Self.panelSize.height,
                           width: Self.panelSize.width, height: Self.panelSize.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        if model.notchSize != notch { model.notchSize = notch }
        if model.hasNotch != hasNotch { model.hasNotch = hasNotch }
        if model.active != active || model.visible != visible {
            withAnimation(AnimationStyle.current) {
                model.active = active
                model.visible = visible
                if !visible, model.phase != .collapsed { model.phase = .collapsed }
                if !active, model.phase == .peek { model.phase = .collapsed }
            }
        }
        cachedHitRect = nil
        evaluateMouse()
    }

    private typealias CGSConnectionFn = @convention(c) () -> Int32
    private typealias CGSSpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let cgs: (CGSConnectionFn, CGSSpacesFn)? = {
        let handle = dlopen(nil, RTLD_LAZY)
        guard let a = dlsym(handle, "CGSMainConnectionID"), let b = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(a, to: CGSConnectionFn.self), unsafeBitCast(b, to: CGSSpacesFn.self))
    }()

    /// True when the space currently shown on `screen` is a full-screen app.
    private static func isFullscreen(_ screen: NSScreen) -> Bool {
        guard let (connection, copySpaces) = cgs,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return false }
        var uuid: String?
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let cf = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, cf) as String?
        }
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? displays.first
        let type = (entry?["Current Space"] as? [String: Any])?["type"] as? Int
        return type == 4
    }

    // MARK: Track changes

    private func trackChanged(_ new: Track?) {
        let old = track
        track = new

        if new == nil || new?.isPlaying == true {
            pauseWork?.cancel(); pauseWork = nil
            pausedTooLong = false
        } else if pauseWork == nil, !pausedTooLong {
            let delay = Pref.double(Pref.hidePausedAfter)
            if delay > 0 {
                let work = DispatchWorkItem { [weak self] in
                    self?.pausedTooLong = true
                    self?.refresh()
                }
                pauseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        refresh()

        let launchTrack = !seenFirstTrack && new != nil
        if new != nil { seenFirstTrack = true }
        if let new, !launchTrack, new.isPlaying, new.id != old?.id, model.phase == .collapsed, model.visible,
           Pref.bool(Pref.peekOnTrackChange) {
            setPhase(.peek)
            peekWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                if self?.model.phase == .peek { self?.setPhase(.collapsed) }
            }
            peekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, Pref.double(Pref.peekDuration)), execute: work)
        }
    }

    // MARK: Phase

    private func setPhase(_ phase: NotchModel.Phase) {
        guard model.phase != phase else { return }
        let style = Pref.value(Pref.animation, AnimationStyle.smooth)
        withAnimation(phase == .expanded ? style.open : style.close) {
            model.phase = phase
            if phase == .expanded { model.hovering = false }
        }
        cachedHitRect = nil
        if phase == .expanded, Pref.bool(Pref.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // Size changed, so the visibility rules and the hit area did too.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // MARK: Volume / brightness indicator

    func showHUD(_ state: HUDState) {
        let style = Pref.value(Pref.animation, AnimationStyle.smooth)
        let fresh = model.hud == nil
        withAnimation(fresh ? style.open : .spring(response: 0.3, dampingFraction: 0.82)) {
            model.hud = state
            model.visible = true
            if model.phase == .peek { model.phase = .collapsed }
        }
        cachedHitRect = nil
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(style.close) { self?.model.hud = nil }
            self?.refresh()
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, Pref.double(Pref.hudDuration)), execute: work)
        evaluateMouse()
    }

    func expand() {
        guard !fullscreen else { return }
        openWork?.cancel(); closeWork?.cancel(); peekWork?.cancel()
        if !model.visible { withAnimation(AnimationStyle.current) { model.visible = true } }
        setPhase(.expanded)
    }

    func collapse() {
        openWork?.cancel(); closeWork?.cancel()
        setPhase(.collapsed)
    }

    func toggle() { model.phase == .expanded ? collapse() : expand() }

    func collapsedClicked() {
        if Pref.value(Pref.openTrigger, OpenTrigger.hover) == .click { expand(); return }
        switch Pref.value(Pref.clickAction, ClickAction.expand) {
        case .expand: expand()
        case .playPause: media.togglePlayPause()
        case .openApp: media.openSourceApp()
        case .none: break
        }
    }

    // MARK: Mouse

    /// Cached because it is consulted on every mouse move anywhere on screen.
    private var cachedHitRect: CGRect?
    private var ignoringMouse = true

    /// The island's current hit area in screen coordinates.
    private func hitRect() -> CGRect {
        if let cachedHitRect { return cachedHitRect }
        let rect = computeHitRect()
        cachedHitRect = rect
        return rect
    }

    private func computeHitRect() -> CGRect {
        guard let screen, model.visible else { return .zero }
        let size = NotchLayout.size(phase: model.phase, notch: model.notchSize, hasNotch: model.hasNotch,
                                    active: model.active, scale: Pref.double(Pref.scale),
                                    hud: model.hud == nil ? nil : Pref.value(Pref.hudStyle, HUDStyle.beside))
        let pad: CGFloat = model.phase == .expanded ? 12 : 0
        return CGRect(x: screen.frame.midX - size.width / 2 - pad, y: screen.frame.maxY - size.height - pad,
                      width: size.width + pad * 2, height: size.height + pad + 2)
    }

    private func evaluateMouse() {
        let inside = hitRect().contains(NSEvent.mouseLocation)
        // Changing this flag commits a window-server transaction, so only touch it when it flips.
        if ignoringMouse == inside {
            ignoringMouse = !inside
            panel?.ignoresMouseEvents = !inside
        }
        if inside, pollTimer == nil {
            // Mouse-moved events stop reaching us while the cursor is over our own
            // window, so watch for the exit with a short-lived timer instead.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.evaluateMouse() }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !inside, pollTimer != nil {
            pollTimer?.invalidate(); pollTimer = nil
        }
        guard inside != isInside else { return }
        isInside = inside

        let swell = inside && model.phase != .expanded
        if model.hovering != swell {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { model.hovering = swell }
        }

        if inside {
            closeWork?.cancel()
            guard model.phase != .expanded, Pref.value(Pref.openTrigger, OpenTrigger.hover) == .hover else { return }
            let work = DispatchWorkItem { [weak self] in
                if self?.isInside == true { self?.expand() }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Pref.double(Pref.hoverDelay), execute: work)
        } else {
            openWork?.cancel()
            swipeAccumulated = 0
            guard model.phase == .expanded else { return }
            scheduleClose()
        }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isInside, self.model.phase == .expanded else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleClose(); return } // mid-drag on the scrubber
            self.collapse()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, Pref.double(Pref.closeDelay)), execute: work)
    }

    private func handleScroll(_ event: NSEvent) {
        guard isInside, event.window === panel, Pref.bool(Pref.swipeGestures), model.active else { return }
        guard !event.phase.isEmpty else { return } // trackpad gestures only, not wheels or momentum
        if event.phase.contains(.began) { swipeAccumulated = 0; swipeFired = false }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        swipeAccumulated += event.scrollingDeltaX
        if !swipeFired, abs(swipeAccumulated) > 45 {
            swipeFired = true
            // Fingers moving left = next track, like turning a page.
            let forward = (swipeAccumulated < 0) != Pref.bool(Pref.invertSwipe)
            forward ? media.next() : media.previous()
            if Pref.bool(Pref.haptics) {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }
}
