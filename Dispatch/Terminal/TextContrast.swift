/// Improve text contrast, on the Mac and the iPhone: the terminal's contrast shader at 4.5:1 for light schemes only
/// (the default: faint colors wash out on light backgrounds), every scheme, or none.
enum TextContrast: String, Codable, CaseIterable, Identifiable, Sendable {
    case lightThemes, always, never

    var id: Self { self }

    var title: String {
        switch self {
        case .lightThemes: "Light themes"
        case .always: "Always"
        case .never: "Never"
        }
    }

    func improves(dark: Bool) -> Bool { self == .always || self == .lightThemes && !dark }
}
