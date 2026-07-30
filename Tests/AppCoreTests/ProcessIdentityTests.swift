import AppCore
import Testing

@Suite("Process identity")
struct ProcessIdentityTests {
    @Test("Start identity prevents a reused PID from being signalled")
    func rejectsReusedProcessID() {
        let selected = identity(processID: 42, startIdentity: "100:1", executable: "/wine")
        var signalledProcessIDs: [Int32] = []

        let didSignal = ProcessIdentitySignalGate.signal(
            selected: selected,
            signal: 15,
            currentIdentity: {
                identity(processID: 42, startIdentity: "101:2", executable: "/wine")
            },
            send: { processID, _ in
                signalledProcessIDs.append(processID)
                return 0
            }
        )

        #expect(!didSignal)
        #expect(signalledProcessIDs.isEmpty)
    }

    @Test("Executable identity prevents signalling a replaced process image")
    func rejectsReplacedExecutable() {
        let selected = identity(processID: 42, startIdentity: "100:1", executable: "/wine")
        var didInvokeBackend = false

        let didSignal = ProcessIdentitySignalGate.signal(
            selected: selected,
            signal: 9,
            currentIdentity: {
                identity(processID: 42, startIdentity: "100:1", executable: "/other")
            },
            send: { _, _ in
                didInvokeBackend = true
                return 0
            }
        )

        #expect(!didSignal)
        #expect(!didInvokeBackend)
    }

    @Test("A missing current executable cannot weaken a selected identity")
    func rejectsMissingCurrentExecutable() {
        let selected = identity(processID: 42, startIdentity: "100:1", executable: "/wine")

        let didSignal = ProcessIdentitySignalGate.signal(
            selected: selected,
            signal: 9,
            currentIdentity: {
                identity(processID: 42, startIdentity: "100:1", executable: nil)
            },
            send: { _, _ in 0 }
        )

        #expect(!didSignal)
    }

    @Test("Matching identity reaches the injected signal backend")
    func signalsMatchingIdentity() {
        let selected = identity(processID: 42, startIdentity: "100:1", executable: "/wine")
        var receivedSignal: Int32?

        let didSignal = ProcessIdentitySignalGate.signal(
            selected: selected,
            signal: 15,
            currentIdentity: { selected },
            send: { processID, signal in
                #expect(processID == 42)
                receivedSignal = signal
                return 0
            }
        )

        #expect(didSignal)
        #expect(receivedSignal == 15)
    }

    @Test(
        "Incomplete and failed process tables fail closed",
        arguments: [
            ProcessTableSnapshot<Int32>.incomplete([42]),
            .failed,
        ]
    )
    func rejectsUnreliableProcessTables(_ snapshot: ProcessTableSnapshot<Int32>) {
        #expect(throws: ProcessTableSnapshotError.self) {
            try snapshot.requireComplete()
        }
    }

    @Test("Only a complete process table exposes actionable elements")
    func acceptsCompleteProcessTable() throws {
        let snapshot = ProcessTableSnapshot<Int32>.complete([7, 42])

        #expect(try snapshot.requireComplete() == [7, 42])
    }

    private func identity(
        processID: Int32,
        startIdentity: String,
        executable: String?
    ) -> ProcessInstanceIdentity<Int32, String> {
        ProcessInstanceIdentity(
            processID: processID,
            startIdentity: startIdentity,
            executableIdentity: executable
        )
    }
}
