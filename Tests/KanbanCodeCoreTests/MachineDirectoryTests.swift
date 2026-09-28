import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("One machine is one choice")
struct MachineDirectoryTests {
    private let box = MachineIdentity(id: "machine_box", name: "rchaves-platform", alwaysOn: true)
    private let other = MachineIdentity(id: "machine_other", name: "studio")

    @Test("ssh targets and peer URLs give their host")
    func hosts() {
        #expect(MachineDirectory.host(ofSshTarget: "root@100.114.220.85") == "100.114.220.85")
        #expect(MachineDirectory.host(ofSshTarget: "me@Box.example:2222") == "box.example")
        #expect(MachineDirectory.host(ofSshTarget: "box-alias") == "box-alias")
        #expect(MachineDirectory.host(ofSshTarget: "root@[fd7a::1]") == "fd7a::1")
        #expect(MachineDirectory.host(ofURL: "http://100.114.220.85:7780") == "100.114.220.85")
    }

    @Test("an ssh machine that runs a paired master is listed once, as that master")
    func unified() {
        let ssh = [
            SshMachine(name: "platform", target: "root@100.114.220.85"),
            SshMachine(name: "gpu", target: "root@10.0.0.9"),
        ]
        let peers = [
            PeerStatus(peerId: "peer_box", machine: box, online: true, url: "http://100.114.220.85:7780"),
            PeerStatus(peerId: "peer_other", machine: other, online: false, url: "http://10.0.0.20:7780"),
        ]
        let choices = MachineDirectory.choices(sshMachines: ssh, peers: peers)
        #expect(choices.map(\.name) == ["platform", "gpu", "studio"])
        #expect(choices[0].master == box && choices[0].masterOnline && choices[0].sshMachine?.name == "platform")
        #expect(choices[1].master == nil && choices[1].sshMachine?.name == "gpu")
        #expect(choices[2].master == other && choices[2].sshMachine == nil && !choices[2].masterOnline)
    }

    @Test("the same name is the same machine when the hosts differ in form")
    func byName() {
        let ssh = [SshMachine(name: "rchaves-platform", target: "root@51.159.202.175")]
        let peers = [PeerStatus(peerId: "peer_box", machine: box, online: true, url: "http://100.114.220.85:7780")]
        let choices = MachineDirectory.choices(sshMachines: ssh, peers: peers)
        #expect(choices.count == 1)
        #expect(choices[0].master == box)
    }

    @Test("launches, moves and resumes that name the ssh machine reach the master on it")
    func resolvesSshName() {
        var state = AppState()
        state.boxdSettings = BoxdSettings(sshMachines: [SshMachine(name: "platform", target: "root@100.114.220.85")])
        state.peerStatuses["peer_box"] = PeerStatus(peerId: "peer_box", machine: box, online: true, url: "http://100.114.220.85:7780")
        #expect(state.peerMachine(named: "platform") == box)
        #expect(state.peerMachine(named: "PLATFORM") == box)
        #expect(state.peerMachine(named: "rchaves-platform") == box)
        #expect(state.peerMachine(named: "machine_box") == box)
        #expect(state.peerMachine(named: "gpu") == nil)
        #expect(state.sshMachine(named: "platform", runningMaster: "machine_box")?.target == "root@100.114.220.85")
        #expect(state.sshMachine(named: "platform", runningMaster: "machine_other") == nil)
    }
}
