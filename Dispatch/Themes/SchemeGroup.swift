import Foundation

/// The sections the color schemes are listed in, on the Mac's scheme pickers and the iPhone's scheme list: `dark` and
/// `light` in their order. The bundled schemes are placed by hand; any other (imported, made, your own) by its colors
/// (`group(background:accents:light:)`).
enum SchemeGroup: String, CaseIterable, Sendable {
    case oled, graphite, midnight, dusk, white, offWhite, cream, mist, muted, neon, fun

    static let dark: [SchemeGroup] = [.oled, .graphite, .midnight, .dusk, .muted, .neon, .fun]
    static let light: [SchemeGroup] = [.white, .offWhite, .cream, .mist, .muted, .fun]

    var title: String {
        switch self {
        case .oled: "OLED"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .dusk: "Dusk"
        case .white: "White"
        case .offWhite: "Off-white"
        case .cream: "Cream"
        case .mist: "Mist"
        case .muted: "Muted"
        case .neon: "Neon"
        case .fun: "Fun"
        }
    }

    /// The bundled schemes (Vendor/Term/Resources/ghostty/themes), dark then light: Muted and Fun hold both. The
    /// colorblind ones go with their typical-vision sibling, though colorblind modes list them alone.
    static let bundled: [String: SchemeGroup] = {
        let dark: [SchemeGroup: [String]] = [
            .oled: ["dispatch-black", "Detuned", "Modus Vivendi", "Modus Vivendi Deuteranopia",
                    "Modus Vivendi Tritanopia", "vim-ice", "vim-ir_black"],
            .graphite: ["dispatch", "vim-vantablack", "Flexoki Dark", "Xcode Dark",
                        "Xcode Dark hc", "Monokai Pro", "Monokai Pro Ristretto", "vim-pokemon"],
            .midnight: ["Ayu", "Ayu Mirage", "GitHub Dark Default", "GitHub Dark Colorblind",
                        "vim-gotham", "Night Owl", "One Half Dark", "Monokai Pro Machine",
                        "iTerm2 Solarized Dark", "Citrus Ink", "Terminal Green 1999",
                        "Trapped in Amber"],
            .dusk: ["TokyoNight", "TokyoNight Storm", "Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappe",
                    "Rose Pine", "Rose Pine Moon", "Monokai Pro Octagon"],
            .muted: ["Kanagawa Wave", "Kanagawa Dragon", "Kanso Zen", "Zenbones Dark", "Melange Dark",
                     "Everforest Dark Hard", "Gruvbox Dark", "Iceberg Dark", "Nord", "Nightfox",
                     "Tomorrow Night", "vim-bubblegum", "Sakura", "Twilight"],
            .neon: ["Dracula", "Vaporwave Sunset", "Emerald Synth", "Oxocarbon", "Monokai Classic",
                    "Monokai Pro Spectrum", "vim-prismatic"],
            .fun: ["Hot Dog Stand", "Root Access", "Red Alert", "Bluescreen"],
        ]
        let light: [SchemeGroup: [String]] = [
            .white: ["Adwaita", "GitHub Light Default", "GitHub Light Colorblind", "Modus Operandi",
                     "Modus Operandi Deuteranopia", "Modus Operandi Tritanopia", "Xcode Light", "Xcode Light hc",
                     "TextMate"],
            .offWhite: ["Light Owl", "One Half Light", "Alabaster"],
            .cream: ["iTerm2 Solarized Light", "Flexoki Light", "Gruvbox Light", "Rose Pine Dawn",
                     "Monokai Pro Light", "Monokai Pro Light Sun", "Dayfox", "Novel",
                     "vim-sailormoon"],
            .mist: ["Catppuccin Latte", "TokyoNight Day", "Iceberg Light", "Nvim Light", "Ayu Light", "Y2K Chrome"],
            .muted: ["Zenbones Light", "Melange Light", "Kanagawa Lotus", "Everforest Light Med",
                     "Patina Stellar"],
            .fun: ["Hot Dog Stand (Mustard)", "Cotton Candy"],
        ]
        return Dictionary(uniqueKeysWithValues: [dark, light].flatMap { table in
            table.flatMap { group, names in names.map { ($0, group) } }
        })
    }()

    /// The names the lists show where they differ from the file's: Dispatch's own (extras/ghostty), and bundled schemes
    /// whose file names carry their source. The files keep their names, which settings store.
    static let titles = [
        "dispatch-black": "Dispatch", "dispatch": "Dispatch Gray", "GitHub Dark Default": "GitHub Dark",
        "iTerm2 Solarized Dark": "Solarized Dark", "iTerm2 Solarized Light": "Solarized Light",
        // Vim colorschemes ported to Ghostty, without the port's prefix.
        "vim-bubblegum": "Bubblegum", "vim-gotham": "Gotham", "vim-ice": "Ice", "vim-ir_black": "IR Black",
        "vim-pokemon": "Pokemon", "vim-prismatic": "Prismatic", "vim-sailormoon": "Sailor Moon", "vim-vantablack": "Vantablack",
    ]

    /// A scheme's name as the lists show it: by its title, or its file name.
    static func title(_ name: String) -> String { titles[name] ?? name }

    /// The classics: Dispatch's own, and schemes nearly every terminal offers (Ghostty, iTerm2, WezTerm, Kitty, Alacritty)
    /// and people ask for by name, each with a sentence of its history. The scheme lists mark them with a star, the
    /// history in the tooltip, and SchemeAudit leaves them alone.
    static let classics: [String: String] = {
        let solarized = "Ethan Schoonover's 2011 sixteen-color palette, built on fixed CIELAB lightness steps to work light or dark."
        let gruvbox = "Pavel Pertsev's 2012 Vim theme of retro groove colors, warm and easy on the eyes."
        let oneHalf = "Son A. Pham's port of Atom's One Dark and One Light to terminals and Vim."
        let catppuccin = "A community pastel theme from 2021 in four flavors, Latte to Mocha, now ported to hundreds of apps."
        let tokyoNight = "Enkia's VS Code theme of Tokyo's lights at night, made a Neovim staple by folke's port."
        let rosePine = "“All natural pine, faux fur and a bit of soho vibes”: a soft palette with Main, Moon and Dawn variants."
        let kanagawa = "Rebelot's Neovim theme after Hokusai's The Great Wave off Kanagawa: Wave, Dragon and Lotus."
        let everforest = "Sainnhe's green, warm Vim theme, made to be gentle on the eyes over a long day."
        let gitHub = "GitHub's own colors from github.com, as its Primer team ships them in the official VS Code theme."
        let ayu = "Ike Ku's Sublime Text theme in three shades: light, mirage and dark."
        let owl = "Sarah Drasner's 2018 VS Code theme for coding late at night, its colors chosen for low light and color blindness."
        let flexoki = "Steph Ango's 2023 palette after analog printing inks on warm paper."
        let fox = "EdenEast's Neovim family of foxes, Nightfox by night and Dayfox by day."
        let iceberg = "Cocopon's bluish Vim theme, dark and cool, later with a light side."
        let monokai = "Wimer Hazenberg's 2006 TextMate theme, Sublime Text's default for years and copied into nearly every editor since."
        let monokaiPro = "Wimer Hazenberg's own successor to Monokai, from 2017, in a set of filters from Classic to Spectrum."
        return [
            "dispatch-black": "Dispatch's own colors, made alongside the app: true black, for OLED screens.",
            "Dracula": "Zeno Rocha's 2013 dark theme, since ported to hundreds of apps by its community.",
            "iTerm2 Solarized Dark": solarized, "iTerm2 Solarized Light": solarized,
            "Monokai Classic": monokai, "Monokai Pro": monokaiPro, "Monokai Pro Ristretto": monokaiPro,
            "Monokai Pro Machine": monokaiPro, "Monokai Pro Octagon": monokaiPro, "Monokai Pro Spectrum": monokaiPro,
            "Monokai Pro Light": monokaiPro, "Monokai Pro Light Sun": monokaiPro,
            "Nord": "Arctic Ice Studio's 2016 palette of the arctic north: frost blues on polar night.",
            "Gruvbox Dark": gruvbox, "Gruvbox Light": gruvbox,
            "Tomorrow Night": "Chris Kempson's 2011 Tomorrow family, ported early to nearly every editor and terminal.",
            "One Half Dark": oneHalf, "One Half Light": oneHalf,
            "Catppuccin Mocha": catppuccin, "Catppuccin Macchiato": catppuccin, "Catppuccin Frappe": catppuccin,
            "Catppuccin Latte": catppuccin,
            "TokyoNight": tokyoNight, "TokyoNight Storm": tokyoNight, "TokyoNight Day": tokyoNight,
            "Rose Pine": rosePine, "Rose Pine Moon": rosePine, "Rose Pine Dawn": rosePine,
            "Kanagawa Wave": kanagawa, "Kanagawa Dragon": kanagawa, "Kanagawa Lotus": kanagawa,
            "Everforest Dark Hard": everforest, "Everforest Light Med": everforest,
            "GitHub Dark Default": gitHub, "GitHub Light Default": gitHub,
            "Ayu": ayu, "Ayu Mirage": ayu, "Ayu Light": ayu,
            "Night Owl": owl, "Light Owl": owl,
            "Flexoki Dark": flexoki, "Flexoki Light": flexoki,
            "Nightfox": fox, "Dayfox": fox,
            "Iceberg Dark": iceberg, "Iceberg Light": iceberg,
        ]
    }()

    /// Fun's order: the movie themes, then the Hot Dog Stands; the rest of Fun, and every other group, by name.
    static let funOrder = ["Root Access", "Red Alert", "Bluescreen", "Hot Dog Stand", "Hot Dog Stand (Mustard)",
                           "Cotton Candy"]

    /// `items` (already by name) in this group's order.
    func ordered<Item>(_ items: [Item], name: (Item) -> String) -> [Item] {
        guard self == .fun else { return items }
        let ranks = items.map { Self.funOrder.firstIndex(of: name($0)) ?? Self.funOrder.count }
        // Stable: ties keep their order by name.
        return items.indices.sorted { (ranks[$0], $0) < (ranks[$1], $1) }.map { items[$0] }
    }

    /// The bundled schemes listed on both sides (in Fun), whatever their background: the Hot Dog Stand pair.
    static let bothSides: Set<String> = ["Hot Dog Stand", "Hot Dog Stand (Mustard)"]

    /// The bundled schemes drawn with the phosphor glow and scanlines (Config.glow), by file name.
    static let glowing: Set<String> = ["Root Access", "Red Alert", "Bluescreen"]

    /// A scheme's section: the bundled table by name, otherwise by its colors (0...1 components).
    static func of(_ name: String, background: (Double, Double, Double), accents: [(Double, Double, Double)],
                   light: Bool) -> SchemeGroup {
        bundled[name] ?? group(background: background, accents: accents, light: light)
    }

    /// The rule the bundled table was drawn from, for the rest, checked in order. Dark: a black background is OLED;
    /// vivid accents (red to cyan, mean HSL saturation 0.85 or more) Neon; dull ones (0.5 or less) Muted; otherwise the
    /// background's hue: gray or warm Graphite, indigo to violet Dusk, the rest (navy, blue, teal) Midnight. Light:
    /// dull accents (0.45 or less) Muted; an untinted background White when pure white, Off-white when grayer; a warm
    /// one Cream, a cool one Mist. Fun is by hand only.
    static func group(background: (Double, Double, Double), accents: [(Double, Double, Double)],
                      light: Bool) -> SchemeGroup {
        let accent = accents.isEmpty ? nil : accents.map { hsl($0).saturation }.reduce(0, +) / Double(accents.count)
        if light {
            if let accent, accent <= 0.45 { return .muted }
            // HSL saturation runs high on any tint of white: the tint's strength is the channels' spread.
            if max(background.0, background.1, background.2) - min(background.0, background.1, background.2) <= 0.04 {
                return min(background.0, background.1, background.2) >= 0.995 ? .white : .offWhite
            }
            return (100..<300).contains(hsl(background).hue) ? .mist : .cream
        }
        if max(background.0, background.1, background.2) <= 0.01 { return .oled }
        if let accent, accent >= 0.85 { return .neon }
        if let accent, accent <= 0.5 { return .muted }
        let (hue, saturation) = hsl(background)
        if saturation < 0.1 { return .graphite }
        switch hue {
        case 235..<320: return .dusk
        case 150..<235: return .midnight
        default: return .graphite
        }
    }

    /// Hue in degrees and HSL saturation.
    private static func hsl(_ c: (Double, Double, Double)) -> (hue: Double, saturation: Double) {
        let high = max(c.0, c.1, c.2), low = min(c.0, c.1, c.2), range = high - low
        guard range > 0 else { return (0, 0) }
        let lightness = (high + low) / 2
        let saturation = range / (1 - abs(2 * lightness - 1))
        let hue: Double = switch high {
        case c.0: (c.1 - c.2) / range
        case c.1: (c.2 - c.0) / range + 2
        default: (c.0 - c.1) / range + 4
        }
        return ((hue * 60 + 360).truncatingRemainder(dividingBy: 360), saturation)
    }
}
