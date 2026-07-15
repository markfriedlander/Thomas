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
//  Services/LocalAPI/LocalAPIServer.swift
//    9  The Antenna (Class, Token, Address)
//   10  The Look Queue (Serialization)
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
//
//  Qwen.swift
//   17  Qwen (The Unguarded Eye)
//
//  Developing.swift
//   18  The Darkroom (Compositor)
//
//  CameraView.swift
//   19  Viewfinder
//   20  CameraView (The Sacred Screen)
//   21  Seer (Which Eye Is Loaded)
//
//  Preferences.swift
//   22  Settings (What The Camera Is Loaded With)
//   23  PreferencesView (The Film Drawer)
//
//  Created by Mark Friedlander on 7/14/26.
//

import SwiftUI

@main
struct AI_CameraApp: App {

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
    }
}
// ==== LEGO END: 1 App Entry ====
