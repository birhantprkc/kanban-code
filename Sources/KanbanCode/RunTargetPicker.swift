import SwiftUI
import KanbanCodeCore

/// The "Run on" row of the launch dialogs in boxd mode: this Mac, the ssh
/// machines with whether they answer, and the boxd machines.
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
