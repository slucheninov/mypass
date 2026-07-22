import Foundation
import MyPassKit

enum CSVImportError: Error, Equatable {
    case missingRequiredColumn(String)
}

enum CSVImporter {
    private static let requiredColumns = ["title", "username", "password"]
    private static let columnAliases: [String: String] = [
        "title": "title",
        "url": "url",
        "username": "username",
        "password": "password",
        "notes": "notes"
    ]

    static func parse(csvData: Data) throws -> [KdbxEntry] {
        guard let text = String(data: csvData, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }

        let header = lines.removeFirst()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        for required in requiredColumns {
            guard header.contains(required) else {
                throw CSVImportError.missingRequiredColumn(required)
            }
        }

        var entries: [KdbxEntry] = []
        for line in lines {
            let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard values.count == header.count else { continue }

            let now = Date()
            var entry = KdbxEntry(
                uuid: UUID(),
                iconID: 0,
                fields: [],
                creationTime: now,
                lastModificationTime: now,
                lastAccessTime: now,
                locationChanged: now,
                history: []
            )

            for (column, value) in zip(header, values) {
                switch column {
                case "title": entry.title = value
                case "url": entry.url = value
                case "username": entry.login = value
                case "password": entry.password = value
                case "notes": entry.notes = value
                default: break // unknown columns are ignored, per design decision
                }
            }
            entries.append(entry)
        }
        return entries
    }
}
