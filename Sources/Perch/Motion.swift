import AppKit
import SwiftUI

/// Every animation of the island in one place, so timings stay consistent and
/// the system "Reduce motion" setting is honoured everywhere: with it on, the
/// island cross-fades instead of springing, scaling and blurring.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static var style: AnimationStyle { Pref.value(Pref.animation, AnimationStyle.smooth) }

    /// The island growing: opening, the track card, an indicator appearing.
    static var grow: Animation { reduced ? .easeInOut(duration: 0.22) : style.open }

    /// The island shrinking back. No bounce, so it settles against the notch.
    static var shrink: Animation { reduced ? .easeInOut(duration: 0.2) : style.close }

    /// Content appearing inside the island, a beat after the shape starts to grow.
    static var contentIn: Animation { reduced ? .easeOut(duration: 0.2) : style.contentIn }

    /// Content leaving: quick, so it is gone before the shape closes over it.
    static var contentOut: Animation { .easeIn(duration: 0.11) }

    /// The island growing a little while the pointer rests on it.
    static var swell: Animation { reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.95) }

    /// Song title and artist trading places when the track changes.
    static var textIn: Animation { reduced ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.22).delay(0.1) }
    static var textOut: Animation { .easeIn(duration: 0.12) }

    /// A value changing inside an open indicator.
    static var update: Animation { reduced ? .linear(duration: 0.08) : .spring(response: 0.26, dampingFraction: 0.86) }
}
