import AppKit
import Combine
import os
import PerchCore
import SwiftUI

final class NotchModel: ObservableObject {
    typealias Phase = IslandPhase

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
    /// The open player shows lyrics (only while the feature is on).
    @Published var showLyrics = Pref.bool(Pref.lyricsOpen)
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
    static let log = Logger(subsystem: "dev.perch.Perch", category: "island")

    let model = NotchModel()
    private let media = MediaService.shared
    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var track: Track?
    private var pausedTooLong = false
    private var fullscreen = false
    private var capturing = false
    private var captureTimer: Timer?
    private var seenFirstTrack = false

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

    private static let panelSize = CGSize(width: 800, height: 720)

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

        let geometry = NotchLayout.geometry(screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
                                            leftAuxWidth: screen.auxiliaryTopLeftArea?.width,
                                            rightAuxWidth: screen.auxiliaryTopRightArea?.width)
        if geometry.notch != model.notchSize || geometry.hasNotch != model.hasNotch {
            Self.log.notice("Display: notch \(geometry.hasNotch), \(Int(geometry.notch.width))×\(Int(geometry.notch.height))")
        }
        let nowFullscreen = Pref.bool(Pref.hideInFullscreen) && Self.isFullscreen(screen)
        if nowFullscreen != fullscreen {
            fullscreen = nowFullscreen
            Self.log.notice("Full-screen space: \(nowFullscreen)")
        }
        updateCaptureWatch()
        let active = track != nil && !pausedTooLong
        // The volume indicator stays even during a recording: it says nothing about the music.
        let visible = model.hud != nil || !fullscreen && !capturing
            && (geometry.hasNotch || (Pref.bool(Pref.showOnNonNotch) && (active || model.phase == .expanded)))

        let frame = CGRect(x: screen.frame.midX - Self.panelSize.width / 2,
                           y: screen.frame.maxY - Self.panelSize.height,
                           width: Self.panelSize.width, height: Self.panelSize.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        if model.notchSize != geometry.notch { model.notchSize = geometry.notch }
        if model.hasNotch != geometry.hasNotch { model.hasNotch = geometry.hasNotch }
        if model.active != active || model.visible != visible {
            let growing = (active && !model.active) || (visible && !model.visible)
            withAnimation(growing ? Motion.grow : Motion.shrink) {
                model.active = active
                model.visible = visible
                if !visible, model.phase != .collapsed { model.phase = .collapsed }
                if !active, model.phase == .peek { model.phase = .collapsed }
            }
        }
        cachedHitRect = nil
        evaluateMouse()
    }

    // MARK: Screen recording and sharing

    private typealias WatcherFn = @convention(c) () -> Bool
    /// SkyLight reports whether anything is capturing the screen (recording, a call
    /// sharing the screen, QuickTime…). There is no public API for this.
    private static let screenWatcher: WatcherFn? = {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let symbol = dlsym(handle, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(symbol, to: WatcherFn.self)
    }()

    /// With "Hide while the screen is recorded or shared" on, the island asks capture
    /// tools to leave it out (older ones honour that) and disappears while a capture
    /// is running, because ScreenCaptureKit on macOS 15.4+ ignores the request.
    private func updateCaptureWatch() {
        let wanted = Pref.bool(Pref.hideFromCapture)
        let sharing: NSWindow.SharingType = wanted ? .none : .readOnly
        if panel?.sharingType != sharing { panel?.sharingType = sharing }
        if wanted, captureTimer == nil, Self.screenWatcher != nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.pollCapture() }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            captureTimer = timer
            capturing = Self.screenWatcher?() ?? false
        } else if !wanted, captureTimer != nil {
            captureTimer?.invalidate()
            captureTimer = nil
            capturing = false
        }
    }

    private func pollCapture() {
        let now = Self.screenWatcher?() ?? false
        guard now != capturing else { return }
        capturing = now
        Self.log.notice("Screen capture \(now ? "started; hiding the island" : "ended", privacy: .public)")
        refresh()
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

        // No card for the song that was already playing when Perch started.
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
        withAnimation(phase == .collapsed ? Motion.shrink : Motion.grow) {
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
        let fresh = model.hud == nil
        withAnimation(fresh ? Motion.grow : Motion.update) {
            model.hud = state
            model.visible = true
            if model.phase == .peek { model.phase = .collapsed }
        }
        cachedHitRect = nil
        announce(state)
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Motion.shrink) { self?.model.hud = nil }
            self?.refresh()
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, Pref.double(Pref.hudDuration)), execute: work)
        evaluateMouse()
    }

    /// The system indicator is announced by VoiceOver; ours has to be too.
    private func announce(_ state: HUDState) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: state.spokenDescription,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Open / close

    func expand() {
        guard !fullscreen else { return }
        openWork?.cancel(); closeWork?.cancel(); peekWork?.cancel()
        if !model.visible { withAnimation(Motion.grow) { model.visible = true } }
        setPhase(.expanded)
    }

    /// Opens the island for a look from Settings or the welcome window and closes
    /// it again after a few seconds unless the pointer moves onto it.
    func preview() {
        expand()
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isInside, self.model.phase == .expanded else { return }
            self.collapse()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func collapse() {
        openWork?.cancel(); closeWork?.cancel()
        setPhase(.collapsed)
    }

    func toggle() { model.phase == .expanded ? collapse() : expand() }

    func toggleLyrics() {
        let open = !model.showLyrics
        withAnimation(open ? Motion.grow : Motion.shrink) { model.showLyrics = open }
        Pref.set(open, Pref.lyricsOpen)
        cachedHitRect = nil
        evaluateMouse()
    }

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
        // While hovered, the swollen island counts, so the edge does not flicker.
        let size = NotchLayout.size(phase: model.phase, notch: model.notchSize, hasNotch: model.hasNotch,
                                    active: model.active, scale: Pref.double(Pref.scale),
                                    hud: model.hud == nil ? nil : Pref.value(Pref.hudStyle, HUDStyle.beside),
                                    swell: model.hovering && !Motion.reduced,
                                    lyricsHeight: LyricsSpace.currentHeight(scale: Pref.double(Pref.scale)))
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
            withAnimation(Motion.swell) { model.hovering = swell }
            cachedHitRect = nil
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

    private var holds = 0

    /// Keeps the island open while `body` runs, e.g. a menu shown from one of its buttons.
    func holdOpen(_ body: () -> Void) {
        holds += 1
        body()
        holds -= 1
        cachedHitRect = nil
        evaluateMouse()
        if !isInside, model.phase == .expanded { scheduleClose() }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isInside, self.model.phase == .expanded else { return }
            // Mid-drag on the scrubber, or a menu opened from the island is still up.
            if NSEvent.pressedMouseButtons != 0 || self.holds > 0 { self.scheduleClose(); return }
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

    // MARK: Diagnostics

    func diagnosticRows() -> [(String, String)] {
        [
            ("State", model.phase.rawValue),
            ("Visible", model.visible ? "yes" : "no"),
            ("Music shown", model.active ? "yes" : "no"),
            ("Notch", model.hasNotch ? "\(Int(model.notchSize.width))×\(Int(model.notchSize.height))" : "none"),
            ("Full-screen space", fullscreen ? "yes" : "no"),
            ("Hide while captured", Pref.bool(Pref.hideFromCapture) ? "on" : "off"),
            ("Screen being captured", capturing ? "yes" : "no"),
            ("Indicator on screen", model.hud == nil ? "no" : "yes"),
        ]
    }
}
