import Foundation

struct SavedTab: Codable {
    let cwd: String?
}

struct SavedRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct SavedState: Codable {
    let tabs: [SavedTab]
    let isFullScreen: Bool
    let windowFrame: SavedRect?

    init(tabs: [SavedTab],
         isFullScreen: Bool = false,
         windowFrame: SavedRect? = nil) {
        self.tabs = tabs
        self.isFullScreen = isFullScreen
        self.windowFrame = windowFrame
    }

    private enum CodingKeys: String, CodingKey {
        case tabs, isFullScreen, windowFrame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tabs = try c.decodeIfPresent([SavedTab].self, forKey: .tabs) ?? []
        self.isFullScreen = try c.decodeIfPresent(Bool.self, forKey: .isFullScreen) ?? false
        self.windowFrame = try c.decodeIfPresent(SavedRect.self, forKey: .windowFrame)
    }
}

enum Persistence {
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

    static func save(_ state: SavedState) {
        guard let url = stateURL else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // best effort
        }
    }

    static func load() -> SavedState? {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }
}
