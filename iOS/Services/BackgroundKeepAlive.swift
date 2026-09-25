import AVFoundation
import CoreLocation

/// Keeps the app running in the background while it spoofs this phone itself.
///
/// On-device spoofing rides one connection, and iOS only lets that connection
/// be *opened* on Wi-Fi — the phone's pairing service refuses new ones on
/// cellular. One opened on Wi-Fi keeps working after you leave, but only
/// while this app is alive to hold it. Suspended, the connection dies, and
/// the next change of location needs a new one that cellular will refuse.
///
/// Two mechanisms, as StikDebug uses, because either alone can lapse:
/// background location updates (which need location permission, and show the
/// blue pill), and a silent audio loop mixed with other audio (which needs no
/// permission and survives the location one being refused).
@MainActor
final class BackgroundKeepAlive {
    private let manager = CLLocationManager()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var interruptionObserver: NSObjectProtocol?
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true

        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()

        startSilence()
        // A call or another app taking the audio session stops the loop; take
        // it back when the interruption ends.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.startSilence()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startSilence() {
        do {
            player.stop()
            engine.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)

            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            // A second of zeroes, looped: silence that keeps the session live.
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                buffer.frameLength = buffer.frameCapacity
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            try engine.start()
            player.play()
        } catch {
            // Background location still holds the app; nothing to surface.
        }
    }
}
