import Flutter
import UIKit
import AVKit

/// Platform channel handler for AirPlay integration.
///
/// This class manages the communication between Flutter and native iOS
/// AirPlay functionality using AVRoutePickerView.
class AirPlayChannelHandler: NSObject, FlutterPlugin {
    private static let channelName = "com.mydia.player/airplay"
    private var channel: FlutterMethodChannel?
    private var routePickerView: AVRoutePickerView?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = AirPlayChannelHandler()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Set up route detection observer
        instance.setupRouteObserver()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(isAirPlayAvailable())

        case "showRoutePicker":
            showRoutePicker(result: result)

        case "disconnect":
            disconnect(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Check if AirPlay is available on this device.
    private func isAirPlayAvailable() -> Bool {
        // AirPlay is available on all iOS devices, but we can check
        // if there are any external playback routes available
        return AVAudioSession.sharedInstance().isOtherAudioPlaying ||
               AVAudioSession.sharedInstance().currentRoute.outputs.count > 0
    }

    /// Show the native AirPlay route picker.
    private func showRoutePicker(result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result(FlutterError(
                    code: "UNAVAILABLE",
                    message: "AirPlay handler not available",
                    details: nil
                ))
                return
            }

            // Create or reuse route picker view
            if self.routePickerView == nil {
                self.routePickerView = AVRoutePickerView()
                self.routePickerView?.prioritizesVideoDevices = true
            }

            // Programmatically trigger the route picker
            if let routeButton = self.routePickerView?.subviews.first(
                where: { $0 is UIButton }
            ) as? UIButton {
                routeButton.sendActions(for: .touchUpInside)
                result(nil)
            } else {
                result(FlutterError(
                    code: "FAILED",
                    message: "Could not trigger route picker",
                    details: nil
                ))
            }
        }
    }

    /// Disconnect from current AirPlay device.
    private func disconnect(result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            // To disconnect, we need to route back to the device speaker
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default)
                try audioSession.overrideOutputAudioPort(.none)
                result(nil)
            } catch {
                result(FlutterError(
                    code: "FAILED",
                    message: "Could not disconnect from AirPlay",
                    details: error.localizedDescription
                ))
            }
        }
    }

    /// Set up observer for route changes.
    private func setupRouteObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// Handle audio route change notifications.
    @objc private func audioRouteChanged(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let channel = self.channel else { return }

            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable:
                // Get the current route
                let currentRoute = AVAudioSession.sharedInstance().currentRoute
                let outputs = currentRoute.outputs

                // Check if we're connected to AirPlay
                let airPlayOutput = outputs.first { output in
                    output.portType == .airPlay
                }

                if let airPlayDevice = airPlayOutput {
                    // Connected to AirPlay
                    channel.invokeMethod("onRouteChanged", arguments: [
                        "routeName": airPlayDevice.portName
                    ])
                } else {
                    // Disconnected from AirPlay
                    channel.invokeMethod("onRouteChanged", arguments: [
                        "routeName": nil
                    ])
                }

            default:
                break
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
