import ServiceManagement

/// Whether macOS starts Pashari when the user logs in.
///
/// `SMAppService` is the system's registry of login items. The same setting
/// shows up under General > Login Items in System Settings.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
