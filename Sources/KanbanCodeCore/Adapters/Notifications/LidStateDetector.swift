#if canImport(IOKit)
import Foundation
import IOKit
import CoreGraphics

/// Detects whether the MacBook lid (clamshell) is closed via IOKit.
/// Works even when Amphetamine or similar tools keep the system awake.
public enum LidStateDetector {
    /// True when lid is closed AND no external display is active.
    /// When lid is closed but an external monitor is connected, returns false
    /// (user is at their desk using the external display).
    public static var isAway: Bool {
        isLidClosed && !hasActiveExternalDisplay
    }

    public static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != MACH_PORT_NULL else { return false }
        defer { IOObjectRelease(service) }

        let key: CFString = "AppleClamshellState" as CFString
        guard let prop = IORegistryEntryCreateCFProperty(
            service, key, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return false
        }

        if let num = prop as? Int {
            return num != 0
        }
        return (prop as? Bool) ?? false
    }

    private static var hasActiveExternalDisplay: Bool {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(displayIDs[i]) == 0 {
                return true
            }
        }
        return false
    }
}
#else
import Foundation

/// A headless host has no lid and nobody at its screen, so it is always away.
public enum LidStateDetector {
    public static var isAway: Bool { true }
    public static var isLidClosed: Bool { true }
    public static var hasActiveExternalDisplay: Bool { false }
}
#endif
