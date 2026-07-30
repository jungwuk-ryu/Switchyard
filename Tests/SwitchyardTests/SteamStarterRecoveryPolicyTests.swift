import AppCore
import Testing
@testable import Switchyard

@Suite("Steam Starter Recovery Policy")
struct SteamStarterRecoveryPolicyTests {
    @Test("system utilities do not hide incomplete Steam setup")
    func systemUtilitiesDoNotCompleteSteamSetup() {
        let programs = [
            InstalledProgram(
                name: "Internet Explorer",
                executablePath:
                    #"/containers/Steam.container/drive_c/Program Files/Internet Explorer/iexplore.exe"#,
                installDirectory:
                    #"/containers/Steam.container/drive_c/Program Files/Internet Explorer"#,
                source: .programFiles
            ),
        ]

        #expect(
            SteamStarterRecoveryPolicy.needsRecovery(
                starterApplicationID: StarterApplicationCatalog.steam.id,
                installedPrograms: programs
            )
        )
    }

    @Test("recognized Steam program completes guided setup")
    func recognizedSteamCompletesGuidedSetup() {
        let programs = [
            InstalledProgram(
                name: "Internet Explorer",
                executablePath:
                    #"/containers/Steam.container/drive_c/Program Files/Internet Explorer/iexplore.exe"#,
                installDirectory:
                    #"/containers/Steam.container/drive_c/Program Files/Internet Explorer"#,
                source: .programFiles
            ),
            InstalledProgram(
                name: "Steam",
                executablePath:
                    #"/containers/Steam.container/drive_c/Program Files (x86)/Steam/steam.exe"#,
                installDirectory:
                    #"/containers/Steam.container/drive_c/Program Files (x86)/Steam"#,
                source: .programFiles
            ),
        ]

        #expect(
            !SteamStarterRecoveryPolicy.needsRecovery(
                starterApplicationID: StarterApplicationCatalog.steam.id,
                installedPrograms: programs
            )
        )
    }

    @Test("non-Steam containers never show Steam recovery")
    func nonSteamContainersDoNotOfferSteamRecovery() {
        #expect(
            !SteamStarterRecoveryPolicy.needsRecovery(
                starterApplicationID: nil,
                installedPrograms: []
            )
        )
        #expect(
            !SteamStarterRecoveryPolicy.needsRecovery(
                starterApplicationID: StarterApplicationCatalog.battleNet.id,
                installedPrograms: []
            )
        )
    }
}
