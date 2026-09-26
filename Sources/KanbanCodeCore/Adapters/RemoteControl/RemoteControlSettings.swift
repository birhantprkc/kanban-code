import Foundation
import KanbanCodeRemoteKit

/// Settings > Remote Control: the HTTP server phones and other agents use to
/// drive this Mac (docs/remote-control.md). Off until turned on.
public struct RemoteControlSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var port: Int

    public init(enabled: Bool = false, port: Int = RemoteAPI.defaultPort) {
        self.enabled = enabled
        self.port = port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        let port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? RemoteAPI.defaultPort
        self.port = (1...65535).contains(port) ? port : RemoteAPI.defaultPort
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, port
    }
}
