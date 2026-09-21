import SwiftUI

@main
struct GabbroApp: App {
    @State private var model = CaptureModel.shared

    var body: some Scene {
        WindowGroup {
            CaptureView()
                .environment(model)
                .task { await model.bootstrap() }
        }
    }
}
