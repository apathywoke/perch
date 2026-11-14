import AppKit
import SwiftUI

/// Shown once on the first launch: how the island works, the optional
/// Accessibility permission (explained before macOS asks for it), and privacy.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0
    @ObservedObject private var hud = SystemHUD.shared
    @AppStorage(Pref.hudEnabled) private var hudEnabled = true
    @AppStorage(Pref.openTrigger) private var openTrigger = OpenTrigger.hover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: indicators
                default: privacy
                }
            }
            .id(page)
            .transition(pageTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 34)

            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Page \(page + 1) of \(pageCount)"))
                Spacer()
                if page > 0 {
                    Button("Back") { go(to: page - 1) }
                }
                if page < pageCount - 1 {
                    Button("Next") { go(to: page + 1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: finish)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 560, height: 440)
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 28)),
                                              removal: .opacity.combined(with: .offset(x: -28)))
    }

    private func go(to target: Int) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.9)) {
            page = target
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text("Perch lives in the notch")
                .font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Row(symbol: "cursorarrow.rays",
                    text: openTrigger == .click
                        ? "Click the notch to open the player."
                        : "Point at the notch to open the player. The delay can be changed in Settings.")
                Row(symbol: "hand.draw", text: "Swipe sideways with two fingers on the island to switch tracks.")
                Row(symbol: "contextualmenu.and.cursorarrow",
                    text: "Right-click the island or use the bird icon in the menu bar for Settings.")
            }
            Button("Show the island") { NotchController.shared.preview() }
        }
    }

    private var indicators: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                Image(systemName: "speaker.wave.2.fill")
                Image(systemName: "sun.max.fill")
            }
            .font(.system(size: 38, weight: .medium))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
            Text("Volume and brightness")
                .font(.title.weight(.semibold))
            Text("Perch can show volume and brightness in the island instead of the system indicators.")
            Text("For this macOS asks for Accessibility access. Perch then receives only the media keys, never ordinary keystrokes.")
                .foregroundStyle(.secondary)
            Group {
                if !hudEnabled {
                    Text("The system indicators stay. You can change this later in Settings.")
                        .foregroundStyle(.secondary)
                    Button("Use Perch indicators") { hudEnabled = true }
                } else if hud.trusted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 12) {
                        Button("Allow access") { hud.requestAccess() }
                            .buttonStyle(.borderedProminent)
                        Button("Keep the system indicators") { hudEnabled = false }
                    }
                    Text("If macOS shows a request, click “Open System Settings” and switch Perch on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var privacy: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Private by design")
                .font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Row(symbol: "eye.slash", text: "No telemetry, analytics or crash reporting.")
                Row(symbol: "wifi.slash",
                    text: "No network connections. Features that need the internet stay off until you turn them on.")
                Row(symbol: "doc.on.clipboard",
                    text: "Diagnostics are copied to the clipboard only when you ask for them.")
            }
        }
    }
}

private struct Row: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
