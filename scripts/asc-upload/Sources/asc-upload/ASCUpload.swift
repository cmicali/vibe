// Uploads the localized App Store product-page metadata — promotional text,
// description, keywords, what's new, the support URL, and screenshots — from
// Assets/app-store/ to App Store Connect. Copy format and tree layout:
// Assets/app-store/README.md. Run via scripts/appstore-upload-metadata.sh (or
// `make appstore-upload-metadata`), which resolves the shared API key.
//
// Targets the one editable version on ONE platform — --platform macos (the
// default) or ios — since ASC localizations hang off a version and versions are
// per platform. Both apps share a bundle id (Universal Purchase), so the two
// platforms are separate version trains on the same app record and upload
// independently. Text fields are PATCHed only when they differ; each screenshot
// set is replaced wholesale, ordered by file name. macOS has one set per
// locale, iOS two (iPhone and iPad are separate sets, not two sizes of one).

import BagbutikAppStore
import BagbutikAppStoreModels
import BagbutikCore
import CryptoKit
import Foundation

// Catalog language → App Store Connect locale. The App Store has no Bulgarian
// product page, so `bg` maps to nil and is skipped with a warning; the catalog
// stays the source of which languages exist (CLAUDE.md).
let ascLocale: [String: String?] = [
    "bg": nil,
    "cs": "cs", "da": "da", "de": "de-DE", "el": "el", "en": "en-US",
    "es": "es-ES", "fi": "fi", "fr": "fr-FR", "hr": "hr", "hu": "hu",
    "id": "id", "it": "it", "ja": "ja", "ko": "ko",
    "nb": "no", "nl": "nl-NL", "pl": "pl", "pt-BR": "pt-BR", "pt-PT": "pt-PT",
    "ro": "ro", "ru": "ru", "sk": "sk", "sv": "sv", "th": "th", "tr": "tr",
    "uk": "uk", "vi": "vi", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
]

// The AppInfo carrying the privacy policy URL has its own state enum, so the
// editable set has to be spelled twice. An app normally has two AppInfos: the
// live one (READY_FOR_DISTRIBUTION) and the one being prepared.
let editableAppInfoStates: Set<AppInfo.Attributes.State> = [
    .prepareForSubmission, .developerRejected, .rejected,
    .readyForReview, .waitingForReview,
]

// States whose metadata App Store Connect still allows editing.
let editableStates: Set<AppVersionState> = [
    .prepareForSubmission, .developerRejected, .rejected, .metadataRejected,
    .invalidBinary, .readyForReview, .waitingForReview,
]

// Which version train to write to, and where its copy lives on disk.
// copy/<lang>/<platform>/ exists because every file under it is an ASC
// *version* field, and versions are per platform.
enum TargetPlatform: String {
    case macos, ios

    var asc: Platform { self == .macos ? .macOS : .iOS }

    // The ASC screenshot sets this platform ships, and the subdirectory of
    // screenshots/<lang>/<platform>/ each one's files come from. macOS has a
    // single set and keeps its flat directory; iOS has two, because iPhone
    // and iPad are separate sets rather than two sizes of one, and the iPad
    // set is REQUIRED — TARGETED_DEVICE_FAMILY is 1,2.
    //
    // APP_IPHONE_69 does not exist: a deliberately invalid POST made ASC
    // enumerate its valid values, and 6.7" is still the largest iPhone type.
    // Do not "fix" this by bumping Bagbutik — 24.0.3 is upstream's latest and
    // has no such case either.
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
    let screenshotSets: [(type: ScreenshotDisplayType, files: [URL])]
}

func loadCopy(root: URL, options: Options) throws -> [LocaleCopy] {
    let fm = FileManager.default
    let copyDir = root.appendingPathComponent("copy")
    let platformDir = options.platform.rawValue
    // A language is one whose copy exists FOR THIS PLATFORM. Listing by
    // <lang>/ alone would pick up languages that only have the other
    // platform's copy and fail later, one field at a time.
    let languages = try fm.contentsOfDirectory(atPath: copyDir.path).sorted()
        .filter { fm.fileExists(atPath: copyDir.appendingPathComponent($0).path
                                    + "/\(platformDir)/description.txt") }

    // One support and one marketing URL for every locale. ASC requires the
    // support URL per localization — a localization created without one blocks
    // submission; the marketing URL is optional but kept uniform the same way.
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
        var screenshotSets: [(type: ScreenshotDisplayType, files: [URL])] = []
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

        // App, then its one editable version ON THE TARGET PLATFORM.
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

        // Release notes are not a field on a platform's FIRST version: App
        // Store Connect answers "Attribute 'whatsNew' cannot be edited at this
        // time", and it fails the whole run on the first locale. Nothing about
        // the version record says so — the only signal is that the platform
        // has no other version — so it is derived here rather than discovered
        // 30 locales in. Vibe hit this shipping iOS for the first time against
        // a mature macOS train, where the same version string had notes and
        // the new platform could not.
        let acceptsWhatsNew = versions.contains { $0.id != version.id }
        if !acceptsWhatsNew {
            print("note: \(options.platform.rawValue) has no earlier version, so App Store Connect "
                  + "does not accept release notes — whats-new.txt is not uploaded for this release")
        }

        let existing = try await service.request(.listAppStoreVersionLocalizationsForAppStoreVersionV1(
            id: version.id, limits: [.limit(50)])).data
        var byLocale = [String: AppStoreVersionLocalization]()
        for l in existing { if let loc = l.attributes?.locale { byLocale[loc] = l } }

        for copy in copies {
            try await sync(copy, version: version, current: byLocale[copy.locale],
                           acceptsWhatsNew: acceptsWhatsNew, service: service, options: options)
        }

        if !options.skipText {
            try await syncPrivacyPolicyUrl(appId: app.id, copies: copies,
                                           service: service, options: options)
        }
        print(options.dryRun ? "dry run complete — nothing was uploaded" : "done")
    }

    /// The privacy policy URL is the one product-page field that does not live
    /// on the version. It sits on appInfoLocalizations, per locale, beside the
    /// app name and subtitle — which this tool still leaves alone, because they
    /// rarely change and getting them wrong renames the app. The URL is
    /// different: it is the same string in every locale, so setting it by hand
    /// means the same edit 29 times in App Store Connect.
    ///
    /// Only existing localizations are patched. Creating one requires a `name`,
    /// and inventing an app name per locale is exactly the mistake the
    /// out-of-scope rule exists to prevent — a locale with no appInfoLocalization
    /// is reported instead.
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
                     service: BagbutikService, options: Options) async throws {
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

        guard !options.skipScreenshots else { return }
        guard let localizationId else {
            for set in copy.screenshotSets {
                print("\(copy.locale): would upload \(set.files.count) \(set.type.rawValue) screenshots")
            }
            return
        }
        for set in copy.screenshotSets {
            try await syncScreenshots(copy, set: set, localizationId: localizationId,
                                      service: service, options: options)
        }
    }

    static func syncScreenshots(_ copy: LocaleCopy,
                                set: (type: ScreenshotDisplayType, files: [URL]),
                                localizationId: String,
                                service: BagbutikService, options: Options) async throws {
        let displayType = set.type
        let sets = try await service.request(.listAppScreenshotSetsForAppStoreVersionLocalizationV1(
            id: localizationId,
            filters: [.screenshotDisplayType([displayType])])).data

        if options.dryRun {
            print("\(copy.locale): would replace \(displayType.rawValue) set with \(set.files.count) screenshots")
            return
        }

        let setId: String
        if let existing = sets.first {
            setId = existing.id
            let shots = try await service.request(.listAppScreenshotsForAppScreenshotSetV1(
                id: setId, limit: 50)).data
            for shot in shots {
                _ = try await service.request(.deleteAppScreenshotV1(id: shot.id))
            }
        } else {
            let created = try await service.request(.createAppScreenshotSetV1(
                requestBody: AppScreenshotSetCreateRequest(data: .init(
                    attributes: .init(screenshotDisplayType: displayType),
                    relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationId)))))))
            setId = created.data.id
        }

        for file in set.files {
            try await upload(file, setId: setId, locale: copy.locale, service: service)
        }
        print("\(copy.locale): uploaded \(set.files.count) \(displayType.rawValue) screenshots")
    }

    static func upload(_ file: URL, setId: String, locale: String,
                       service: BagbutikService) async throws {
        let data = try Data(contentsOf: file)
        let reserved = try await service.request(.createAppScreenshotV1(
            requestBody: AppScreenshotCreateRequest(data: .init(
                attributes: .init(fileName: file.lastPathComponent, fileSize: data.count),
                relationships: .init(appScreenshotSet: .init(data: .init(id: setId)))))))

        guard let operations = reserved.data.attributes?.uploadOperations else {
            throw Fail("\(locale)/\(file.lastPathComponent): no upload operations returned")
        }
        for op in operations {
            guard let urlString = op.url, let url = URL(string: urlString),
                  let offset = op.offset, let length = op.length else {
                throw Fail("\(locale)/\(file.lastPathComponent): malformed upload operation")
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
                throw Fail("\(locale)/\(file.lastPathComponent): chunk upload failed (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
            }
        }

        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        _ = try await service.request(.updateAppScreenshotV1(
            id: reserved.data.id,
            requestBody: AppScreenshotUpdateRequest(data: .init(
                id: reserved.data.id,
                attributes: .init(sourceFileChecksum: md5, uploaded: true)))))
    }
}
