import Foundation

struct ProjectIconResolver: Sendable {
    private struct ResolvedIcon {
        let url: URL
        let projectRelevance: Int
        let renditionScore: Double
    }

    private struct AssetCatalog: Decodable {
        struct Entry: Decodable {
            let filename: String?
            let size: String?
            let scale: String?
        }

        let images: [Entry]
    }

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules",
        "Pods", "Carthage", "vendor", "dist", ".next", "xcuserdata"
    ]

    func iconURL(for projectURL: URL) -> URL? {
        let projectURL = projectURL.standardizedFileURL
        let configuredNames = configuredIconNames(in: projectURL)
        let iconSets = appIconSets(in: projectURL)
        let configuredSets = iconSets.filter {
            configuredNames.contains($0.deletingPathExtension().lastPathComponent)
        }
        if let icon = bestIcon(in: configuredSets, projectURL: projectURL) { return icon }

        let conventionalSets = iconSets.filter {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare("AppIcon") == .orderedSame
        }
        return bestIcon(in: conventionalSets.isEmpty ? iconSets : conventionalSets, projectURL: projectURL)
    }

    private func bestIcon(in iconSets: [URL], projectURL: URL) -> URL? {
        iconSets.compactMap { iconSet -> ResolvedIcon? in
            guard let data = try? Data(contentsOf: iconSet.appending(path: "Contents.json")),
                  let catalog = try? JSONDecoder().decode(AssetCatalog.self, from: data),
                  let rendition = catalog.images
                    .compactMap({ entry -> (url: URL, score: Double)? in
                        guard let filename = entry.filename else { return nil }
                        let url = iconSet.appending(path: filename)
                        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        return (url, renditionScore(size: entry.size, scale: entry.scale, url: url))
                    })
                    .max(by: { $0.score < $1.score }) else { return nil }
            return ResolvedIcon(
                url: rendition.url,
                projectRelevance: projectRelevance(of: iconSet, to: projectURL),
                renditionScore: rendition.score
            )
        }
        .max { lhs, rhs in
            if lhs.projectRelevance != rhs.projectRelevance {
                return lhs.projectRelevance < rhs.projectRelevance
            }
            return lhs.renditionScore < rhs.renditionScore
        }?
        .url
    }

    private func configuredIconNames(in projectURL: URL) -> Set<String> {
        let expression = try? NSRegularExpression(
            pattern: #"ASSETCATALOG_COMPILER_APPICON_NAME\s*=\s*\"?([^;\"\n]+)\"?\s*;"#
        )
        guard let expression else { return [] }

        var names: Set<String> = []
        for pbxProject in projectFiles(in: projectURL) {
            guard let source = try? String(contentsOf: pbxProject, encoding: .utf8) else { continue }
            let nsSource = source as NSString
            for match in expression.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
                let name = nsSource.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !name.contains("$(") { names.insert(name) }
            }
        }
        return names
    }

    private func projectFiles(in rootURL: URL) -> [URL] {
        enumeratedURLs(in: rootURL) { url, isDirectory, enumerator in
            if isDirectory, url.pathExtension == "xcodeproj" {
                enumerator.skipDescendants()
                return url.appending(path: "project.pbxproj")
            }
            return nil
        }
    }

    private func appIconSets(in rootURL: URL) -> [URL] {
        enumeratedURLs(in: rootURL) { url, isDirectory, enumerator in
            guard isDirectory, url.pathExtension == "appiconset" else { return nil }
            enumerator.skipDescendants()
            return url
        }
    }

    private func enumeratedURLs(
        in rootURL: URL,
        match: (URL, Bool, FileManager.DirectoryEnumerator) -> URL?
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            let isDirectory = values?.isDirectory == true
            if isDirectory,
               (Self.ignoredDirectories.contains(url.lastPathComponent) || values?.isHidden == true) {
                enumerator.skipDescendants()
                continue
            }
            if let result = match(url, isDirectory, enumerator) { matches.append(result) }
        }
        return matches
    }

    private func renditionScore(size: String?, scale: String?, url: URL) -> Double {
        let points: Double
        if let size, let firstDimension = size.split(separator: "x").first {
            points = Double(String(firstDimension)) ?? 0
        } else {
            points = 0
        }
        let multiplier: Double
        if let scale {
            multiplier = Double(scale.trimmingCharacters(in: CharacterSet(charactersIn: "x"))) ?? 1
        } else {
            multiplier = 1
        }
        let declaredPixels = points * multiplier
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        return declaredPixels * 1_000_000 + fileSize
    }

    private func projectRelevance(of iconSet: URL, to projectURL: URL) -> Int {
        let identity = normalizedProjectName(projectURL.lastPathComponent)
        guard !identity.isEmpty else { return 0 }
        let rootDepth = projectURL.pathComponents.count
        let relativeComponents = iconSet.pathComponents.dropFirst(rootDepth)
        let matchingComponents = relativeComponents.lazy
            .map(normalizedProjectName)
            .filter { $0 == identity }
            .count
        // Prefer a source folder named for the selected project. Shallower assets
        // break ties and avoid incidental icons in nested sample projects.
        return matchingComponents * 1_000 - relativeComponents.count
    }

    private func normalizedProjectName(_ name: String) -> String {
        var result = name.lowercased().filter(\.isLetter)
        for suffix in ["macos", "ios", "mac", "app"] where result.hasSuffix(suffix) {
            let shortened = result.dropLast(suffix.count)
            if shortened.count >= 3 { result = String(shortened) }
            break
        }
        return result
    }
}
