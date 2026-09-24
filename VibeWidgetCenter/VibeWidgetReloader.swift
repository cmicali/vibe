//
//  VibeWidgetReloader.swift
//  Vibe (iOS) and VibeWidgetCenter.bundle (macOS)
//
//  The app's only WidgetKit caller: WidgetCenter has no Objective-C API, and
//  nothing else can tell WidgetKit that a published snapshot is newer than
//  what the widget is showing, or whether a widget is placed at all.
//
//  On the mac it is not in the app. Linking WidgetKit loads it at launch, and
//  with it all of SwiftUI and, through that, WebKit — for every user, widget
//  or not. So the mac compiles this file alone into VibeWidgetCenter.bundle,
//  which WidgetPublisher loads the first time it has a widget to talk to. iOS
//  still compiles it into the app; its launch cost there is unmeasured.
//
//  Keep it this small. Anything that can be written in Objective-C belongs in
//  Objective-C, beside the code that already owns the concern.
//

import Foundation
import os
import WidgetKit

// public, not internal: on iOS the generated Vibe-Swift.h is what Objective-C
// sees, and an internal class does not reach it. The mac finds the class in
// the bundle by this runtime name.
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

    // Whether the now-playing widget is placed, from the one party that knows,
    // on WidgetKit's queue. A failed query is an error, not an answer: the
    // caller keeps what it knew rather than publishing on a guess or deleting
    // the mark on one.
    @objc(queryPlaced:)
    public static func queryPlaced(_ completion: @escaping (Bool, Error?) -> Void) {
        WidgetCenter.shared.getCurrentConfigurations { result in
            switch result {
            case .success(let configurations):
                let placed = configurations.filter { $0.kind == kind }
                log.notice("Widget: WidgetKit lists \(placed.count) placed: \(placed.map { "\($0.family)" }.joined(separator: ", "), privacy: .public)")
                completion(!placed.isEmpty, nil)
            case .failure(let error):
                log.error("Widget: WidgetKit query failed: \(error.localizedDescription, privacy: .public)")
                completion(false, error)
            }
        }
    }

    // VibeWidget.swift's StaticConfiguration kind.
    private static let kind = "VibeNowPlaying"

    private static let log = Logger(subsystem: "com.commonwealthrecordings.Vibe", category: "app")
}
