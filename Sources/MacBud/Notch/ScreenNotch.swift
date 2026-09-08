import AppKit

/// One collapsed notch per physical display. Each display measures its own notch rect, so the
/// silhouette, the tab wings and the toast all need their own window and their own canvas size.
@Observable
final class ScreenNotch: Identifiable {
    let displayID: CGDirectDisplayID
    var geometry: NotchGeometry
    var canvasSize: CGSize
    /// Only the display the user is working on renders toasts; the others stay idle.
    var isActive = false

    @ObservationIgnored let window: NotchBaseWindow
    @ObservationIgnored var host: ClickableHostingView<NotchBaseView>?

    var id: CGDirectDisplayID { displayID }

    init(geometry: NotchGeometry) {
        displayID = geometry.displayID
        self.geometry = geometry
        canvasSize = geometry.notchRect.size
        window = NotchBaseWindow(contentRect: geometry.notchRect)
    }
}
