import AppKit
import SubwayWorkerCore
import SwiftUI

@main
struct SubwayWorkerApp: App {
    static let launcherID = "launcher"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Subway Worker", id: Self.launcherID) {
            LauncherView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                SessionMenuItems(model: model)
            }
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.session.isActive ? "tram.fill" : "tram")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // the menu bar item and the panel keep us useful
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let session = model.session
        if session.isActive {
            // Put the window back before we go.
            Task {
                await session.end(restore: model.restoreOnEnd)
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        if session.phase == .ending {
            // A restore is already running (e.g. a second ⌘Q) — let it finish.
            Task {
                await session.waitForPendingRestore()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

/// Opens (or focuses) the launcher window.
struct OpenLauncherButton: View {
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: SubwayWorkerApp.launcherID)
            NSApp.activate()
        }
    }
}

private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.session.isActive, let target = model.session.target {
            Text("Locked in on \(target.name)")
            Text(model.clipSource.displayName)
            Divider()
            SessionMenuItems(model: model)
            Divider()
            OpenLauncherButton(title: "Change Setup…")
        } else {
            if let app = model.selectedApp, model.isTrusted {
                Button("Lock In on \(app.name)") {
                    Task { await model.lockIn() }
                }
            }
            OpenLauncherButton(title: "Choose App…")
        }
        Divider()
        Menu("Clip") { ClipMenuItems(model: model) }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Subway Worker") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Session controls shared by the menu bar item and the app's "Session" menu.
struct SessionMenuItems: View {
    let model: AppModel

    var body: some View {
        let playback = model.playback
        let active = model.session.isActive
        Button(playback.isPaused ? "Play" : "Pause") { model.togglePause() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Button(playback.isMuted ? "Unmute" : "Mute") { model.toggleMute() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        if model.clipSource.supportsSkipping {
            Button("Next Clip") { playback.skip() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        Button("Swap Sides") { model.swapSides() }
            .disabled(!active)
        Button("Re-snap Windows") { model.session.relayout() }
            .disabled(!active)
        Picker("When I Switch Apps", selection: Binding(
            get: { model.switchAwayBehavior },
            set: { model.switchAwayBehavior = $0 }
        )) {
            ForEach(SwitchAwayBehavior.allCases) { Text($0.title).tag($0) }
        }
        Button("End Session") {
            Task { await model.session.end(restore: model.restoreOnEnd) }
        }
        .disabled(!active)
    }
}
