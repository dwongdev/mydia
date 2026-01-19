import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Make the window look more native
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // Optional: hide traffic light buttons (close/minimize/zoom)
    // self.standardWindowButton(.closeButton)?.isHidden = true
    // self.standardWindowButton(.miniaturizeButton)?.isHidden = true
    // self.standardWindowButton(.zoomButton)?.isHidden = true

    super.awakeFromNib()
  }
}
