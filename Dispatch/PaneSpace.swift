import Foundation

extension AppDelegate {
    func movePaneToNewSpace(_ surface: UUID) {
        guard let tab = workspace.spaces.flatMap(\.tabs).first(where: { $0.surfaceIDs.contains(surface) }) else { return }
        workspace.moveTabToNewSpace(tab.id)
    }
}
