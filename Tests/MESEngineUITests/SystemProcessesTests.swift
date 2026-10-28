import Darwin
import Foundation
@testable import MESEngineUI
import Testing

// The System page's engine memory: this process alone, a host and its workers read by pid, or readings the backend
// supplies, with one row per process and their total.

@MainActor
@Suite("System page: engine memory across processes")
struct SystemProcessesTests {
    @Test("Readings from the backend: one per process, summed, and the total is what the history records")
    func backendReadings() async {
        let host = EngineProcess(id: "host", title: "Gaea", pid: 1, role: .host)
        let readings = [ProcessFootprint(process: host, bytes: 300 << 20),
                        ProcessFootprint(process: EngineProcess(id: "z-image", title: "Z-Image", pid: 2), bytes: 14 << 30),
                        ProcessFootprint(process: EngineProcess(id: "pack", title: "Processing pack", pid: 3), bytes: 2 << 30)]
        let store = SystemMonitorStore(processes: .readings { readings })
        await store.sampleNow()
        #expect(store.snapshot.processes == readings)
        #expect(store.snapshot.processFootprintBytes == (300 << 20) + (14 << 30) + (2 << 30))
        #expect(store.footprintHistory.last?.value == Double((300 << 20) + (14 << 30) + (2 << 30)))
    }

    @Test("Pids from the backend: each is read with proc_pid_rusage, and one that has exited drops out")
    func pidsReadWithRusage() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let childPID = child.processIdentifier

        let store = SystemMonitorStore(processes: .processes {
            [EngineProcess.current(title: "Host"),
             EngineProcess(id: "worker", title: "Worker", pid: childPID),
             EngineProcess(id: "gone", title: "Exited", pid: 999_999),
             EngineProcess(id: "nopid", title: "No pid")]
        })
        await store.sampleNow()
        let processes = store.snapshot.processes
        #expect(processes.map(\.id) == ["host", "worker"])
        #expect(processes.allSatisfy { $0.bytes > 0 })
        #expect(store.snapshot.processFootprintBytes == processes[0].bytes + processes[1].bytes)
        // The host is this process, so it's the bigger one by far.
        #expect(processes[0].bytes > processes[1].bytes)
    }

    @Test("By default the page reads this process alone, matching task_info's phys_footprint")
    func currentProcessByDefault() async {
        let store = SystemMonitorStore()
        await store.sampleNow()
        let processes = store.snapshot.processes
        #expect(processes.count == 1)
        #expect(processes.first?.process.role == .host)
        #expect(processes.first?.process.pid == getpid())

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        #expect(result == KERN_SUCCESS)
        let rusage = try? #require(ProcessFootprint.physFootprint(pid: getpid()))
        let ratio = Double(rusage ?? 0) / Double(info.phys_footprint)
        #expect(ratio > 0.8 && ratio < 1.25, "proc_pid_rusage \(rusage ?? 0) vs task_info \(info.phys_footprint)")
    }

    @Test("The source can change after the store is made (an engine starts its workers later)")
    func sourceChanges() async {
        let store = SystemMonitorStore()
        await store.sampleNow()
        #expect(store.snapshot.processes.count == 1)
        store.processSource = .readings {
            [ProcessFootprint(process: .current(), bytes: 1), ProcessFootprint(process: EngineProcess(id: "w", title: "W"), bytes: 2)]
        }
        await store.sampleNow()
        #expect(store.snapshot.processFootprintBytes == 3)
    }
}
