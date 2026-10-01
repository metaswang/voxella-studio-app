import Foundation

struct AppUpdateRelease: Equatable, Sendable {
    var shortVersion: String
    var build: String
    var minimumSystemVersion: String?
    var downloadURL: URL
}

enum AppcastFeedError: LocalizedError, Equatable, Sendable {
    case malformed
    case empty

    var errorDescription: String? {
        switch self {
        case .malformed:
            "The update listing could not be read."
        case .empty:
            "The update listing did not include a download."
        }
    }
}

enum AppUpdateEvaluation: Equatable, Sendable {
    case upToDate
    case available(AppUpdateRelease)
    case unsupportedSystem(AppUpdateRelease)
}

struct AppcastFeed: Equatable, Sendable {
    var items: [AppUpdateRelease]

    static func parse(xml: Data) throws -> AppcastFeed {
        let parser = AppcastXMLParser()
        let items = try parser.parse(xml)
        guard !items.isEmpty else { throw AppcastFeedError.empty }
        return AppcastFeed(items: items)
    }

    func evaluation(
        currentBuild: String,
        currentShortVersion: String,
        operatingSystemVersion: OperatingSystemVersion
    ) -> AppUpdateEvaluation {
        guard let latest = latestItem() else { return .upToDate }
        guard isNewer(latest, thanBuild: currentBuild, shortVersion: currentShortVersion) else {
            return .upToDate
        }
        if let minimum = latest.minimumSystemVersion,
           !Self.osVersion(operatingSystemVersion, satisfies: minimum) {
            return .unsupportedSystem(latest)
        }
        return .available(latest)
    }

    func latestItem() -> AppUpdateRelease? {
        items.max { lhs, rhs in
            compareVersion(lhs.build, rhs.build) == .orderedAscending
        }
    }

    private func isNewer(
        _ release: AppUpdateRelease,
        thanBuild currentBuild: String,
        shortVersion currentShortVersion: String
    ) -> Bool {
        let buildOrdering = compareVersion(release.build, currentBuild)
        if buildOrdering != .orderedSame {
            return buildOrdering == .orderedDescending
        }
        return compareVersion(release.shortVersion, currentShortVersion) == .orderedDescending
    }

    static func osVersion(_ version: OperatingSystemVersion, satisfies minimum: String) -> Bool {
        compareVersion(
            "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            minimum
        ) != .orderedAscending
    }
}

func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = versionComponents(lhs)
    let right = versionComponents(rhs)
    let count = max(left.count, right.count)
    for index in 0..<count {
        let leftValue = index < left.count ? left[index] : 0
        let rightValue = index < right.count ? right[index] : 0
        if leftValue != rightValue {
            return leftValue < rightValue ? .orderedAscending : .orderedDescending
        }
    }
    return .orderedSame
}

private func versionComponents(_ value: String) -> [Int] {
    value.split { $0 == "." || $0 == "-" }.compactMap { Int($0.filter(\.isNumber)) }
}

private final class AppcastXMLParser: NSObject, XMLParserDelegate {
    private var items: [AppUpdateRelease] = []
    private var currentBuild: String?
    private var currentShortVersion: String?
    private var currentMinimum: String?
    private var currentURL: String?
    private var currentElement = ""
    private var text = ""
    private var parseError: AppcastFeedError?

    func parse(_ data: Data) throws -> [AppUpdateRelease] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), parseError == nil else {
            throw parseError ?? AppcastFeedError.malformed
        }
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
        if elementName == "item" {
            currentBuild = nil
            currentShortVersion = nil
            currentMinimum = nil
            currentURL = nil
        }
        if elementName == "enclosure" {
            currentURL = attributeDict["url"]
        }
        if elementName == "version"
            || elementName.hasSuffix(":version")
            || elementName == "sparkle:version" {
            currentElement = "sparkle:version"
        } else if elementName == "shortVersionString"
            || elementName.hasSuffix(":shortVersionString")
            || elementName == "sparkle:shortVersionString" {
            currentElement = "sparkle:shortVersionString"
        } else if elementName == "minimumSystemVersion"
            || elementName.hasSuffix(":minimumSystemVersion")
            || elementName == "sparkle:minimumSystemVersion" {
            currentElement = "sparkle:minimumSystemVersion"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch currentElement {
        case "sparkle:version":
            if !value.isEmpty { currentBuild = value }
        case "sparkle:shortVersionString":
            if !value.isEmpty { currentShortVersion = value }
        case "sparkle:minimumSystemVersion":
            if !value.isEmpty { currentMinimum = value }
        default:
            break
        }
        if elementName == "item" {
            if let build = currentBuild,
               let shortVersion = currentShortVersion,
               let urlString = currentURL,
               let url = URL(string: urlString) {
                items.append(
                    AppUpdateRelease(
                        shortVersion: shortVersion,
                        build: build,
                        minimumSystemVersion: currentMinimum,
                        downloadURL: url
                    )
                )
            }
        }
        currentElement = ""
        text = ""
    }
}
