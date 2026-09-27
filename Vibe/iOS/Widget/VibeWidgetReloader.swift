//
//  VibeWidgetReloader.swift
//  Vibe (iOS)
//
//  WidgetCenter has no Objective-C API. Keep this small: anything that can be
//  Objective-C belongs beside the code that owns the concern.
//

import Foundation
import WidgetKit

// public: an internal class does not reach Vibe-Swift.h.
@objc(VibeWidgetReloader)
public final class VibeWidgetReloader: NSObject {
    // Call after the files are written; WidgetPublisher throttles, WidgetKit
    // budgets. A dropped reload costs a stale widget, never wrong data.
    @objc(reload)
    public static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    // Answers on WidgetKit's queue. Fails OPEN: a wrong NO silences the widget
    // until the next foreground, a wrong YES costs one unread publish.
    @objc(queryPlaced:)
    public static func queryPlaced(_ completion: @escaping (Bool) -> Void) {
        WidgetCenter.shared.getCurrentConfigurations { result in
            switch result {
            case .success(let placed): completion(!placed.isEmpty)
            case .failure: completion(true)
            }
        }
    }
}
