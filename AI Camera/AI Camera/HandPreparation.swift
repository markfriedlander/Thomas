//
//  HandPreparation.swift
//  Thomas
//
//  Preparing the Core ML hand for this iPhone's Neural Engine, as a visible step right after the
//  download (and once after each app update), instead of a surprise wait in the middle of a shot.
//

import CoreML
import Foundation
import MachO
import SwiftUI
import UIKit

// ==== LEGO START: 41 Preparing The Hand (Download, Then Prepare) ====

/// The first time a Core ML model runs on a phone, Apple's Core ML prepares it for the Neural Engine
/// and caches the result in the app's Caches folder. Measured on iPhone 16 Plus (2026-11-12): 84 s
/// and about 1.1 GB written the first time; afterwards a load takes about 1 s and a whole shot writes
/// 10-30 MB. The preparation repeats after every install or update of the app.
///
/// Mark (2026-11-12): make it part of the download. When the hand finishes downloading, Thomas
/// prepares it right away and says so ("Preparing for shooting"), so the wait is one continuous,
/// expected thing; after an app update it does the same once when the camera opens. Honest progress
/// only: Core ML reports no percentage, so the card shows the real stages (each sub-model is
/// prepared separately), an elapsed clock, and, from the second time on, how long it took last time
/// on THIS phone. Nothing about it leaves the phone.
@MainActor @Observable
final class HandPreparation {
    static let shared = HandPreparation()

    enum Phase: Equatable { case idle, preparing, done, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var repoID: String?
    private(set) var stage = 0
    private(set) var stageCount = 0
    private(set) var stageName = ""
    private(set) var started: Date?
    private(set) var reason = ""
    /// Ticks once a second while preparing, so clocks redraw.
    private(set) var now = Date()
    private var ticker: Task<Void, Never>?

    private init() {
        // Remember when Thomas last went to the background, so a timing taken across it isn't kept
        // as "how long this takes" (see markPrepared). Registered here because the camera screen
        // touches `shared` at launch (prepareAfterLaunchIfNeeded).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { _ in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "handPrepLastBackgrounded")
        }
    }

    var isPreparing: Bool { phase == .preparing }
    var elapsed: TimeInterval { started.map { now.timeIntervalSince($0) } ?? 0 }

    /// "0:42", "1:24".
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: What has been prepared (kept on the phone, in UserDefaults)

    /// This build of the app. Core ML's cache does not survive an install or update, so a
    /// preparation counts only for the build that made it.
    ///
    /// The version alone was not enough (2026-11-13): a test install keeps the same version number, so
    /// the after-launch preparation never ran and the next shot paid for it mid-shot (91 s, 1.1 GB
    /// written). The compiled code's own identity (its LC_UUID, new with every build) is added, so any
    /// new build is recognized; an App Store update changes both anyway.
    nonisolated static var currentBuild: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?")) \(binaryID.prefix(8))"
    }

    /// The UUID the linker stamped on the code this function lives in (`#dsohandle` is that image's
    /// header, which in a Debug build is the app's debug library rather than its small launcher).
    nonisolated private static let binaryID: String = {
        let base = UnsafeRawPointer(#dsohandle)
        let header = base.load(as: mach_header_64.self)
        var cursor = base.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.ncmds {
            let command = cursor.load(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                return UUID(uuid: cursor.load(as: uuid_command.self).uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return "unknown"
    }()

    nonisolated static func isPrepared(_ repoID: String) -> Bool {
        UserDefaults.standard.string(forKey: "handPreparedFor.\(repoID)") == currentBuild
    }

    /// How long the last preparation of this hand took on this phone, if one was ever timed.
    nonisolated static func lastSeconds(_ repoID: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: "handPrepSeconds.\(repoID)")
        return v > 0 ? v : nil
    }

    /// Record that this build's hand is prepared. Also called by `CoreMLDrawer` after any successful
    /// load, so a shot that happened to do the preparation counts too. `seconds` is stored only for a
    /// load slow enough to have been a real preparation.
    nonisolated static func markPrepared(_ repoID: String, seconds: Double?) {
        UserDefaults.standard.set(currentBuild, forKey: "handPreparedFor.\(repoID)")
        // Keep the time only when Thomas stayed in front the whole way. A phone call during the
        // preparation (Mark, 2026-11-13) sent Thomas to the background, where iOS gives it little
        // time: it took 7:48 instead of about 1:30, and that would have become the next "of about".
        let backgrounded = UserDefaults.standard.double(forKey: "handPrepLastBackgrounded")
        if let seconds, seconds > 20,
           backgrounded < Date().timeIntervalSince1970 - seconds {
            UserDefaults.standard.set(seconds, forKey: "handPrepSeconds.\(repoID)")
        }
    }

    #if DEBUG
    /// Antenna only: forget that this build was prepared, to exercise the after-update path.
    nonisolated static func forget(_ repoID: String) {
        UserDefaults.standard.removeObject(forKey: "handPreparedFor.\(repoID)")
    }
    #endif

    // MARK: Preparing

    /// Prepare `repoID` now, through the model lane (one heavy job at a time). No-op if it is not a
    /// downloaded Core ML hand, or a preparation is already running.
    func prepare(_ repoID: String, reason: String) async {
        guard !isPreparing, ModelCatalog.model(id: repoID)?.engine == .coreML,
              CoreMLDrawer.isInstalled(repoID) else { return }
        self.repoID = repoID; self.reason = reason
        phase = .preparing; stage = 0; stageCount = 0; stageName = "Getting ready"
        started = Date(); now = Date()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.now = Date()
                self?.publishPill()
            }
        }
        publishPill()
        let bundlesBefore = await Task.detached { e5rtFinishedBundles() }.value
        cameraLog("PREPARE: \(repoID) (\(reason)) \(writesLine())")
        let result: Result<Double, Error> = await ModelLane.shared.run("prepare") {
            do {
                let seconds = try await CoreMLDrawer.shared.prepare(repoID: repoID) { k, n, name in
                    Task { @MainActor in
                        HandPreparation.shared.stage = k
                        HandPreparation.shared.stageCount = n
                        HandPreparation.shared.stageName = name
                        HandPreparation.shared.publishPill()
                    }
                }
                return .success(seconds)
            } catch {
                return .failure(error)
            }
        }
        ticker?.cancel(); ticker = nil
        switch result {
        case .success(let seconds):
            Self.markPrepared(repoID, seconds: seconds)
            await Task.detached { reapStalePreparations(existingBefore: bundlesBefore, preparedSeconds: seconds) }.value
            phase = .done
            cameraLog("PREPARE: done in \(Self.clock(seconds)) \(writesLine())")
        case .failure(let error):
            // Not fatal: the first shot will prepare it instead, as before.
            phase = .failed(error.localizedDescription)
            cameraLog("PREPARE: did not complete (\(error.localizedDescription)); the first shot will prepare it")
        }
        StatusFeed.shared.clear(.hand)
    }

    /// After an install or update: once the camera has settled, prepare the selected Core ML hand if
    /// this build has not. Deferred and memory-gated on purpose: warming the model as the app's first
    /// work was killed by iOS for memory in July (AI_CameraApp: "PRE-WARM AT LAUNCH DISABLED").
    func prepareAfterLaunchIfNeeded() async {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let s = Settings.shared
        let repo = s.selectedDrawer
        guard s.drawsThirdFrame, ModelCatalog.model(id: repo)?.engine == .coreML,
              CoreMLDrawer.isInstalled(repo), !Self.isPrepared(repo), !isPreparing else { return }
        let available = processAvailableMemoryMB()
        guard available > 2500 else {
            cameraLog("PREPARE: after-launch preparation skipped, only \(formatMB(available)) MB free; the first shot will prepare it")
            return
        }
        await prepare(repo, reason: "after install or update")
    }

    /// The capture screen's status pill while preparing.
    private func publishPill() {
        guard isPreparing, let repoID else { return }
        var text = "Preparing for shooting · \(Self.clock(elapsed))"
        if let last = Self.lastSeconds(repoID) { text += " of about \(Self.clock(last))" }
        StatusFeed.shared.publish(StatusMessage(kind: .hand, icon: nil, showsSpinner: true, text: text,
                                                tap: .explainPreparation))
    }
}

/// The preparation, as the Model Library row shows it: what is happening, the real stage, the clock,
/// and what to do (keep Thomas open). Honest: no invented percentage.
struct HandPreparationCard: View {
    let repoID: String
    @State private var prep = HandPreparation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing for shooting").font(.subheadline.weight(.medium))
                Spacer()
                Text(HandPreparation.clock(prep.elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if prep.stageCount > 0 {
                Text("Step \(prep.stage) of \(prep.stageCount): \(prep.stageName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        if let last = HandPreparation.lastSeconds(repoID) {
            return "Your \(ThisDevice.deviceKind) is getting the drawing model ready for its Neural Engine. Last time this took \(HandPreparation.clock(last)) on this \(ThisDevice.deviceKind). Keep Thomas open until it finishes."
        }
        return "Your \(ThisDevice.deviceKind) is getting the drawing model ready for its Neural Engine. This takes a few minutes the first time, and happens once. Keep Thomas open until it finishes."
    }
}

/// Clear away what an interrupted preparation left behind: Core ML writes its prepared model into a
/// temporary bundle in Caches/com.apple.e5rt.e5bundlecache and only then makes it permanent, so a
/// preparation cut short (phone locked, app killed) can leave a large ".tmp" bundle that nothing will
/// ever use. Run once per launch, before any model loads (AI_CameraApp.init). Only temporary bundles
/// are touched; the finished cache is left alone, so a prepared hand stays prepared.
nonisolated func reapInterruptedPreparations() {
    let fm = FileManager.default
    var doomed: [URL] = []
    for root in e5rtCacheRoots() {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
        for case let url as URL in walker where url.lastPathComponent.contains(".tmp.") {
            doomed.append(url)
            walker.skipDescendants()
        }
    }
    for url in doomed {
        let bytes = NegativeStore.size(of: url)
        do {
            try fm.removeItem(at: url)
            cameraLog("PREPARE: cleared an interrupted preparation's leftovers (\(NegativeStore.formatBytes(bytes)))")
        } catch {
            cameraLog("PREPARE: could not clear \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

/// Where Core ML keeps its prepared models for this app. Measured on the phone (2026-11-12, GET
/// /caches): Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache/<OS build>/<model hash>/<bundle>.
/// The top-level spelling is checked too, in case another OS puts it there.
nonisolated func e5rtCacheRoots() -> [URL] {
    let fm = FileManager.default
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
    let id = Bundle.main.bundleIdentifier ?? "com.MarkFriedlander.AI-Camera"
    return [caches.appendingPathComponent(id).appendingPathComponent("com.apple.e5rt.e5bundlecache"),
            caches.appendingPathComponent("com.apple.e5rt.e5bundlecache")]
        .filter { fm.fileExists(atPath: $0.path) }
}

/// The finished prepared-model bundles Core ML holds for this app (outermost ".bundle" folders,
/// never the temporary ones).
nonisolated func e5rtFinishedBundles() -> Set<URL> {
    var found = Set<URL>()
    for root in e5rtCacheRoots() {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
        for case let url as URL in walker where url.pathExtension == "bundle" {
            if !url.lastPathComponent.contains(".tmp.") { found.insert(url.standardizedFileURL) }
            walker.skipDescendants()
        }
    }
    return found
}

/// After a real preparation (one that took long enough to have built new bundles), remove the
/// finished bundles that existed before it started: they were prepared for an earlier build of the
/// app and Core ML will never use them again (measured: each install left its ~97 MB copy behind).
/// A piece the new build still shared would simply be prepared again on its next load.
nonisolated func reapStalePreparations(existingBefore: Set<URL>, preparedSeconds: Double) {
    guard preparedSeconds > 20 else { return }
    let current = e5rtFinishedBundles()
    let fresh = current.subtracting(existingBefore)
    guard !fresh.isEmpty else { return }
    for url in existingBefore where current.contains(url) {
        let bytes = NegativeStore.size(of: url)
        if (try? FileManager.default.removeItem(at: url)) != nil {
            cameraLog("PREPARE: removed an earlier build's prepared copy (\(NegativeStore.formatBytes(bytes)))")
        }
    }
}

// ==== LEGO END: 41 Preparing The Hand (Download, Then Prepare) ====
