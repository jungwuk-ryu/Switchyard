import AppCore

extension InstalledProgram {
    var presentationName: String {
        switch name.lowercased() {
        case "chrome": "Google Chrome"
        case "iexplore": "Internet Explorer"
        case "wmplayer": "Windows Media Player"
        case "googleupdate": "Google Update"
        default: name
        }
    }

    var isSystemUtility: Bool {
        let normalized = name.lowercased()
        return [
            "drivers", "googleupdate", "iexplore", "wmplayer",
            "winecfg", "regedit", "uninstaller",
        ].contains(normalized)
    }
}
