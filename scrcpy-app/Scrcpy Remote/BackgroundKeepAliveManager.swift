//
//  BackgroundKeepAliveManager.swift
//  Scrcpy Remote
//
//  When the app is backgrounded with an active scrcpy / VNC session, iOS
//  may suspend the process within seconds even though we declare the
//  'audio' UIBackgroundMode — because SDL's default AVAudioSession
//  category is .ambient (paused on lock, not allowed in background) and
//  scrcpy itself does not actively keep an audio source playing.
//
//  This manager owns a tiny AVAudioEngine that plays a near-silent
//  (-60 dB equivalent) looping buffer whenever:
//    - there is an active connection AND
//    - the user has set Background Active != never AND
//    - the app is in the background.
//
//  The audio session is configured with .playback + .mixWithOthers so
//  the silent tone coexists with any audio the Android device or VNC
//  session might be streaming. It's stopped (and the session
//  deactivated, notifying others) on disconnect or foreground.
//

import AVFoundation
import Combine
import Foundation
import UIKit

final class BackgroundKeepAliveManager: ObservableObject {
    static let shared = BackgroundKeepAliveManager()

    /// True when the silent-audio engine is currently running.
    @Published private(set) var silentAudioActive = false

    private var audioEngine: AVAudioEngine?
    private var silentPlayerNode: AVAudioPlayerNode?

    private var appIsInBackground = false
    private var sessionActive = false
    private var cancellables: Set<AnyCancellable> = []
    private var didSetup = false

    private init() {}

    /// Wire up notification observers. Idempotent.
    func setup() {
        guard !didSetup else { return }
        didSetup = true

        // Seed background state from the current scene activation so we
        // don't accidentally start silent audio if setup() happens to be
        // called when the app is already foreground / active.
        let state = UIApplication.shared.applicationState
        appIsInBackground = (state == .background)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.appIsInBackground = true
                self?.evaluate("didEnterBackground")
            }
            .store(in: &cancellables)

        // Foreground transitions: cover both willEnterForeground (sent
        // first as the scene leaves background) and didBecomeActive
        // (sent once the scene is fully foreground-active). Either one
        // must stop the silent-audio engine so we don't hold the audio
        // session while the user is interacting normally.
        let foregroundNotifications: [Notification.Name] = [
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification
        ]
        for name in foregroundNotifications {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    guard let self = self else { return }
                    self.appIsInBackground = false
                    self.evaluate("foreground:\(note.name.rawValue)")
                }
                .store(in: &cancellables)
        }

        // External media (Music, calls, …) interrupts our engine. When the
        // interruption ends, restart so we keep alive.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt }
            .filter { $0 == AVAudioSession.InterruptionType.ended.rawValue }
            .sink { [weak self] _ in
                // Brief delay so the foreign session releases first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let self = self else { return }
                    if self.silentAudioActive {
                        // Engine is silently dead; force-restart.
                        self.teardownEngineState()
                    }
                    self.evaluate("interruptionEnded")
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Session lifecycle hooks

    /// Called by SessionConnectionManager when a connection comes up.
    /// We configure the AVAudioSession here (NOT lazily on first
    /// backgrounding) so iOS already knows we are an "audio app" by
    /// the time the user puts us in the background — otherwise the
    /// system grants us only the default ~30 s background runtime
    /// budget and tears the connection down well before any silent
    /// audio could rescue it.
    func sessionConnected() {
        sessionActive = true
        configureSessionForKeepAlive(reason: "sessionConnected")
        evaluate("sessionConnected")
    }

    /// Idempotent AVAudioSession bring-up. .playback + .mixWithOthers
    /// is the combination that:
    ///   - qualifies us for the UIBackgroundModes=audio entitlement
    ///   - does NOT preempt any audio scrcpy / VNC is already playing
    private func configureSessionForKeepAlive(reason: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default,
                                     options: [.mixWithOthers])
            try session.setActive(true)
            print("🔋 BackgroundKeepAlive: session configured for keep-alive (reason=\(reason))")
        } catch {
            print("🔋 BackgroundKeepAlive: configure session FAILED (reason=\(reason)): \(error.localizedDescription)")
        }
    }

    /// Called by SessionConnectionManager when the session ends, either
    /// from a user action or a remote disconnect.
    func sessionDisconnected() {
        sessionActive = false
        evaluate("sessionDisconnected")
    }

    // MARK: - Evaluate state

    private func evaluate(_ reason: String) {
        // Run the silent engine for the ENTIRE lifetime of a session,
        // not just while backgrounded. Reason: iOS audits audio
        // background eligibility at the moment the app transitions to
        // background, and only grants extended runtime if there is
        // already a live audio session producing samples. Spinning up
        // AVAudioEngine from inside didEnterBackground is too late —
        // the system has already classified us as non-audio and only
        // gives ~30 s before the connection's TCP sockets get
        // suspended (which is exactly the failure mode in field
        // logs: "sockets.cpp:310 timeout expired while flushing
        // socket, closing").
        //
        // While in the foreground the silent buffer is inaudible and
        // mixWithOthers means we don't disturb the scrcpy / VNC audio
        // path. Stopping happens only when the session is torn down.
        let shouldPlay = sessionActive
        print("🔋 BackgroundKeepAlive evaluate(reason=\(reason)) → session=\(sessionActive) bg=\(appIsInBackground) playing=\(silentAudioActive) shouldPlay=\(shouldPlay)")

        if shouldPlay && !silentAudioActive {
            startSilentAudio()
        } else if !shouldPlay && silentAudioActive {
            stopSilentAudio()
        }
    }

    // MARK: - Silent audio engine

    private func startSilentAudio() {
        guard !silentAudioActive else { return }

        // Make sure the session is still .playback / .mixWithOthers in
        // case SDL or another sub-system reconfigured it after our
        // initial sessionConnected() setup.
        configureSessionForKeepAlive(reason: "startSilentAudio")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate) // 1s of silence, looped
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("🔋 BackgroundKeepAlive: failed to create silent buffer")
            return
        }
        buffer.frameLength = frameCount

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.001

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioEngine = engine
            silentPlayerNode = player
            silentAudioActive = true
            print("🔋 BackgroundKeepAlive: silent audio started")
        } catch {
            print("🔋 BackgroundKeepAlive: engine.start() failed: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        guard silentAudioActive else { return }
        teardownEngineState()

        // Release the audio session and let any paused background players
        // resume. Without notifyOthersOnDeactivation, Music etc. would
        // stay paused after we let go.
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("🔋 BackgroundKeepAlive setActive(false) FAILED: \(error.localizedDescription)")
        }
        print("🔋 BackgroundKeepAlive: silent audio stopped")
    }

    private func teardownEngineState() {
        silentPlayerNode?.stop()
        audioEngine?.stop()
        silentPlayerNode = nil
        audioEngine = nil
        silentAudioActive = false
    }
}
