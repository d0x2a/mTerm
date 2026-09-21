import Foundation

package struct SavedTab: Codable {
    package let cwd: String?
    /// Profile the tab was opened with, as a uuid string. Absent for a tab
    /// opened with plain ⌘T, and for every tab written before profiles
    /// existed — both of which restore onto the current default.
    package let profileId: String?

    package init(cwd: String?, profileId: String? = nil) {
        self.cwd = cwd
        self.profileId = profileId
    }

    private enum CodingKeys: String, CodingKey {
        case cwd, profileId
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
    }
}

package struct SavedRect: Codable {
    package let x: Double
    package let y: Double
    package let width: Double
    package let height: Double

    // Spelled out because a synthesized memberwise init is internal and can't
    // be reached from MTermApp, which is the only thing that builds one.
    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct SavedState: Codable {
    package let tabs: [SavedTab]
    package let isFullScreen: Bool
    package let windowFrame: SavedRect?

    package init(tabs: [SavedTab],
         isFullScreen: Bool = false,
         windowFrame: SavedRect? = nil) {
        self.tabs = tabs
        self.isFullScreen = isFullScreen
        self.windowFrame = windowFrame
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, isFullScreen, windowFrame
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tabs = try c.decodeIfPresent([SavedTab].self, forKey: .tabs) ?? []
        self.isFullScreen = try c.decodeIfPresent(Bool.self, forKey: .isFullScreen) ?? false
        self.windowFrame = try c.decodeIfPresent(SavedRect.self, forKey: .windowFrame)
    }
}

package enum Persistence {
    private static var stateURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("mTerm", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("state.json")
    }

    package static func save(_ state: SavedState) {
        guard let url = stateURL else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // best effort
        }
    }

    package static func load() -> SavedState? {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }
}
