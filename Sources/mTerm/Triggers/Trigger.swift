import Foundation
import simd

enum ClickAction: Codable, Equatable {
    case openURL
    /// Selects the match in Finder rather than launching it. Opening a path
    /// with its default app means a stray ⌘-click on a `.sh` or a `.app`
    /// runs it; revealing is the same gesture with nothing to undo.
    case revealFile
    case runCommand(String)        // template, $1 is the matched text
}

enum TriggerStyle: String, Codable {
    /// Clickable, but never drawn as part of the ambient screen. What the
    /// builtins use: marking *every* link at once — a rule under each, a tint
    /// behind each, each in its own colour — was tried in all three forms and
    /// each read as the terminal repainting itself. A `.none` trigger is
    /// still marked while the pointer is on it; see TerminalView's hover
    /// bands.
    case none
    case background
    case underline
    case both
    /// Recolour the matched text itself, drawing nothing around it.
    case text
}

struct Trigger: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var pattern: String
    /// Background tint color (RGBA, 0..1).
    var colorR: Float
    var colorG: Float
    var colorB: Float
    var colorA: Float
    var style: TriggerStyle
    var clickAction: ClickAction?
    var enabled: Bool

    init(id: UUID = UUID(),
         name: String,
         pattern: String,
         color: SIMD4<Float>,
         style: TriggerStyle = .background,
         clickAction: ClickAction? = nil,
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.colorR = color.x
        self.colorG = color.y
        self.colorB = color.z
        self.colorA = color.w
        self.style = style
        self.clickAction = clickAction
        self.enabled = enabled
    }

    var color: SIMD4<Float> { SIMD4(colorR, colorG, colorB, colorA) }
}

extension Trigger {
    /// One path segment. `-` is allowed inside a segment but never at the
    /// start of a relative path, so a compiler flag like `-I/usr/include`
    /// doesn't read as a path.
    private static let seg  = #"[\w.+%@-]+"#
    private static let head = #"[\w.+%@][\w.+%@-]*"#

    /// Hostnames worth linking without a scheme. Curated rather than
    /// `[a-z]{2,}` because a terminal is full of strings that look like a
    /// bare domain: the ccTLDs that collide with file extensions (`sh`, `py`,
    /// `rs`, `pl`, `so`, `md`, `cc`) and the gTLDs that collide with bundles
    /// and archives (`app`, `zip`, `mov`) are deliberately absent, so
    /// `main.py` and `mTerm.app` stay plain text. `localhost` is in the list
    /// so Traefik-style `<service>.docker.localhost` hosts resolve.
    private static let tlds = [
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name", "pro",
        "io", "dev", "ai", "xyz", "tech", "cloud", "site", "online", "store", "blog",
        "wiki", "live", "news", "page", "space", "shop", "design", "studio", "media",
        "agency", "digital", "email", "network", "systems", "solutions", "software",
        "tools", "host", "press", "link", "click", "chat", "social", "team", "works",
        "group", "center", "company", "today", "world", "life", "fun", "art", "run",
        "build", "co", "me", "tv", "fm", "gg", "to", "ly", "is",
        "uk", "de", "fr", "jp", "cn", "ru", "br", "in", "au", "ca", "nl", "se", "no",
        "fi", "dk", "es", "it", "ch", "at", "be", "eu", "us", "nz", "za", "kr", "mx",
        "ar", "cl", "tr", "il", "ie", "pt", "gr", "cz", "hu", "ro", "ua", "sg", "hk",
        "tw", "id", "th", "vn", "ph", "my", "local", "localhost",
    ].joined(separator: "|")

    /// Everything a URL may carry after the host: path, query, fragment.
    private static let tail = #"(?:/[^\s)\]>"'`]*)?"#

    /// Three shapes, tried in order:
    ///   1. an explicit scheme,
    ///   2. a dotted host ending in a known TLD — `code.d0x2a.com`, with an
    ///      optional port and path,
    ///   3. `localhost` or a bare IPv4, but only when a port or path follows,
    ///      so the word "localhost" in prose and a mentioned IP stay plain.
    /// The leading `(?<![@\w.-])` keeps the host shapes from matching the
    /// domain half of an email address, and the trailing `(?<![.,;:!?])`
    /// backtracks off sentence punctuation so "see example.com." doesn't
    /// link the full stop.
    static let urlPattern = """
    (?:\
    (?:https?|ftp|file)://[^\\s)\\]>"'`]+\
    |(?<![@\\w.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+(?:\(tlds))(?![\\w-])(?::\\d{1,5})?\(tail)\
    |(?<![@\\w.-])(?:localhost|\\d{1,3}(?:\\.\\d{1,3}){3})(?=[:/])(?::\\d{1,5})?\(tail)\
    )(?<![.,;:!?])
    """

    /// A path is anything rooted at `/`, `~/`, `./` or `../`, plus a relative
    /// run containing a slash (`src/main.swift`, `build/`). An optional
    /// trailing `:line[:col]` is part of the match so compiler and grep output
    /// links cleanly instead of stopping at the colon.
    ///
    /// This pattern is deliberately loose — `and/or` matches it. What keeps
    /// it quiet is that TerminalView drops every path match that doesn't
    /// exist on disk before anything is drawn or clicked.
    static let pathPattern =
        #"(?<![\w@:/~.-])(?:(?:~|\.{1,2})?/(?:\#(seg)/)*\#(seg)/?|\#(head)(?:/\#(seg))+/?|\#(head)/)(?::\d+(?::\d+)?)?"#

    /// Defaults shipped with mTerm. Neither draws anything of its own: a link
    /// looks exactly like the text around it until the pointer reaches it,
    /// and only then takes the theme accent with a matching underline. What
    /// made the earlier attempts fail wasn't the decoration, it was that all
    /// of them fired on every link on screen at once.
    ///
    /// The stored colour goes unused at `.none` — hover marking takes its
    /// colour from the theme — and is kept so either trigger can be given a
    /// visible style without inventing one. Git SHAs and IPv4 used to be
    /// builtins too; they marked constantly and had nothing useful to open.
    static let builtins: [Trigger] = [
        Trigger(name: "URL",
                pattern: urlPattern,
                color: SIMD4(0.40, 0.65, 1.00, 1.00),
                style: .none,
                clickAction: .openURL),
        Trigger(name: "File path",
                pattern: pathPattern,
                color: SIMD4(0.40, 0.65, 1.00, 1.00),
                style: .none,
                clickAction: .revealFile),
    ]
}
