import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Retained so its method-channel handler stays alive for the app's lifetime.
  private var videoExporter: VideoExporter?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    videoExporter = VideoExporter(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
