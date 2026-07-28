import Foundation
import Testing
@testable import Switchyard

@Test
func appUpdateConfigurationRequiresAnExplicitSecureConfiguration() {
    let disabled = AppUpdateConfiguration(infoDictionary: [:])
    #expect(!disabled.isUsable)

    let insecureURL = AppUpdateConfiguration(
        infoDictionary: [
            "SwitchyardUpdatesEnabled": true,
            "SUFeedURL": "http://example.test/appcast.xml",
            "SUPublicEDKey": "mzrMz2wukRl+HaXCsPXXODj0BoAmMSBMj5w8ZwYWOvg="
        ]
    )
    #expect(!insecureURL.isUsable)

    let invalidKey = AppUpdateConfiguration(
        infoDictionary: [
            "SwitchyardUpdatesEnabled": true,
            "SUFeedURL": "https://example.test/appcast.xml",
            "SUPublicEDKey": "not-an-ed25519-public-key"
        ]
    )
    #expect(!invalidKey.isUsable)

    let enabled = AppUpdateConfiguration(
        infoDictionary: [
            "SwitchyardUpdatesEnabled": true,
            "SUFeedURL": "https://example.test/appcast.xml",
            "SUPublicEDKey": "mzrMz2wukRl+HaXCsPXXODj0BoAmMSBMj5w8ZwYWOvg="
        ]
    )
    #expect(enabled.isUsable)
}
