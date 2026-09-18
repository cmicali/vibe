//
//  VibeWidgetReloader.swift
//  Vibe (iOS)
//
//  The whole reason Swift is in this target: WidgetCenter has no Objective-C
//  API, and nothing else can tell WidgetKit that a published snapshot is newer
//  than what the home screen is showing.
//
//  Keep it this small. Anything that can be written in Objective-C belongs in
//  Objective-C, beside the code that already owns the concern.
//

import Foundation
import WidgetKit

// public, not internal: the generated Vibe-Swift.h is what Objective-C sees,
// and an internal class does not reach it.
@objc(VibeWidgetReloader)
public final class VibeWidgetReloader: NSObject {
    // Reloads are rate-limited by the system, not by us: WidgetKit coalesces
    // and budgets them, so the caller's job is only to publish the file first
    // and call this after. A dropped reload costs a stale widget until the
    // next publish, never wrong data — the extension re-reads the file.
    @objc(reload)
    public static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
