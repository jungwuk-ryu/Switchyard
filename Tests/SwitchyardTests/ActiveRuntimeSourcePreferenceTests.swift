import Testing
@testable import Switchyard

@Test func appPinnedRuntimePreferenceUsesTheBundledSourceRevision() {
    let preference = ActiveRuntimeSourcePreference(storedValue: nil)

    #expect(preference == .appPinned)
    #expect(
        preference.expectedSourceRevision(pinnedRevision: "pinned-revision")
            == "pinned-revision"
    )
}

@Test func localDevelopmentRuntimePreferenceDisablesPinnedSourceFallback() {
    let preference = ActiveRuntimeSourcePreference(storedValue: "")

    #expect(preference == .localDevelopment)
    #expect(
        preference.expectedSourceRevision(pinnedRevision: "pinned-revision")
            == nil
    )
    #expect(preference.storedValue == "")
}

@Test func selectedRuntimePreferenceKeepsItsOwnSourceRevision() {
    let preference = ActiveRuntimeSourcePreference(
        storedValue: "selected-revision"
    )

    #expect(preference == .selectedRevision("selected-revision"))
    #expect(
        preference.expectedSourceRevision(pinnedRevision: "pinned-revision")
            == "selected-revision"
    )
}
