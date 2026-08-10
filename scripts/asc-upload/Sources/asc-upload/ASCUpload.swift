// Uploads the localized App Store product-page metadata — promotional text,
// description, keywords, what's new, the support URL, and screenshots — from
// Assets/app-store/ to App Store Connect. Copy format and tree layout:
// Assets/app-store/README.md. Run via scripts/appstore-upload-metadata.sh (or
// `make appstore-upload-metadata`), which resolves the shared API key.
//
// Targets the one editable macOS version (Prepare for Submission or a rejected
// state). Text fields are PATCHed only when they differ; screenshots replace
// the locale's APP_DESKTOP set wholesale, ordered by file name.

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
    "da": "da", "de": "de-DE", "en": "en-US", "es": "es-ES", "fi": "fi",
    "fr": "fr-FR", "hr": "hr", "it": "it", "ja": "ja", "ko": "ko",
    "nb": "no", "nl": "nl-NL", "pl": "pl", "pt-BR": "pt-BR", "pt-PT": "pt-PT",
    "ro": "ro", "ru": "ru", "sv": "sv", "tr": "tr", "uk": "uk",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
]

// States whose metadata App Store Connect still allows editing.
let editableStates: Set<AppVersionState> = [
    .prepareForSubmission, .developerRejected, .rejected, .metadataRejected,
    .invalidBinary, .readyForReview, .waitingForReview,
]

struct Options {
    var keyId = ""
    var issuerId = ""
    var keyPath = ""
    var bundleId = ""
    var root = ""
    var locales: Set<String>? = nil
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
    let screenshots: [URL]     // ordered
}

func loadCopy(root: URL, options: Options) throws -> [LocaleCopy] {
    let fm = FileManager.default
    let copyDir = root.appendingPathComponent("copy")
    let languages = try fm.contentsOfDirectory(atPath: copyDir.path).sorted()
        .filter { fm.fileExists(atPath: copyDir.appendingPathComponent($0).path + "/description.txt") }

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
        let dir = copyDir.appendingPathComponent(language)
        func field(_ name: String) throws -> String {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Fail("\(language): \(name) is empty") }
            return trimmed
        }
        var screenshots: [URL] = []
        if !options.skipScreenshots {
            let shotDir = root.appendingPathComponent("screenshots").appendingPathComponent(language)
            guard fm.fileExists(atPath: shotDir.path) else {
                throw Fail("\(language): missing \(shotDir.path) — run `make appstore-generate-store-screenshots-all` (or pass --skip-screenshots)")
            }
            screenshots = try fm.contentsOfDirectory(atPath: shotDir.path).sorted()
                .filter { $0.hasSuffix(".png") }
                .map { shotDir.appendingPathComponent($0) }
            guard !screenshots.isEmpty else { throw Fail("\(language): no .png in \(shotDir.path)") }
        }
        out.append(LocaleCopy(
            language: language, locale: locale,
            promotionalText: try field("promotional-text.txt"),
            description: try field("description.txt"),
            keywords: try field("keywords.txt"),
            whatsNew: try field("whats-new.txt"),
            supportUrl: supportUrl,
            marketingUrl: marketingUrl,
            screenshots: screenshots))
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
        guard !copies.isEmpty else { throw Fail("nothing to upload") }

        let privateKey = try String(contentsOf: URL(fileURLWithPath: options.keyPath), encoding: .utf8)
        let service = try BagbutikService(jwt: JWT(
            keyId: options.keyId, issuerId: options.issuerId, privateKey: privateKey))

        // App, then its one editable macOS version.
        let apps = try await service.request(.listAppsV1(
            filters: [.bundleId([options.bundleId])])).data
        guard let app = apps.first else { throw Fail("no app with bundle id \(options.bundleId)") }

        let versions = try await service.request(.listAppStoreVersionsForAppV1(
            id: app.id, filters: [.platform([.macOS])], limits: [.limit(20)])).data
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
                    attributes: .init(platform: .macOS, versionString: v),
                    relationships: .init(app: .init(data: .init(id: app.id))))))).data
        default:
            let states = versions.map { "\($0.attributes?.versionString ?? "?"): \($0.attributes?.appVersionState?.rawValue ?? "?")" }
            throw Fail("need exactly one editable macOS version, found \(editable.count) — versions: \(states.joined(separator: ", ")). Pass --create-version <string> to create one.")
        }
        print("app \(options.bundleId), version \(version.attributes?.versionString ?? version.id) (\(version.attributes?.appVersionState?.rawValue ?? "?"))\(options.dryRun ? " [dry run]" : "")")

        let existing = try await service.request(.listAppStoreVersionLocalizationsForAppStoreVersionV1(
            id: version.id, limits: [.limit(50)])).data
        var byLocale = [String: AppStoreVersionLocalization]()
        for l in existing { if let loc = l.attributes?.locale { byLocale[loc] = l } }

        for copy in copies {
            try await sync(copy, version: version, current: byLocale[copy.locale],
                           service: service, options: options)
        }
        print(options.dryRun ? "dry run complete — nothing was uploaded" : "done")
    }

    static func sync(_ copy: LocaleCopy, version: AppStoreVersion,
                     current: AppStoreVersionLocalization?,
                     service: BagbutikService, options: Options) async throws {
        var localizationId = current?.id

        if let current {
            let a = current.attributes
            let changed = !options.skipText &&
                (a?.promotionalText != copy.promotionalText ||
                 a?.description != copy.description ||
                 a?.keywords != copy.keywords ||
                 a?.whatsNew != copy.whatsNew ||
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
                                whatsNew: copy.whatsNew)))))
                }
            } else if !options.skipText {
                print("\(copy.locale): text unchanged")
            }
        } else {
            // whatsNew rides along here too; note ASC rejects it on an app's
            // first-ever version, where there is nothing to be new against.
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
                            whatsNew: copy.whatsNew),
                        relationships: .init(appStoreVersion: .init(data: .init(id: version.id)))))))
                localizationId = created.data.id
            }
        }

        guard !options.skipScreenshots else { return }
        guard let localizationId else {
            print("\(copy.locale): would upload \(copy.screenshots.count) screenshots")
            return
        }
        try await syncScreenshots(copy, localizationId: localizationId,
                                  service: service, options: options)
    }

    static func syncScreenshots(_ copy: LocaleCopy, localizationId: String,
                                service: BagbutikService, options: Options) async throws {
        let sets = try await service.request(.listAppScreenshotSetsForAppStoreVersionLocalizationV1(
            id: localizationId,
            filters: [.screenshotDisplayType([.appDesktop])])).data

        if options.dryRun {
            print("\(copy.locale): would replace APP_DESKTOP set with \(copy.screenshots.count) screenshots")
            return
        }

        let setId: String
        if let set = sets.first {
            setId = set.id
            let shots = try await service.request(.listAppScreenshotsForAppScreenshotSetV1(
                id: setId, limit: 50)).data
            for shot in shots {
                _ = try await service.request(.deleteAppScreenshotV1(id: shot.id))
            }
        } else {
            let created = try await service.request(.createAppScreenshotSetV1(
                requestBody: AppScreenshotSetCreateRequest(data: .init(
                    attributes: .init(screenshotDisplayType: .appDesktop),
                    relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationId)))))))
            setId = created.data.id
        }

        for file in copy.screenshots {
            try await upload(file, setId: setId, locale: copy.locale, service: service)
        }
        print("\(copy.locale): uploaded \(copy.screenshots.count) screenshots")
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
