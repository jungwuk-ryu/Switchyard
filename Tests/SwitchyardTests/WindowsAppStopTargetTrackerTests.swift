import Foundation
import Testing

@testable import Switchyard

@Test func stopAllWindowsAppsRetainsStatusOnlyTargetsUntilPrefixStopSucceeds() {
    let containerID = UUID()
    var tracker = WindowsAppStopTargetTracker(
        initiallyRunningContainerIDs: [containerID]
    )

    tracker.observeRunningContainerIDs([])

    #expect(tracker.pendingPrefixStopContainerIDs == [containerID])

    tracker.markPrefixStopSucceeded(for: containerID)

    #expect(tracker.pendingPrefixStopContainerIDs.isEmpty)
}

@Test func stopAllWindowsAppsRetriesAReactivatedPrefix() {
    let containerID = UUID()
    var tracker = WindowsAppStopTargetTracker(
        initiallyRunningContainerIDs: [containerID]
    )
    tracker.markPrefixStopSucceeded(for: containerID)

    tracker.observeRunningContainerIDs([containerID])
    #expect(tracker.pendingPrefixStopContainerIDs.isEmpty)

    tracker.observeActivePrefixContainerIDs([containerID])
    #expect(tracker.pendingPrefixStopContainerIDs == [containerID])
}
