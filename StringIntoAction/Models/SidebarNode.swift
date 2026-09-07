import Foundation

struct SidebarNode: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        case folder
        case file
        case string
    }

    let id: String
    let title: String
    let kind: Kind
    let children: [SidebarNode]?
    let occurrence: StringOccurrence?
    let language: StringOccurrence.Language?
    let stringCount: Int
}

enum SidebarTreeBuilder {
    static func build(from occurrences: [StringOccurrence]) -> [SidebarNode] {
        let root = MutableFolder(name: "", path: "")

        for occurrence in occurrences {
            let components = occurrence.relativePath.split(separator: "/").map(String.init)
            guard let fileName = components.last else { continue }
            var folder = root
            for name in components.dropLast() {
                let path = folder.path.isEmpty ? name : "\(folder.path)/\(name)"
                if let existing = folder.folders[name] {
                    folder = existing
                } else {
                    let child = MutableFolder(name: name, path: path)
                    folder.folders[name] = child
                    folder = child
                }
            }
            folder.files[fileName, default: []].append(occurrence)
        }

        return root.nodes()
    }

    private final class MutableFolder {
        let name: String
        let path: String
        var folders: [String: MutableFolder] = [:]
        var files: [String: [StringOccurrence]] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func nodes() -> [SidebarNode] {
            let folderNodes = folders.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { folder -> SidebarNode in
                    let children = folder.nodes()
                    return SidebarNode(
                        id: "folder:\(folder.path)",
                        title: folder.name,
                        kind: .folder,
                        children: children,
                        occurrence: nil,
                        language: nil,
                        stringCount: children.reduce(0) { $0 + $1.stringCount }
                    )
                }

            let fileNodes = files
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { fileName, occurrences -> SidebarNode in
                    let sorted = occurrences.sorted { $0.line < $1.line }
                    let children = sorted.map { occurrence in
                        SidebarNode(
                            id: "string:\(occurrence.id)",
                            title: occurrence.summary,
                            kind: .string,
                            children: nil,
                            occurrence: occurrence,
                            language: occurrence.language,
                            stringCount: 1
                        )
                    }
                    let relativePath = sorted.first?.relativePath ?? fileName
                    return SidebarNode(
                        id: "file:\(relativePath)",
                        title: fileName,
                        kind: .file,
                        children: children,
                        occurrence: nil,
                        language: sorted.first?.language,
                        stringCount: children.count
                    )
                }

            return folderNodes + fileNodes
        }
    }
}
