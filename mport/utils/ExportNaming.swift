//
//  ExportNaming.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  Keeps one collection's export file from silently replacing another's: on a disk that doesn't tell upper and
//  lower case apart (the macOS default), `Users.bson` and `users.bson` are the same file.
//

import Foundation

/// Groups of names that differ only by letter case, in the order they first appear. Every file in one export has
/// the same extension, so comparing the names is enough.
func caseClashes(in names: [String]) -> [[String]] {
    var groupForKey: [String: Int] = [:]
    var groups: [[String]] = []
    for name in names {
        let key = name.lowercased()
        if let group = groupForKey[key] {
            groups[group].append(name)
        } else {
            groupForKey[key] = groups.count
            groups.append([name])
        }
    }
    return groups.filter { $0.count > 1 }
}

/// Whether the volume `directory` is on tells `Users` and `users` apart. The export directory may not exist yet, so
/// this checks the nearest folder above it that does. When the answer is unknown, it's `false`, which only ever
/// makes `export` more careful.
func isCaseSensitiveVolume(at directory: URL) -> Bool {
    var candidate = directory.absoluteURL.standardizedFileURL
    while !FileManager.default.fileExists(atPath: candidate.path) {
        let parent = candidate.deletingLastPathComponent()
        guard parent.path != candidate.path else {
            return false
        }
        candidate = parent
    }
    let values = try? candidate.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values?.volumeSupportsCaseSensitiveNames ?? false
}

/// Thrown before anything is written when selected collections would overwrite each other's export file.
struct ExportNameClashError: Error, CustomStringConvertible {
    let groups: [[String]]

    var description: String {
        let clashes = groups.map { group in
            group.map { "'\($0)'" }.joined(separator: " and ")
        }
        return """
        These collections would overwrite each other's export file, because this disk doesn't tell upper and \
        lower case apart: \(clashes.joined(separator: "; ")). Nothing was exported. \
        Export them in separate runs to different directories.
        """
    }
}
