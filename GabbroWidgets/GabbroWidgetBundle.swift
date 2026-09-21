import SwiftUI
import WidgetKit

@main
struct GabbroWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordingControl()
    }
}
