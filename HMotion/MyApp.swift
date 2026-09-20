import SwiftUI

@main
struct HMotionApp: App {
    @State private var controller = HeadTrackingController()

    var body: some Scene {
        // `LSUIElement` keeps the app out of the Dock; the menu bar item is the
        // only UI, and motion updates keep flowing while the panel is closed.
        MenuBarExtra {
            ControlPanelView(controller: controller)
        } label: {
            Image(systemName: controller.statusSymbolName)
        }
        .menuBarExtraStyle(.window)
    }
}
