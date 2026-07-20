// ==== LEGO START: 1 App Entry ====
//
//  AI_CameraApp.swift — AI Camera's entry point.
//
//  A camera whose film is language. See CLAUDE.md for what that means and
//  HISTORY.md for why every decision below was made the way it was.
//
//  ============================================================
//  MASTER LEGO INDEX
//  Every source file and every LEGO block, in canonical order.
//  Blocks form a single gapless sequence, numbered from 1.
//  scripts/validate_lego.py keeps this index honest against the real
//  markers — run it after touching any block boundary.
//  ============================================================
//
//  AI_CameraApp.swift
//    1  App Entry
//
//  Seeing.swift
//    2  Perception (What The Machine Did)
//    3  Readiness (Whether The Machine Can See)
//    4  Eye (How The Machine Looks)
//    5  Measuring What A Look Costs
//
//  ContentView.swift
//    6  ContentView (Steel-Thread Scaffolding)
//    7  PerceptionView (Showing What The Machine Did)
//    8  The Orientation Trap
//
//  ModelLane.swift
//    9  The Model Lane (Serialization + Settle)
//
//  Services/LocalAPI/LocalAPIServer.swift
//   10  The Antenna (Class, Token, Address)
//   11  HTTP Plumbing (Parse, Respond)
//   12  Routes (Dispatch)
//
//  Camera.swift
//   13  Lens (Capture)
//   14  Place (Reality's Receipt)
//
//  SharedModelStore.swift
//   15  Shared Model Store (App-Group Paths)
//   16  Shared Model Store (Refcount Manifest)
//   17  Shared Model Store (Cross-App Download Lock)
//
//  Qwen.swift
//   18  Qwen (The Unguarded Eye)
//
//  Developing.swift
//   19  The Darkroom (Compositor)
//
//  CameraView.swift
//   20  Viewfinder
//   21  CameraView (The Sacred Screen)
//   22  Seer (Which Eye Is Loaded)
//
//  Preferences.swift
//   23  Settings (What The Camera Is Loaded With)
//   24  PreferencesView (The Film Drawer)
//
//  ProcessMemoryGuard.swift
//   25  ProcessMemoryGuard (Load-Time Memory Headroom)
//
//  MLXModelDownloader.swift
//   26  The Downloader (Fetching Weights)
//
//  ModelCatalog.swift
//   27  Model Catalog (What The Camera Can Load)
//
//  ModelLibraryView.swift
//   28  ModelLibraryView (The Model Library)
//
//  Drawing.swift
//   29  The Hand (Frame 3 — Drawing From Words)
//
//  Shot.swift
//   30  The Shot (One Press, All Three Frames)
//
//  Upscaler.swift
//   31  The Upscaler (Making The Drawing Bigger)
//
//  TAESD.swift
//   32  TAESD (A Tiny, Low-Memory Decoder For The Drawing)
//
//  About.swift
//   33  About (Who Made This, And On Whose Shoulders)
//
//  ThermalGovernor.swift
//   34  ThermalGovernor (Backing Off When The Phone Runs Hot)
//
//  DarkRoomQueue.swift
//   35  The Dark Room Queue (Durable Developing)
//
//  Created by Mark Friedlander on 7/14/26.
//

import SwiftUI
import UIKit

/// Bridges the one UIKit lifecycle method SwiftUI doesn't expose.
///
/// **Without this, background downloads silently never finish.** A 1.75 GB model does not
/// download while the user watches — they leave, iOS suspends or outright terminates the
/// app, and the transfer continues in the OS. When it lands, iOS **relaunches the app** and
/// calls `handleEventsForBackgroundURLSession` to say so. SwiftUI's `App` lifecycle has no
/// equivalent hook, so a pure-SwiftUI app has no way to hear it: the download completes and
/// nothing is ever told. `UIApplicationDelegateAdaptor` is the only bridge.
///
/// Lifted from Hal's `HalAppDelegate` — **only this one method.** Hal's delegate also does
/// embedding-backend crash guards, maintenance GC, and an `MLX_METAL_GPU_ARCH` workaround
/// that are Hal's own history, not ours. See the note in NEXT.md about that env var; it is
/// a real open question and not one to answer by copying on a hunch.
final class CameraAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        cameraLog("DOWNLOAD: app woken by iOS for background session id=\(identifier)")
        if identifier == BackgroundDownloadCoordinator.backgroundSessionID {
            // Hand it to the coordinator; it calls this back once every queued completion
            // callback has been processed. Calling it early tells iOS we're done when we
            // aren't, and it stops delivering.
            BackgroundDownloadCoordinator.shared.backgroundCompletionHandler = completionHandler
        } else {
            // Not our session. Answer immediately — iOS blocks waiting on this.
            completionHandler()
        }
    }
}

@main
struct AI_CameraApp: App {

    @UIApplicationDelegateAdaptor(CameraAppDelegate.self) var appDelegate

    /// Backgrounding is the moment iOS decides who to kill.
    ///
    /// A camera holding 1.75 GB of Qwen while the user reads a text message is a prime
    /// jetsam target — it comes back dead, or not at all. Hal has unloaded on background
    /// for years; AI Camera shipped without it because `unload()` was a stub nobody
    /// called. Wired here, at app level, for the same reason the antenna is: a view can
    /// stop being shown and take its lifecycle hooks with it silently. There is no view
    /// this can be orphaned from.
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    /// The antenna starts with the APP, not with a view.
    ///
    /// It used to auto-start in `ContentView.onAppear` — and then CameraView became the
    /// root, ContentView stopped being shown, and the antenna silently never started.
    /// CC spent the next stretch guessing at a rotation bug with no instrument, because
    /// the instrument was wired to a screen nobody looks at any more. App-level: there is
    /// no view it can be orphaned from. Still compiled out of Release entirely.
    init() { LocalAPIServer.shared.start() }
    #endif

    var body: some Scene {
        WindowGroup {
            // The camera IS the app. ContentView is the old steel-thread scaffolding —
            // still reachable from the antenna's own screen for characterization work,
            // but it is not what this app is.
            CameraView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // ⭐ RESUME — the whole crash/background/call/thermal recovery story in one line.
                // `.active` fires on cold launch AND on every return to the foreground, so any
                // shot left undeveloped on disk (a crash mid-develop, a kill while backgrounded)
                // is picked up the moment the app is alive again. `kick()` is idempotent: if the
                // worker is already developing, this does nothing. App-level, so there is no view
                // it can be orphaned from.
                DarkRoomWorker.shared.kick()
            case .background:
                // `.background` only — NOT `.inactive`. Inactive fires for a pulled-down
                // notification shade, a control-centre swipe, or an incoming call banner;
                // unloading on those would tear down 1.75 GB because someone glanced at the
                // time, then reload it a second later. Hal makes exactly this distinction and
                // says so in its own lifecycle comment.
                cameraLog("MEMORY: app entered background — unloading the eye to reduce jetsam pressure")
                Task { await QwenLoader.shared.unload() }
            default:
                break
            }
        }
    }
}
// ==== LEGO END: 1 App Entry ====
