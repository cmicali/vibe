// Uploads the localized App Store product page — promotional text,
// description, keywords, what's new, the support, marketing and privacy URLs,
// and screenshots — from Assets/app-store/ (layout: its README.md). Run through
// scripts/appstore-upload-metadata.sh, which resolves the API key.
//
// Targets the one editable version on ONE platform (--platform macos, the
// default, or ios): localizations hang off a version, and versions are per
// platform. Text is PATCHed only when it differs. A screenshot is uploaded
// only when no processed screenshot in its set has the file's checksum. The
// run then waits until App Store Connect has processed every upload, and
// orders each changed set by file name.

import BagbutikAppStore
import BagbutikAppStoreModels
import BagbutikCore
import CryptoKit
import Foundation

// Catalog language → ASC locale. nil: the App Store has no product page in
// that language, so it is skipped. An unmapped language is an error.
let ascLocale: [String: String?] = [
    "bg": nil,
    "cs": "cs", "da": "da", "de": "de-DE", "el": "el", "en": "en-US",
    "es": "es-ES", "fi": "fi", "fr": "fr-FR", "hr": "hr", "hu": "hu",
    "id": "id", "it": "it", "ja": "ja", "ko": "ko",
    "nb": "no", "nl": "nl-NL", "pl": "pl", "pt-BR": "pt-BR", "pt-PT": "pt-PT",
    "ro": "ro", "ru": "ru", "sk": "sk", "sv": "sv", "th": "th", "tr": "tr",
    "uk": "uk", "vi": "vi", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
]

// AppInfo (which carries the privacy policy URL) has its own state enum, so the
// editable set is spelled twice. An app normally has two AppInfos: the live one
// and the one being prepared.
let editableAppInfoStates: Set<AppInfo.Attributes.State> = [
    .prepareForSubmission, .developerRejected, .rejected,
    .readyForReview, .waitingForReview,
]

// States whose metadata App Store Connect still allows editing.
let editableStates: Set<AppVersionState> = [
    .prepareForSubmission, .developerRejected, .rejected, .metadataRejected,
    .invalidBinary, .readyForReview, .waitingForReview,
]

// TRAP: App Store Connect can leave a committed screenshot in UPLOAD_COMPLETE
// for good, with no errors and a null sourceFileChecksum. On the iOS 1.15
// upload about half of every batch did this, and "Add for Review" refused
// the version until each one was processed. Uploading the set again stalled
// as often, and re-sending the commit answered 500. Deleting one stuck
// screenshot and uploading it again is what worked, a few rounds over.
let screenshotStall: Duration = .seconds(240)
let screenshotPoll: Duration = .seconds(60)
let screenshotUploadRounds = 8

typealias ScreenshotFiles = (type: ScreenshotDisplayType, files: [URL])

// A screenshot set this run changed. `ids` holds the screenshot for each
// file, in file-name order.
typealias ChangedSet = (locale: String, localizationId: String, set: ScreenshotFiles,
                        setId: String, ids: [String])

// The version train written to; also names copy/<lang>/<platform>/.
enum TargetPlatform: String {
    case macos, ios

    var asc: Platform { self == .macos ? .macOS : .iOS }

    // Each ASC screenshot set and its subdirectory of
    // screenshots/<lang>/<platform>/. iPhone and iPad are separate sets, and
    // the iPad one is required because TARGETED_DEVICE_FAMILY is 1,2.
    //
    // There is no APP_IPHONE_69: ASC's own list of valid values, drawn out by a
    // deliberately invalid POST, tops out at 6.7", so this is not a Bagbutik gap.
    var screenshotSets: [(dir: String, type: ScreenshotDisplayType)] {
        switch self {
        case .macos: return [(dir: "", type: .appDesktop)]
        case .ios: return [(dir: "iphone", type: .appIphone67),
                           (dir: "ipad", type: .appIpadPro3Gen129)]
        }
    }
}

struct Options {
    var keyId = ""
    var issuerId = ""
    var keyPath = ""
    var bundleId = ""
    var root = ""
    var locales: Set<String>? = nil
    var platform = TargetPlatform.macos
    var createVersion: String? = nil
    var dryRun = false
    var skipScreenshots = false
    var skipText = false

    static func parse() throws -> Options {
        var o = Options()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = args.next() else { throw Fail("\(flag) needs a value") }
            return v
        }
        while let a = args.next() {
            switch a {
            case "--key-id": o.keyId = try value(a)
            case "--issuer-id": o.issuerId = try value(a)
            case "--key-path": o.keyPath = try value(a)
            case "--bundle-id": o.bundleId = try value(a)
            case "--root": o.root = try value(a)
            case "--locales": o.locales = Set(try value(a).split(separator: ",").map(String.init))
            case "--platform":
                let raw = try value(a)
                guard let p = TargetPlatform(rawValue: raw) else {
                    throw Fail("--platform must be 'macos' or 'ios', not '\(raw)'")
                }
                o.platform = p
            case "--create-version": o.createVersion = try value(a)
            case "--dry-run": o.dryRun = true
            case "--skip-screenshots": o.skipScreenshots = true
            case "--skip-text": o.skipText = true
            default: throw Fail("unknown argument: \(a)")
            }
        }
        for (flag, v) in [("--key-id", o.keyId), ("--issuer-id", o.issuerId),
                          ("--key-path", o.keyPath), ("--bundle-id", o.bundleId),
                          ("--root", o.root)] where v.isEmpty {
            throw Fail("missing required \(flag)")
        }
        return o
    }
}

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

struct LocaleCopy {
    let language: String       // catalog code, e.g. "de"
    let locale: String         // ASC locale, e.g. "de-DE"
    let promotionalText: String
    let description: String
    let keywords: String
    let whatsNew: String
    let supportUrl: String     // shared across locales (copy/support-url.txt)
    let marketingUrl: String   // shared across locales (copy/marketing-url.txt)
    let privacyPolicyUrl: String  // shared (copy/privacy-url.txt); appInfo, not version
    // One entry per ASC screenshot set, each ordered by file name.
    let screenshotSets: [ScreenshotFiles]
}

func loadCopy(root: URL, options: Options) throws -> [LocaleCopy] {
    let fm = FileManager.default
    let copyDir = root.appendingPathComponent("copy")
    let platformDir = options.platform.rawValue
    // Only languages with copy FOR THIS PLATFORM; <lang>/ alone would admit
    // one that has only the other platform's copy.
    let languages = try fm.contentsOfDirectory(atPath: copyDir.path).sorted()
        .filter { fm.fileExists(atPath: copyDir.appendingPathComponent($0).path
                                    + "/\(platformDir)/description.txt") }

    // Shared by every locale. ASC requires a support URL on each localization,
    // or submission is blocked.
    func sharedURL(_ name: String) throws -> String {
        let url = try String(contentsOf: copyDir.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw Fail("copy/\(name) is empty") }
        return url
    }
    let supportUrl = try sharedURL("support-url.txt")
    let marketingUrl = try sharedURL("marketing-url.txt")
    let privacyPolicyUrl = try sharedURL("privacy-url.txt")

    var out: [LocaleCopy] = []
    for language in languages {
        if let wanted = options.locales, !wanted.contains(language) { continue }
        guard let mapped = ascLocale[language] else {
            throw Fail("no ASC locale mapping for catalog language '\(language)' — add it to ascLocale")
        }
        guard let locale = mapped else {
            print("skip \(language): the App Store has no product page in this language")
            continue
        }
        let dir = copyDir.appendingPathComponent(language).appendingPathComponent(platformDir)
        func field(_ name: String) throws -> String {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Fail("\(language): \(name) is empty") }
            return trimmed
        }
        var screenshotSets: [ScreenshotFiles] = []
        if !options.skipScreenshots {
            for set in options.platform.screenshotSets {
                var shotDir = root.appendingPathComponent("screenshots")
                    .appendingPathComponent(language).appendingPathComponent(platformDir)
                if !set.dir.isEmpty { shotDir = shotDir.appendingPathComponent(set.dir) }
                guard fm.fileExists(atPath: shotDir.path) else {
                    throw Fail("\(language): missing \(shotDir.path) — run `make appstore-generate-store-screenshots-all` (or pass --skip-screenshots)")
                }
                let files = try fm.contentsOfDirectory(atPath: shotDir.path).sorted()
                    .filter { $0.hasSuffix(".png") }
                    .map { shotDir.appendingPathComponent($0) }
                guard !files.isEmpty else { throw Fail("\(language): no .png in \(shotDir.path)") }
                screenshotSets.append((type: set.type, files: files))
            }
        }
        out.append(LocaleCopy(
            language: language, locale: locale,
            promotionalText: try field("promotional-text.txt"),
            description: try field("description.txt"),
            keywords: try field("keywords.txt"),
            whatsNew: try field("whats-new.txt"),
            supportUrl: supportUrl,
            marketingUrl: marketingUrl,
            privacyPolicyUrl: privacyPolicyUrl,
            screenshotSets: screenshotSets))
    }
    return out
}

@main
struct ASCUpload {
    static func main() async {
        do {
            try await run()
        } catch let error as ServiceError {
            FileHandle.standardError.write(Data("error: \(error.description ?? "\(error)")\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let options = try Options.parse()
        let root = URL(fileURLWithPath: options.root)
        let copies = try loadCopy(root: root, options: options)
        guard !copies.isEmpty else { throw Fail("no copy found for --platform \(options.platform.rawValue) — expected copy/<lang>/\(options.platform.rawValue)/") }

        let privateKey = try String(contentsOf: URL(fileURLWithPath: options.keyPath), encoding: .utf8)
        let service = try BagbutikService(jwt: JWT(
            keyId: options.keyId, issuerId: options.issuerId, privateKey: privateKey))

        let apps = try await service.request(.listAppsV1(
            filters: [.bundleId([options.bundleId])])).data
        guard let app = apps.first else { throw Fail("no app with bundle id \(options.bundleId)") }

        let versions = try await service.request(.listAppStoreVersionsForAppV1(
            id: app.id, filters: [.platform([options.platform.asc])], limits: [.limit(20)])).data
        let editable = versions.filter {
            guard let s = $0.attributes?.appVersionState else { return false }
            return editableStates.contains(s)
        }
        let version: AppStoreVersion
        switch (editable.count, options.createVersion) {
        case (1, nil):
            version = editable[0]
        case (1, .some(let v)):
            guard editable[0].attributes?.versionString == v else {
                throw Fail("--create-version \(v), but \(editable[0].attributes?.versionString ?? "?") is already editable")
            }
            version = editable[0]
        case (0, .some(let v)):
            print("creating version \(v)\(options.dryRun ? " [dry run]" : "")")
            if options.dryRun { throw Fail("dry run stops here — no version to inspect until \(v) is created") }
            version = try await service.request(.createAppStoreVersionV1(
                requestBody: AppStoreVersionCreateRequest(data: .init(
                    attributes: .init(platform: options.platform.asc, versionString: v),
                    relationships: .init(app: .init(data: .init(id: app.id))))))).data
        default:
            let states = versions.map { "\($0.attributes?.versionString ?? "?"): \($0.attributes?.appVersionState?.rawValue ?? "?")" }
            throw Fail("need exactly one editable \(options.platform.rawValue) version, found \(editable.count) — versions: \(states.joined(separator: ", ")). Pass --create-version <string> to create one.")
        }
        print("app \(options.bundleId), version \(version.attributes?.versionString ?? version.id) (\(version.attributes?.appVersionState?.rawValue ?? "?"))\(options.dryRun ? " [dry run]" : "")")

        // A platform's FIRST version takes no release notes: ASC answers
        // "Attribute 'whatsNew' cannot be edited at this time" and fails the
        // run. The version record does not say so; the only signal is that the
        // platform has no other version.
        let acceptsWhatsNew = versions.contains { $0.id != version.id }
        if !acceptsWhatsNew {
            print("note: \(options.platform.rawValue) has no earlier version, so App Store Connect "
                  + "does not accept release notes — whats-new.txt is not uploaded for this release")
        }

        let existing = try await service.request(.listAppStoreVersionLocalizationsForAppStoreVersionV1(
            id: version.id, limits: [.limit(50)])).data
        var byLocale = [String: AppStoreVersionLocalization]()
        for l in existing { if let loc = l.attributes?.locale { byLocale[loc] = l } }

        var changedSets: [ChangedSet] = []
        for copy in copies {
            changedSets += try await sync(copy, version: version, current: byLocale[copy.locale],
                                          acceptsWhatsNew: acceptsWhatsNew, service: service, options: options)
        }

        if !options.skipText {
            try await syncPrivacyPolicyUrl(appId: app.id, copies: copies,
                                           service: service, options: options)
        }
        try await settleScreenshots(changedSets, service: service, options: options)
        print(options.dryRun ? "dry run complete — nothing was uploaded" : "done")
    }

    /// The privacy policy URL lives on appInfoLocalizations, not the version,
    /// beside the app name and subtitle, which this tool leaves alone: a wrong
    /// one renames the app. Only existing localizations are patched, since
    /// creating one requires a `name`; a missing one is reported.
    static func syncPrivacyPolicyUrl(appId: String, copies: [LocaleCopy],
                                     service: BagbutikService, options: Options) async throws {
        guard let url = copies.first?.privacyPolicyUrl else { return }

        let infos = try await service.request(.listAppInfosForAppV1(
            id: appId, limits: [.limit(20)])).data
        let editable = infos.filter {
            guard let state = $0.attributes?.state else { return false }
            return editableAppInfoStates.contains(state)
        }
        guard editable.count == 1, let info = editable.first else {
            let states = infos.map { $0.attributes?.state?.rawValue ?? "?" }
            throw Fail("need exactly one editable appInfo for the privacy policy URL, found \(editable.count) — states: \(states.joined(separator: ", "))")
        }

        let localizations = try await service.request(
            .listAppInfoLocalizationsForAppInfoV1(id: info.id, limit: 50)).data
        var byLocale = [String: AppInfoLocalization]()
        for l in localizations { if let loc = l.attributes?.locale { byLocale[loc] = l } }

        var changed = 0, unchanged = 0
        var missing: [String] = []
        for copy in copies {
            guard let current = byLocale[copy.locale] else {
                missing.append(copy.locale)
                continue
            }
            if current.attributes?.privacyPolicyUrl == url {
                unchanged += 1
                continue
            }
            changed += 1
            print("\(copy.locale): privacy policy URL -> \(url)")
            if !options.dryRun {
                _ = try await service.request(.updateAppInfoLocalizationV1(
                    id: current.id,
                    requestBody: AppInfoLocalizationUpdateRequest(data: .init(
                        id: current.id,
                        attributes: .init(privacyPolicyUrl: url)))))
            }
        }
        print("privacy policy URL: \(changed) updated, \(unchanged) already correct")
        if !missing.isEmpty {
            print("warning: no appInfoLocalization for \(missing.joined(separator: ", ")) — "
                  + "set the app name for those locales in App Store Connect first")
        }
    }

    static func sync(_ copy: LocaleCopy, version: AppStoreVersion,
                     current: AppStoreVersionLocalization?, acceptsWhatsNew: Bool,
                     service: BagbutikService, options: Options) async throws -> [ChangedSet] {
        var localizationId = current?.id
        // nil omits the attribute entirely, which is what a first version
        // needs — sending it, even unchanged, is what ASC rejects.
        let whatsNew: String? = acceptsWhatsNew ? copy.whatsNew : nil

        if let current {
            let a = current.attributes
            let changed = !options.skipText &&
                (a?.promotionalText != copy.promotionalText ||
                 a?.description != copy.description ||
                 a?.keywords != copy.keywords ||
                 (acceptsWhatsNew && a?.whatsNew != copy.whatsNew) ||
                 a?.supportUrl != copy.supportUrl ||
                 a?.marketingUrl != copy.marketingUrl)
            if changed {
                print("\(copy.locale): updating text")
                if !options.dryRun {
                    _ = try await service.request(.updateAppStoreVersionLocalizationV1(
                        id: current.id,
                        requestBody: AppStoreVersionLocalizationUpdateRequest(data: .init(
                            id: current.id,
                            attributes: .init(
                                description: copy.description,
                                keywords: copy.keywords,
                                marketingUrl: copy.marketingUrl,
                                promotionalText: copy.promotionalText,
                                supportUrl: copy.supportUrl,
                                whatsNew: whatsNew)))))
                }
            } else if !options.skipText {
                print("\(copy.locale): text unchanged")
            }
        } else {
            print("\(copy.locale): creating localization")
            if options.dryRun {
                localizationId = nil
            } else {
                let created = try await service.request(.createAppStoreVersionLocalizationV1(
                    requestBody: AppStoreVersionLocalizationCreateRequest(data: .init(
                        attributes: .init(
                            description: copy.description,
                            keywords: copy.keywords,
                            locale: copy.locale,
                            marketingUrl: copy.marketingUrl,
                            promotionalText: copy.promotionalText,
                            supportUrl: copy.supportUrl,
                            whatsNew: whatsNew),
                        relationships: .init(appStoreVersion: .init(data: .init(id: version.id)))))))
                localizationId = created.data.id
            }
        }

        guard !options.skipScreenshots else { return [] }
        guard let localizationId else {
            for set in copy.screenshotSets {
                print("\(copy.locale): would upload \(set.files.count) \(set.type.rawValue) screenshots")
            }
            return []
        }
        var changed: [ChangedSet] = []
        for set in copy.screenshotSets {
            if let c = try await syncScreenshots(set, locale: copy.locale, localizationId: localizationId,
                                                 service: service, options: options) {
                changed.append(c)
            }
        }
        return changed
    }

    /// An unchanged set is left alone, so it is not exposed to the stall.
    /// Syncing a set again uploads only its unprocessed screenshots, which is
    /// the retry. Returns nil for an unchanged set and in a dry run.
    static func syncScreenshots(_ set: ScreenshotFiles, locale: String, localizationId: String,
                                service: BagbutikService, options: Options) async throws -> ChangedSet? {
        let label = "\(locale) \(set.type.rawValue)"
        let existing = try await service.request(.listAppScreenshotSetsForAppStoreVersionLocalizationV1(
            id: localizationId,
            filters: [.screenshotDisplayType([set.type])])).data.first
        var shots: [AppScreenshot] = []
        if let existing {
            shots = try await service.request(.listAppScreenshotsForAppScreenshotSetV1(
                id: existing.id, limit: 50)).data
        }

        var processed = shots.filter { $0.attributes?.assetDeliveryState?.state == .complete }
        var kept: [String?] = []
        for file in set.files {
            let checksum = md5Hex(try Data(contentsOf: file))
            let match = processed.firstIndex { $0.attributes?.sourceFileChecksum?.lowercased() == checksum }
            kept.append(match.map { processed.remove(at: $0).id })
        }
        if kept == shots.map({ $0.id }) {
            print("\(label): \(shots.count) screenshots unchanged")
            return nil
        }
        let stale = shots.filter { !kept.contains($0.id) }
        let uploads = kept.filter { $0 == nil }.count
        print("\(label): keeping \(set.files.count - uploads), uploading \(uploads), deleting \(stale.count)\(options.dryRun ? " [dry run]" : "")")
        if options.dryRun { return nil }

        let setId: String
        if let existing {
            setId = existing.id
        } else {
            setId = try await service.request(.createAppScreenshotSetV1(
                requestBody: AppScreenshotSetCreateRequest(data: .init(
                    attributes: .init(screenshotDisplayType: set.type),
                    relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationId))))))).data.id
        }
        // Deleted first: a set holds at most ten screenshots.
        for shot in stale {
            _ = try await service.request(.deleteAppScreenshotV1(id: shot.id))
        }
        var ids: [String] = []
        for (file, id) in zip(set.files, kept) {
            if let id {
                ids.append(id)
            } else {
                ids.append(try await upload(file, setId: setId, service: service))
            }
        }
        return (locale: locale, localizationId: localizationId, set: set, setId: setId, ids: ids)
    }

    /// Waits until every screenshot in `sets` is processed, then orders each
    /// set by file name. A set still waiting `screenshotStall` into a round is
    /// synced again.
    static func settleScreenshots(_ sets: [ChangedSet], service: BagbutikService,
                                  options: Options) async throws {
        guard !sets.isEmpty else { return }
        var sets = sets
        let total = sets.reduce(0) { $0 + $1.ids.count }
        var waiting = Array(sets.indices)
        var unprocessed: [URL] = []
        for round in 1 ... screenshotUploadRounds {
            let deadline = ContinuousClock.now + screenshotStall
            repeat {
                try await Task.sleep(for: screenshotPoll)
                var stillWaiting: [Int] = []
                unprocessed = []
                for s in waiting {
                    let shots = try await service.request(.listAppScreenshotsForAppScreenshotSetV1(
                        id: sets[s].setId, limit: 50)).data
                    let pending = try zip(sets[s].set.files, sets[s].ids).filter { file, id in
                        let delivery = shots.first { $0.id == id }?.attributes?.assetDeliveryState
                        if delivery?.state == .failed {
                            let errors = (delivery?.errors ?? []).map { "\($0.code ?? "?"): \($0.description ?? "")" }
                            throw Fail("\(file.path): App Store Connect could not process it — "
                                       + (errors.isEmpty ? "it gave no error" : errors.joined(separator: "; ")))
                        }
                        return delivery?.state != .complete
                    }
                    if !pending.isEmpty { stillWaiting.append(s) }
                    unprocessed += pending.map { $0.0 }
                }
                waiting = stillWaiting
                print("screenshots: \(total - unprocessed.count) of \(total) processed")
            } while !waiting.isEmpty && ContinuousClock.now < deadline
            if waiting.isEmpty { break }

            guard round < screenshotUploadRounds else {
                throw Fail("\(unprocessed.count) screenshots still unprocessed after \(round) rounds: "
                           + unprocessed.map(\.path).joined(separator: ", ")
                           + ". Run again: it keeps every processed screenshot and uploads only these.")
            }
            print("\(unprocessed.count) screenshots unprocessed after \(screenshotStall.components.seconds / 60) minutes. Syncing their sets again (round \(round + 1) of \(screenshotUploadRounds)).")
            for s in waiting {
                if let synced = try await syncScreenshots(sets[s].set, locale: sets[s].locale,
                                                          localizationId: sets[s].localizationId,
                                                          service: service, options: options) {
                    sets[s] = synced
                }
            }
        }
        for set in sets {
            _ = try await service.request(.replaceAppScreenshotsForAppScreenshotSetV1(
                id: set.setId,
                requestBody: AppScreenshotSetAppScreenshotsLinkagesRequest(
                    data: set.ids.map { .init(id: $0) })))
        }
        print("ordered \(sets.count) screenshot sets by file name")
    }

    /// Reserves, uploads and commits one screenshot, returning its id.
    static func upload(_ file: URL, setId: String,
                       service: BagbutikService) async throws -> String {
        let data = try Data(contentsOf: file)
        let reserved = try await service.request(.createAppScreenshotV1(
            requestBody: AppScreenshotCreateRequest(data: .init(
                attributes: .init(fileName: file.lastPathComponent, fileSize: data.count),
                relationships: .init(appScreenshotSet: .init(data: .init(id: setId)))))))

        guard let operations = reserved.data.attributes?.uploadOperations else {
            throw Fail("\(file.path): no upload operations returned")
        }
        for op in operations {
            guard let urlString = op.url, let url = URL(string: urlString),
                  let offset = op.offset, let length = op.length else {
                throw Fail("\(file.path): malformed upload operation")
            }
            var request = URLRequest(url: url)
            request.httpMethod = op.method ?? "PUT"
            for header in op.requestHeaders ?? [] {
                if let name = header.name, let value = header.value {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            let chunk = data.subdata(in: offset ..< offset + length)
            let (_, response) = try await URLSession.shared.upload(for: request, from: chunk)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                throw Fail("\(file.path): chunk upload failed (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
            }
        }

        _ = try await service.request(.updateAppScreenshotV1(
            id: reserved.data.id,
            requestBody: AppScreenshotUpdateRequest(data: .init(
                id: reserved.data.id,
                attributes: .init(sourceFileChecksum: md5Hex(data), uploaded: true)))))
        return reserved.data.id
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
