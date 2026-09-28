import SwiftUI
import KanbanCodeCore

/// The "Run on" row of the launch dialogs in the ssh and boxd modes: this
/// Mac, then the machines of the mode (see `RunTargetOption.options`).
struct RunTargetPicker: View {
    let remote: RemoteLaunchOptions
    @Binding var runRemotely: Bool
    @Binding var machineChoice: BoxdMachineChoice
    @State private var reachability: [String: Bool] = [:]

    var body: some View {
        Picker("Run on", selection: selection) {
            ForEach(RunTargetOption.options(for: remote, reachability: reachability)) { option in
                Text(option.label).tag(option.target)
            }
        }
        .font(.app(.callout))
        .task(id: remote.sshMachines) {
            await probe()
        }
    }

    private var selection: Binding<RunTarget> {
        Binding(
            get: { runRemotely ? .machine(machineChoice) : .mac },
            set: { target in
                switch target {
                case .mac:
                    runRemotely = false
                case .machine(let choice):
                    machineChoice = choice
                    runRemotely = true
                }
            }
        )
    }

    private func probe() async {
        guard remote.mode == .ssh else { return }
        await withTaskGroup(of: (String, Bool).self) { group in
            for machine in remote.sshMachines {
                group.addTask { (machine.name, await SshHostPort.isReachable(target: machine.target)) }
            }
            for await (name, reachable) in group {
                reachability[name] = reachable
            }
        }
    }
}
