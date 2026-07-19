import Darwin
import Foundation
import KanbanCodeCore
import os

/// Lightweight process memory logging for diagnosing leaks after the fact.
///
/// Logs to the normal Kanban Code log when footprint grows meaningfully or
/// crosses a high-water threshold. Disable with `KANBAN_MEMORY_DIAGNOSTICS=0`.
final class MemoryDiagnostics: @unchecked Sendable {
    static let shared = MemoryDiagnostics()

    private struct Snapshot {
        let resident: UInt64
        let footprint: UInt64
        let virtualSize: UInt64
    }

    private struct RelatedProcessSnapshot {
        let label: String
        let pid: pid_t
        let resident: UInt64
        let virtualSize: UInt64
    }

    typealias MainActorMetricProvider = @MainActor @Sendable () -> String

    private let isRunning = OSAllocatedUnfairLock(initialState: false)
    private let checkInterval: TimeInterval = 10
    private let periodicInterval: TimeInterval = 60
    private let growthThreshold: UInt64 = 256 * 1024 * 1024
    private let warningThreshold: UInt64 = 1_024 * 1024 * 1024
    private let criticalThreshold: UInt64 = 4 * 1_024 * 1024 * 1024
    private let artifactInterval: TimeInterval = 120

    private var lastLoggedAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var lastLoggedFootprint = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var lastLoggedTotalResident = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var lastArtifactAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var relatedProcessPIDs = OSAllocatedUnfairLock(initialState: [String: Set<pid_t>]())
    private var mainActorMetricProviders = OSAllocatedUnfairLock(initialState: [String: MainActorMetricProvider]())

    private init() {}

    func start() {
        guard ProcessInfo.processInfo.environment["KANBAN_MEMORY_DIAGNOSTICS"] != "0" else { return }

        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }

        if let snapshot = Self.currentSnapshot() {
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = snapshot.resident }
            log(snapshot, reason: "start")
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.isRunning.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: self.checkInterval)
                guard let snapshot = Self.currentSnapshot() else { continue }
                self.logIfNeeded(snapshot)
            }
        }
    }

    func stop() {
        isRunning.withLock { $0 = false }
    }

    func setRelatedProcessPIDs(label: String, pids: Set<pid_t>) {
        relatedProcessPIDs.withLock { current in
            if pids.isEmpty {
                current.removeValue(forKey: label)
            } else {
                current[label] = pids
            }
        }
    }

    func registerMainActorMetricProvider(name: String, provider: @escaping MainActorMetricProvider) {
        mainActorMetricProviders.withLock { $0[name] = provider }
    }

    private func logIfNeeded(_ snapshot: Snapshot) {
        let previous = lastLoggedFootprint.withLock { $0 }
        let growth = snapshot.footprint > previous ? snapshot.footprint - previous : 0
        let relatedResident = relatedSnapshots().reduce(UInt64(0)) { $0 + $1.resident }
        let totalResident = snapshot.resident + relatedResident
        let previousTotal = lastLoggedTotalResident.withLock { $0 }
        let totalGrowth = totalResident > previousTotal ? totalResident - previousTotal : 0

        let now = Date()
        let periodic = lastLoggedAt.withLock { last -> Bool in
            guard now.timeIntervalSince(last) >= periodicInterval else { return false }
            last = now
            return true
        }

        if snapshot.footprint >= criticalThreshold || totalResident >= criticalThreshold {
            log(snapshot, reason: "critical")
            captureArtifactsIfNeeded(snapshot: snapshot, reason: "critical")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = totalResident }
        } else if (snapshot.footprint >= warningThreshold && growth >= growthThreshold)
                    || (totalResident >= warningThreshold && totalGrowth >= growthThreshold) {
            log(snapshot, reason: "growth")
            captureArtifactsIfNeeded(snapshot: snapshot, reason: "growth")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = totalResident }
        } else if periodic {
            log(snapshot, reason: "periodic")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            lastLoggedTotalResident.withLock { $0 = totalResident }
        }
    }

    private func log(_ snapshot: Snapshot, reason: String) {
        let related = relatedSnapshots()
        let relatedResident = related.reduce(UInt64(0)) { $0 + $1.resident }
        let relatedDetail = related.isEmpty
            ? ""
            : " related=[\(related.map { "\($0.label):pid=\($0.pid),rss=\(Self.format($0.resident)),virtual=\(Self.format($0.virtualSize))" }.joined(separator: ";"))] relatedRSS=\(Self.format(relatedResident)) totalRSS=\(Self.format(snapshot.resident + relatedResident))"
        KanbanCodeLog.info(
            "memory",
            "reason=\(reason) footprint=\(Self.format(snapshot.footprint)) rss=\(Self.format(snapshot.resident)) virtual=\(Self.format(snapshot.virtualSize))\(relatedDetail)"
        )
        logMainActorMetrics(reason: reason)
    }

    private static func currentSnapshot() -> Snapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Snapshot(
            resident: UInt64(info.resident_size),
            footprint: UInt64(info.phys_footprint),
            virtualSize: UInt64(info.virtual_size)
        )
    }

    private func relatedSnapshots() -> [RelatedProcessSnapshot] {
        let pidsByLabel = relatedProcessPIDs.withLock { $0 }
        return pidsByLabel.flatMap { label, pids in
            pids.compactMap { Self.processSnapshot(pid: $0, label: label) }
        }
        .sorted { $0.pid < $1.pid }
    }

    private static func processSnapshot(pid: pid_t, label: String) -> RelatedProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard result == Int32(size) else { return nil }
        return RelatedProcessSnapshot(
            label: label,
            pid: pid,
            resident: UInt64(info.pti_resident_size),
            virtualSize: UInt64(info.pti_virtual_size)
        )
    }

    private func logMainActorMetrics(reason: String) {
        let providers = mainActorMetricProviders.withLock { $0 }
        guard !providers.isEmpty else { return }
        Task { @MainActor in
            let metrics = providers
                .sorted { $0.key < $1.key }
                .map { "\($0.key){\($0.value())}" }
                .joined(separator: " ")
            KanbanCodeLog.info("memory-context", "reason=\(reason) \(metrics)")
        }
    }

    private func captureArtifactsIfNeeded(snapshot: Snapshot, reason: String) {
        let now = Date()
        let shouldCapture = lastArtifactAt.withLock { last -> Bool in
            guard now.timeIntervalSince(last) >= artifactInterval else { return false }
            last = now
            return true
        }
        guard shouldCapture else { return }

        let relatedPIDs = relatedSnapshots().map(\.pid)
        let pids = [ProcessInfo.processInfo.processIdentifier] + relatedPIDs
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs/memory-samples")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        runDiagnosticCommand(
            executable: "/bin/ps",
            arguments: ["-o", "pid,ppid,rss,vsz,command", "-p", pids.map(String.init).joined(separator: ",")],
            outputPath: (dir as NSString).appendingPathComponent("memory-\(stamp)-\(reason)-ps.txt")
        )
        for pid in pids {
            runDiagnosticCommand(
                executable: "/usr/bin/vmmap",
                arguments: ["-summary", String(pid)],
                outputPath: (dir as NSString).appendingPathComponent("memory-\(stamp)-\(reason)-pid\(pid)-vmmap.txt")
            )
        }
    }

    private func runDiagnosticCommand(executable: String, arguments: [String], outputPath: String) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                try? data.write(to: URL(fileURLWithPath: outputPath))
                KanbanCodeLog.info("memory", "diagnostic artifact written: \(outputPath)")
            } catch {
                KanbanCodeLog.warn("memory", "diagnostic command failed: \(executable) \(arguments.joined(separator: " ")) error=\(error)")
            }
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1024 / 1024
        if mib >= 1024 {
            return String(format: "%.2fGiB", mib / 1024)
        }
        return String(format: "%.0fMiB", mib)
    }
}
