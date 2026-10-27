import XCTest
@testable import MyPass

/// Guards the string catalogs (`MyPass/Resources/Localizable.xcstrings`,
/// `InfoPlist.xcstrings`). The catalogs are the single source of truth for the Ukrainian and
/// Russian interface, and Xcode adds every newly found literal to `Localizable.xcstrings` as
/// untranslated on the next build. These tests turn "someone added a UI string and forgot the
/// translations" into a failing test instead of a half-English screen.
///
/// The catalogs are read straight from the source tree (located through `#filePath`) because
/// the built app only carries compiled `.strings` / `.stringsdict`, not the catalog JSON. The
/// last test checks the built bundle itself, so a project that stops emitting `uk.lproj` /
/// `ru.lproj` also fails here.
final class LocalizationCatalogTests: XCTestCase {
    private typealias JSON = [String: Any]

    private static let requiredLanguages = ["uk", "ru"]

    /// CLDR plural categories each language needs. English has no `few` / `many`; Ukrainian and
    /// Russian need all four.
    private static let requiredPluralCategories: [String: Set<String>] = [
        "en": ["one", "other"],
        "uk": ["one", "few", "many", "other"],
        "ru": ["one", "few", "many", "other"],
    ]

    // MARK: - Loading

    private static var resourcesDirectory: URL {
        // MyPassTests/LocalizationCatalogTests.swift -> repo root -> MyPass/Resources
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MyPass/Resources", isDirectory: true)
    }

    private func loadCatalog(_ name: String) throws -> JSON {
        let url = Self.resourcesDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? JSON, "\(name) is not a JSON object")
    }

    private func strings(of catalog: JSON) -> [String: JSON] {
        (catalog["strings"] as? [String: JSON]) ?? [:]
    }

    private func isTranslatable(_ entry: JSON) -> Bool {
        (entry["shouldTranslate"] as? Bool) ?? true
    }

    private func localization(_ language: String, in entry: JSON) -> JSON? {
        (entry["localizations"] as? JSON)?[language] as? JSON
    }

    /// Every `stringUnit` reachable from a localization: the plain one, plural / device
    /// variations, and `substitutions` (which can themselves carry plural variations).
    private func stringUnits(in node: Any) -> [JSON] {
        guard let dict = node as? JSON else { return [] }
        var units: [JSON] = []
        for (key, value) in dict {
            if key == "stringUnit", let unit = value as? JSON {
                units.append(unit)
            } else {
                units.append(contentsOf: stringUnits(in: value))
            }
        }
        return units
    }

    private func pluralCategories(in localization: JSON) -> Set<String>? {
        guard let variations = localization["variations"] as? JSON,
              let plural = variations["plural"] as? JSON else { return nil }
        return Set(plural.keys)
    }

    // MARK: - Tests

    func testEveryTranslatableKeyHasTranslatedUkrainianAndRussian() throws {
        var offenders: [String] = []
        for (key, entry) in strings(of: try loadCatalog("Localizable.xcstrings")) where isTranslatable(entry) {
            for language in Self.requiredLanguages {
                guard let loc = localization(language, in: entry) else {
                    offenders.append("\(language): \(key) (missing)")
                    continue
                }
                let units = stringUnits(in: loc)
                if units.isEmpty {
                    offenders.append("\(language): \(key) (no string unit)")
                } else if let bad = units.first(where: { ($0["state"] as? String) != "translated" }) {
                    offenders.append("\(language): \(key) (state \(bad["state"] as? String ?? "nil"))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Untranslated keys:\n" + offenders.sorted().joined(separator: "\n"))
    }

    func testNoStaleKeys() throws {
        let stale = strings(of: try loadCatalog("Localizable.xcstrings"))
            .filter { ($0.value["extractionState"] as? String) == "stale" }
            .map(\.key)
            .sorted()
        XCTAssertTrue(stale.isEmpty, "Stale keys (delete them from the catalog):\n" + stale.joined(separator: "\n"))
    }

    func testPluralKeysDeclareTheRequiredCategories() throws {
        var offenders: [String] = []
        for (key, entry) in strings(of: try loadCatalog("Localizable.xcstrings")) {
            for (language, required) in Self.requiredPluralCategories {
                guard let loc = localization(language, in: entry),
                      let categories = pluralCategories(in: loc) else { continue }
                let missing = required.subtracting(categories)
                if !missing.isEmpty {
                    offenders.append("\(language): \(key) is missing \(missing.sorted().joined(separator: ", "))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Incomplete plural variations:\n" + offenders.sorted().joined(separator: "\n"))
    }

    func testPlaceholdersMatchAcrossLanguages() throws {
        var offenders: [String] = []
        for (key, entry) in strings(of: try loadCatalog("Localizable.xcstrings")) where isTranslatable(entry) {
            let expected = Self.placeholders(in: key)
            for language in Self.requiredLanguages {
                guard let loc = localization(language, in: entry) else { continue }
                for unit in stringUnits(in: loc) {
                    guard let value = unit["value"] as? String else { continue }
                    let actual = Self.placeholders(in: value)
                    if actual != expected {
                        offenders.append("\(language): \(key) expected \(expected) but found \(actual) in \"\(value)\"")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Placeholder mismatches:\n" + offenders.sorted().joined(separator: "\n"))
    }

    func testInfoPlistCatalogTranslatesTheTouchIDDescription() throws {
        let catalog = try loadCatalog("InfoPlist.xcstrings")
        let entry = try XCTUnwrap(strings(of: catalog)["NSFaceIDUsageDescription"], "NSFaceIDUsageDescription is missing")
        for language in Self.requiredLanguages {
            let loc = try XCTUnwrap(localization(language, in: entry), "\(language) is missing")
            let units = stringUnits(in: loc)
            XCTAssertFalse(units.isEmpty, "\(language) has no string unit")
            for unit in units {
                XCTAssertEqual(unit["state"] as? String, "translated", "\(language) is not translated")
                XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, "\(language) is empty")
            }
        }
    }

    func testBuiltBundleContainsUkrainianAndRussianResources() throws {
        for language in Self.requiredLanguages {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "\(language).lproj is missing from the built app"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["Settings…", "Lock", "Unlock"] {
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: nil)
                XCTAssertNotEqual(value, "__missing__", "\(language): \"\(key)\" is not in the built bundle")
                XCTAssertNotEqual(value, key, "\(language): \"\(key)\" is still English in the built bundle")
            }
        }
    }

    // MARK: - Placeholder parsing

    /// Format specifiers of a string as a sorted list (a multiset). The positional prefix
    /// (`%1$`) is dropped so a translation may reorder arguments; `%%` is a literal percent
    /// sign and is not a specifier.
    private static func placeholders(in string: String) -> [String] {
        let stripped = string.replacingOccurrences(of: "%%", with: "")
        let pattern = #"%(?:\d+\$)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfFeEgGsScCpi]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.matches(in: stripped, range: range)
            .compactMap { Range($0.range, in: stripped).map { String(stripped[$0]) } }
            .map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .sorted()
    }
}
