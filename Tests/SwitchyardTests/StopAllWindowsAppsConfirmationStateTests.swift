import Testing
@testable import Switchyard

@Test
func stopAllWindowsAppsConfirmationRequestsAreIdempotent() {
    var state = StopAllWindowsAppsConfirmationState()

    #expect(!state.isPresented)

    state.request()
    state.request()

    #expect(state.isPresented)
}

@Test
func stopAllWindowsAppsConfirmationCancelDoesNotConfirm() {
    var state = StopAllWindowsAppsConfirmationState()

    state.request()
    state.cancel()
    let didConfirm = state.confirm()

    #expect(!state.isPresented)
    #expect(!didConfirm)
}

@Test
func stopAllWindowsAppsConfirmationCanOnlyBeConfirmedOncePerRequest() {
    var state = StopAllWindowsAppsConfirmationState()

    state.request()
    let firstConfirmation = state.confirm()
    let repeatedConfirmation = state.confirm()

    #expect(firstConfirmation)
    #expect(!state.isPresented)
    #expect(!repeatedConfirmation)
}
