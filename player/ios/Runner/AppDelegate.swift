import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Configure audio session for AirPlay
    configureAudioSession()

    // Register AirPlay platform channel
    if let controller = window?.rootViewController as? FlutterViewController {
      AirPlayChannelHandler.register(with: registrar(forPlugin: "AirPlayChannelHandler")!)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func configureAudioSession() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // Set category to playback to enable AirPlay
      try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
      try audioSession.setActive(true)
    } catch {
      print("Failed to configure audio session for AirPlay: \(error)")
    }
  }
}
