//
//  IPhoneOrientationSync.swift
//  Scrcpy Remote
//
//  Event-driven synchronization of the iPhone's physical orientation with an
//  Android ADB session. No polling and no changes to Android display size.
//

import Foundation
import UIKit

/// Keeps one ADB session in sync with the iPhone's physical orientation.
/// All mutable state is confined to the main queue. ADB callbacks return to
/// that queue before updating state.
final class IPhoneOrientationSync {
    static let shared = IPhoneOrientationSync()

    private struct OriginalRotation {
        let automatic: Bool
        let rotation: Int
    }

    private var sessionID: UUID?
    private var serial: String?
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private var originalRotation: OriginalRotation?
    private var ready = false
    private var stopping = false
    private var restoring = false
    private var sending = false
    private var attemptedChange = false
    private var desiredRotation: Int?
    private var appliedRotation: Int?
    private var pendingChange: DispatchWorkItem?
    private var stopCompletions: [() -> Void] = []

    private init() {}

    /// Starts after the ADB video window is connected. Repeated calls for the
    /// same session (e.g. window-created and window-appeared events) are safe.
    func start(sessionID: UUID, serial: String) {
        assert(Thread.isMainThread)

        if self.sessionID == sessionID, self.serial == serial, !stopping {
            return  // Duplicate window-created/appeared notifications.
        }

        guard self.sessionID == nil else {
            stop { [weak self] in self?.start(sessionID: sessionID, serial: serial) }
            return
        }

        self.sessionID = sessionID
        self.serial = serial
        generation = UUID()
        ready = false
        stopping = false
        restoring = false
        sending = false
        attemptedChange = false
        appliedRotation = nil
        desiredRotation = nil
        originalRotation = nil

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deviceOrientationChanged()
        }

        // Snapshot BEFORE modifying Android. Don't override the remote device
        // if its original rotation mode cannot be read and later restored.
        let token = generation
        execute(["-s", serial, "shell", "settings", "get", "system", "accelerometer_rotation"]) { [weak self] automaticOutput, automaticCode in
            guard let self = self, self.generation == token, !self.stopping else { return }
            let automaticText = automaticOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard automaticCode == 0, let automaticText = automaticText,
                  automaticText == "0" || automaticText == "1" else {
                self.failToStart("Cannot read Android auto-rotation setting")
                return
            }

            self.execute(["-s", serial, "shell", "settings", "get", "system", "user_rotation"]) { [weak self] rotationOutput, rotationCode in
                guard let self = self, self.generation == token, !self.stopping else { return }
                let rotationText = rotationOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard rotationCode == 0, let rotationText = rotationText,
                      let rotation = Int(rotationText), (0...3).contains(rotation) else {
                    self.failToStart("Cannot read Android's original rotation")
                    return
                }
                self.originalRotation = OriginalRotation(automatic: automaticText == "1", rotation: rotation)
                self.ready = true
                self.synchronizeNow(force: true)
            }
        }
    }

    /// Called on foreground/reopen; re-applies the current iPhone orientation
    /// in case the remote device changed while the app was suspended.
    func resume() {
        assert(Thread.isMainThread)
        synchronizeNow(force: true)
    }

    /// Finishes pending rotation before restoring Android's previous mode.
    /// The completion runs only after the restoration attempt, so callers can
    /// close the ADB connection without racing the final command.
    func stop(completion: @escaping () -> Void = {}) {
        assert(Thread.isMainThread)
        guard sessionID != nil else {
            completion()
            return
        }
        stopCompletions.append(completion)
        guard !stopping else { return }

        stopping = true
        pendingChange?.cancel()
        pendingChange = nil
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

        if !sending {
            finishStop()
        }
    }

    private func failToStart(_ reason: String) {
        print("[iPhoneOrientationSync] \(reason); leaving Android rotation unchanged.")
        stop()
    }

    private func deviceOrientationChanged() {
        guard !stopping, ready, UIApplication.shared.applicationState == .active,
              let rotation = Self.rotation(for: UIDevice.current.orientation) else { return }

        // Ignore face-up, face-down and unknown readings, and coalesce a burst
        // of sensor notifications into one ADB command.
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.desiredRotation = rotation
            self?.sendIfNeeded()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func synchronizeNow(force: Bool) {
        guard ready, !stopping, UIApplication.shared.applicationState == .active else { return }
        pendingChange?.cancel()
        pendingChange = nil
        if force { appliedRotation = nil }

        // At startup the sensor can be .unknown; use the visible scene's
        // orientation as a fallback, then portrait if neither is available.
        desiredRotation = Self.rotation(for: UIDevice.current.orientation)
            ?? Self.currentInterfaceRotation()
            ?? 0
        sendIfNeeded()
    }

    private func sendIfNeeded() {
        guard ready, !stopping, !sending,
              let rotation = desiredRotation, rotation != appliedRotation,
              let serial = serial else { return }

        sending = true
        attemptedChange = true
        let token = generation
        execute(["-s", serial, "shell", "cmd", "window", "user-rotation", "lock", String(rotation)]) { [weak self] output, code in
            guard let self = self, self.generation == token else { return }
            self.sending = false
            if code == 0 {
                self.appliedRotation = rotation
            } else {
                print("[iPhoneOrientationSync] Rotation command failed: \(output ?? "unknown error")")
            }

            if self.stopping {
                self.finishStop()
            } else if code == 0, self.desiredRotation != rotation {
                // A newer orientation arrived during the in-flight command.
                self.sendIfNeeded()
            }
        }
    }

    private func finishStop() {
        guard stopping, !sending, !restoring else { return }
        restoring = true
        guard attemptedChange, let restoreSerial = serial,
              let restoreState = originalRotation else {
            completeStop()
            return
        }

        let arguments = restoreState.automatic
            ? ["-s", restoreSerial, "shell", "cmd", "window", "user-rotation", "free"]
            : ["-s", restoreSerial, "shell", "cmd", "window", "user-rotation", "lock", String(restoreState.rotation)]
        execute(arguments) { [weak self] output, code in
            if code != 0 {
                print("[iPhoneOrientationSync] Could not restore Android rotation: \(output ?? "unknown error")")
            }
            self?.completeStop()
        }
    }

    private func completeStop() {
        let callbacks = stopCompletions
        stopCompletions = []
        sessionID = nil
        serial = nil
        originalRotation = nil
        desiredRotation = nil
        appliedRotation = nil
        ready = false
        stopping = false
        restoring = false
        attemptedChange = false
        generation = UUID()
        callbacks.forEach { $0() }
    }

    private func execute(_ arguments: [String], completion: @escaping (String?, Int32) -> Void) {
        ADBClient.shared().executeADBCommandAsync(arguments) { output, returnCode in
            DispatchQueue.main.async {
                completion(output, Int32(returnCode))
            }
        }
    }

    /// Android Surface.ROTATION_* values for physical iPhone orientations.
    static func rotation(for orientation: UIDeviceOrientation) -> Int? {
        switch orientation {
        case .portrait: return 0
        case .landscapeLeft: return 1
        case .portraitUpsideDown: return 2
        case .landscapeRight: return 3
        default: return nil
        }
    }

    private static func currentInterfaceRotation() -> Int? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        switch scene?.interfaceOrientation {
        case .portrait: return 0
        case .landscapeRight: return 1
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return 3
        default: return nil
        }
    }
}
