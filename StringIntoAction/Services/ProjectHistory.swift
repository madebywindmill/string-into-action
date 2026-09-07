import Foundation

struct ProjectHistory {
    private static let lastProjectKey = "lastProjectPath"
    private static let projectPathsKey = "rememberedProjectPaths"
    private static let projectsSidebarKey = "showsProjectsSidebar"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var projectURLs: [URL] {
        var paths = defaults.stringArray(forKey: Self.projectPathsKey) ?? []

        // Migrate installs that only remembered the most recently opened project.
        if let lastPath = defaults.string(forKey: Self.lastProjectKey), !paths.contains(lastPath) {
            paths.append(lastPath)
        }

        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url
        }
    }

    var lastProjectURL: URL? {
        get {
            guard let path = defaults.string(forKey: Self.lastProjectKey) else {
                return projectURLs.last
            }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return projectURLs.contains(url) ? url : projectURLs.last
        }
        nonmutating set {
            defaults.set(newValue?.standardizedFileURL.path, forKey: Self.lastProjectKey)
        }
    }

    var showsProjectsSidebar: Bool {
        get {
            guard defaults.object(forKey: Self.projectsSidebarKey) != nil else { return true }
            return defaults.bool(forKey: Self.projectsSidebarKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.projectsSidebarKey)
        }
    }

    func remember(_ projectURL: URL) {
        let url = projectURL.standardizedFileURL
        var paths = projectURLs.map(\.path)
        if !paths.contains(url.path) { paths.append(url.path) }
        defaults.set(paths, forKey: Self.projectPathsKey)
        defaults.set(url.path, forKey: Self.lastProjectKey)
    }

    func forget(_ projectURL: URL) {
        let path = projectURL.standardizedFileURL.path
        let paths = projectURLs.map(\.path).filter { $0 != path }
        defaults.set(paths, forKey: Self.projectPathsKey)
        if defaults.string(forKey: Self.lastProjectKey) == path {
            defaults.set(paths.last, forKey: Self.lastProjectKey)
        }
    }

    func setProjectOrder(_ projectURLs: [URL]) {
        defaults.set(projectURLs.map { $0.standardizedFileURL.path }, forKey: Self.projectPathsKey)
    }
}
