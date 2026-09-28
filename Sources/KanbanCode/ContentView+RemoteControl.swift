import Foundation
import KanbanCodeCore

extension ContentView {
    /// The "Skip permissions" box of the launch dialogs.
    static var remoteSkipPermissions: Bool {
        UserDefaults.standard.object(forKey: "dangerouslySkipPermissions") as? Bool ?? true
    }
}
