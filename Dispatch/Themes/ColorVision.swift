import Foundation

/// Who a scheme's colors are for. Red-green covers protanopia and deuteranopia (about 1 man in 12), blue-yellow
/// tritanopia (rare); each keeps the accents apart along the axes those viewers still see.
enum ColorVision: String, Codable, CaseIterable, Identifiable, Sendable {
    case typical, redGreen, blueYellow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typical: "Typical"
        case .redGreen: "Red-green"
        case .blueYellow: "Blue-yellow"
        }
    }

    var detail: String {
        switch self {
        case .typical: "all colors"
        case .redGreen: "protanopia and deuteranopia, the most common"
        case .blueYellow: "tritanopia"
        }
    }

    /// The dichromacies a scheme for this vision is checked against.
    var deficiencies: [Deficiency] {
        switch self {
        case .typical: []
        case .redGreen: [.protanopia, .deuteranopia]
        case .blueYellow: [.tritanopia]
        }
    }

    /// Machado, Oliveira and Fernandes (2009) at full severity: how a color looks without one kind of cone, on linear
    /// sRGB.
    enum Deficiency: CaseIterable, Sendable {
        case protanopia, deuteranopia, tritanopia

        var matrix: [[Double]] {
            switch self {
            case .protanopia: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
            case .deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
            case .tritanopia: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
            }
        }
    }

}
