import SwiftUI
import UIKit

/// `UIActivityViewController` with a real completion handler.
///
/// SwiftUI's `ShareLink` cannot tell you whether the user actually completed
/// a share, and the obvious workaround — hanging a `.simultaneousGesture` off
/// it to find out — is worse than useless. The gesture competes with the
/// link's own activation, so the first tap marks the note shared and never
/// presents the sheet at all. That was the observed bug.
///
/// Knowing whether the share completed is not a nicety here: `markShared`
/// drives the duplicate warning, and Obsidian's picker will happily create a
/// second note if you share the same file twice.
///
/// The item is a **file URL**, deliberately. Handing over `Data` or a
/// `String` loses the filename and can route the receiving extension down a
/// different branch. Confirmed on device 2026-09-21: a shared `.md` becomes a
/// note, not an attachment.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// `true` only when the user completed a share, not when they dismissed.
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
