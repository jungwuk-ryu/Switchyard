@testable import Switchyard
import Testing

@Test func onlyActiveWineServerStateReportsWineServerRunning() {
    #expect(WineServerState.active.isWineServerRunning)
    #expect(!WineServerState.checking.isWineServerRunning)
    #expect(!WineServerState.orphaned.isWineServerRunning)
    #expect(!WineServerState.inactive.isWineServerRunning)
    #expect(!WineServerState.unavailable.isWineServerRunning)
}
