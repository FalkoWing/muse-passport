import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Also runs when the system relaunches the app in the background for a
        // Bluetooth event, so the bridge must come up without any window.
        Companion.shared.start()
        return true
    }
}

@main
struct MusePassportApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { ContentView(companion: Companion.shared) }
    }
}
