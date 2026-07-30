import Foundation
import Testing
@testable import AppCore

@Suite("Wine Prefix Session Inspection")
struct WinePrefixSessionInspectionTests {
    @Test("normalizes host process identifiers")
    func normalizesHostProcessIdentifiers() {
        let inspection = WinePrefixSessionInspection(
            state: .active,
            hostProcessIDs: [42, -1, 7, 42, 0]
        )

        #expect(inspection.state == .active)
        #expect(inspection.hostProcessIDs == [7, 42])
    }

    @Test("inactive sessions never carry host process identifiers")
    func inactiveSessionsHaveNoHostProcesses() {
        let inspection = WinePrefixSessionInspection(
            state: .inactive,
            hostProcessIDs: [42]
        )

        #expect(inspection.hostProcessIDs.isEmpty)
    }

    @Test("decoding enforces wire invariants")
    func decodingEnforcesWireInvariants() throws {
        let data = Data(
            #"{"state":"orphaned","hostProcessIDs":[9,3,9,-2,0]}"#.utf8
        )

        let inspection = try JSONDecoder().decode(
            WinePrefixSessionInspection.self,
            from: data
        )

        #expect(inspection == WinePrefixSessionInspection(
            state: .orphaned,
            hostProcessIDs: [3, 9]
        ))
    }

    @Test("round trips the stable JSON field names")
    func roundTripsStableJSONFields() throws {
        let inspection = WinePrefixSessionInspection(
            state: .active,
            hostProcessIDs: [10, 2]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(inspection)

        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"hostProcessIDs":[2,10],"state":"active"}"#
        )
        #expect(
            try JSONDecoder().decode(WinePrefixSessionInspection.self, from: data)
                == inspection
        )
    }
}
