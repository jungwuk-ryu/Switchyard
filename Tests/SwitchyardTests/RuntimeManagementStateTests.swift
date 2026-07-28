import Testing
@testable import Switchyard

@Test func idleRuntimeManagementDoesNotOperateOnAnUninstalledRelease() {
    let state = RuntimeManagementState.idle

    #expect(
        !state.isOperating(
            releaseID: "release-id",
            installationID: nil
        )
    )
}

@Test func runtimeManagementMatchesTheActiveReleaseOperation() {
    let state = RuntimeManagementState.installing("release-id")

    #expect(
        state.isOperating(
            releaseID: "release-id",
            installationID: nil
        )
    )
    #expect(
        !state.isOperating(
            releaseID: "other-release-id",
            installationID: nil
        )
    )
}

@Test func runtimeManagementMatchesTheActiveInstallationOperation() {
    let state = RuntimeManagementState.removing("installation-id")

    #expect(
        state.isOperating(
            releaseID: "release-id",
            installationID: "installation-id"
        )
    )
}

@Test func runtimeInstallationStaysBusyWhileCancelling() {
    #expect(RuntimeInstallationState.working.isWorking)
    #expect(RuntimeInstallationState.cancelling.isWorking)
    #expect(!RuntimeInstallationState.cancelled.isWorking)
}
