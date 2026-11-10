import AppKit
import ClipTemplates
import SubwayWorkerCore
import SwiftUI
import WindowTiling

struct LauncherView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    private var session: SessionController { model.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                Header()
                if !model.isTrusted {
                    AccessRow(model: model)
                }
                AppPicker(model: model, onLockIn: lockIn)
                ClipPicker(model: model)
                LayoutPicker(model: model)
            }
            .padding(.horizontal, 28)
            .padding(.top, 10) // the hidden title bar already keeps us clear of the traffic lights
            .padding(.bottom, 28)

            footer
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .font(.geist(13))
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshRunningApps() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 12)
            if session.isActive {
                Button("End session") {
                    Task { await session.end(restore: model.restoreOnEnd) }
                }
                .buttonStyle(QuietButtonStyle())
            }
            Button(action: lockIn) {
                HStack(spacing: 8) {
                    Text(session.isActive ? "Update" : "Lock in")
                    Text("↩").font(.geistMono(12)).opacity(0.55)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedApp == nil || !model.isTrusted || isBusy)
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .starting(let name):
            StatusLine(text: "Snapping \(name)…", busy: true)
        case .ending:
            StatusLine(text: "Putting your window back…", busy: true)
        case .failed(let message):
            Text(message)
                .font(.geist(12.5))
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        case .active:
            if let target = session.target {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("Locked in on \(target.name)")
                        .font(.geist(12.5, .medium))
                        .lineLimit(1)
                }
            }
        case .idle:
            if let app = model.selectedApp {
                HStack(spacing: 6) {
                    Text(app.name).foregroundStyle(Theme.text)
                    Text("+").foregroundStyle(Theme.tertiaryText)
                    Text(model.clipSource.displayName).foregroundStyle(Theme.secondaryText)
                }
                .font(.geist(12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            } else {
                Text("Pick an app")
                    .font(.geist(12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var isBusy: Bool {
        switch session.phase {
        case .starting, .ending: true
        default: false
        }
    }

    private func lockIn() {
        Task {
            if await model.lockIn() {
                dismissWindow(id: SubwayWorkerApp.launcherID)
            }
        }
    }
}

private struct StatusLine: View {
    let text: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .font(.geist(12.5))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Header

private struct Header: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 10, height: 10)
            Text("Subway Worker")
                .font(.geist(19, .semibold))
                .tracking(-0.3)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}

private struct AccessRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Subway Worker needs Accessibility access to move windows.")
                .font(.geist(12.5))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Allow…") { model.requestAccessibility() }
                .buttonStyle(QuietButtonStyle(tint: Theme.accent))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent.opacity(0.35))
        }
    }
}

// MARK: - App

private struct AppPicker: View {
    let model: AppModel
    let onLockIn: () -> Void
    @State private var search = ""

    private var filtered: [AppChoice] {
        let apps = model.allApps
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("App")
                Spacer()
                SearchField(text: $search)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 96), spacing: 4)], spacing: 4) {
                    ForEach(filtered) { app in
                        AppTile(app: app, isSelected: model.selectedAppID == app.id)
                            .onTapGesture(count: 2) {
                                model.selectedAppID = app.id
                                onLockIn()
                            }
                            // Simultaneous, so a single click selects at once instead of
                            // waiting out the double-click interval.
                            .simultaneousGesture(TapGesture().onEnded { model.selectedAppID = app.id })
                            // VoiceOver (and other assistive tech) presses select the app too.
                            .accessibilityAction { model.selectedAppID = app.id }
                    }
                    OtherAppTile { model.pickOtherApp() }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: 178)
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.geist(12))
        }
        .padding(.horizontal, 9)
        .frame(width: 168, height: 26)
        .background(Theme.surface, in: .rect(cornerRadius: 7))
    }
}

private struct AppTile: View {
    let app: AppChoice
    let isSelected: Bool
    @State private var isHovering = false

    private var isRunning: Bool { app.processIdentifier != nil }

    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 40, height: 40)
                .opacity(isRunning ? 1 : 0.55)
            Text(app.name)
                .font(.geist(11.5, isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 84)
        .tileBackground(selected: isSelected, hovering: isHovering)
        .onHover { isHovering = $0 }
        .help(isRunning ? app.name : "\(app.name) isn't running. It opens when you lock in.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct OtherAppTile: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                    }
                Text("Other…")
                    .font(.geist(11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .tileBackground(selected: false, hovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Clip

private struct ClipPicker: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Clip")
            HStack(spacing: 10) {
                ForEach(ClipTemplate.allCases) { template in
                    TemplateTile(template: template, isSelected: model.clipSource == .template(template)) {
                        model.clipSource = .template(template)
                    }
                }
            }
            HStack(spacing: 10) {
                SourceTile(symbol: "film", title: fileTitle, isSelected: isFile) { model.chooseVideoFile() }
                SourceTile(symbol: "folder", title: folderTitle, isSelected: isFolder) { model.chooseVideoFolder() }
                YouTubeField(model: model)
            }
        }
    }

    private var isFile: Bool { if case .file = model.clipSource { true } else { false } }
    private var isFolder: Bool { if case .folder = model.clipSource { true } else { false } }

    private var fileTitle: String {
        if case .file(let url) = model.clipSource { return url.lastPathComponent }
        return "Video file…"
    }

    private var folderTitle: String {
        if case .folder(let url) = model.clipSource {
            let count = model.folderClipCount ?? 0
            return "\(url.lastPathComponent) · \(count)"
        }
        return "Folder…"
    }
}

private struct TemplateTile: View {
    let template: ClipTemplate
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                TemplateClipView(template: template, isPaused: !isSelected)
                    .frame(height: 84)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Theme.accent : (isHovering ? Theme.text.opacity(0.25) : Theme.hairline),
                                          lineWidth: isSelected ? 1.5 : 1)
                    }
                    .allowsHitTesting(false)
                Text(template.title)
                    .font(.geist(12, isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(template.blurb)
    }
}

private struct SourceTile: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                    .frame(width: 16)
                Text(title)
                    .font(.geist(12))
                    .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isHovering && !isSelected ? Theme.surfaceRaised : Theme.surface, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct YouTubeField: View {
    let model: AppModel
    @State private var text = ""
    @State private var isInvalid = false

    private var currentLink: YouTubeLink? {
        if case .youtube(let link) = model.clipSource { link } else { nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(currentLink != nil ? Theme.accent : Theme.secondaryText)
                .frame(width: 16)
            TextField(currentLink.map { "youtu.be/\($0.videoID)" } ?? "YouTube link", text: $text)
                .textFieldStyle(.plain)
                .font(.geist(12))
                .onSubmit(apply)
                .onChange(of: text) { isInvalid = false }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(Theme.surface, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 1.5)
        }
        .help(isInvalid ? "That doesn't look like a YouTube video link." : "Paste a YouTube video or Shorts link, then press Return.")
    }

    private var borderColor: Color {
        if isInvalid { return Theme.danger }
        return currentLink != nil ? Theme.accent : .clear
    }

    private func apply() {
        guard !text.isEmpty else { return }
        if let link = YouTubeLink(string: text) {
            model.clipSource = .youtube(link)
            text = ""
        } else {
            isInvalid = true
            NSSound.beep()
        }
    }
}

// MARK: - Layout

private struct LayoutPicker: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Layout")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    OptionRow("Side") {
                        SegmentedPicker(
                            options: ClipPlacement.allCases.map { ($0, $0.title) },
                            selection: Binding(get: { model.placement }, set: { model.placement = $0 })
                        )
                    }
                    OptionRow("Size") {
                        HStack(spacing: 12) {
                            SegmentedPicker(options: [(true, "Phone"), (false, "Custom")], selection: sizingMode)
                            if case .fraction(let share) = model.sizing {
                                Slider(value: Binding(get: { share }, set: { model.sizing = .fraction($0) }), in: 0.12...0.6)
                                    .controlSize(.small)
                                    .frame(width: 110)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                LayoutDiagram(model: model)
            }
        }
    }

    private var sizingMode: Binding<Bool> {
        Binding(
            get: { model.sizing == .automatic },
            set: { automatic in
                if automatic {
                    model.sizing = .automatic
                } else if let screen = NSScreen.main {
                    // Start the slider from whatever "auto" currently gives.
                    let auto = SplitLayout.compute(in: screen.visibleFrame, placement: model.placement, sizing: .automatic)
                    model.sizing = .fraction(auto.clipShare(in: screen.visibleFrame))
                } else {
                    model.sizing = .fraction(0.3)
                }
            }
        )
    }
}

private struct OptionRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.geist(12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 34, alignment: .leading)
            content
        }
    }
}

/// A to-scale miniature of the main display: the app in gray, the clip in yellow.
private struct LayoutDiagram: View {
    let model: AppModel

    var body: some View {
        let screen = NSScreen.main
        let full = screen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = screen?.visibleFrame ?? full
        let layout = SplitLayout.compute(in: visible, placement: model.placement, sizing: model.sizing)
        let width: CGFloat = 124
        let height = (width * full.height / max(full.width, 1)).rounded()

        VStack(alignment: .trailing, spacing: 6) {
            do {
                let scale = width / max(full.width, 1)
                // AppKit y is bottom-up; SwiftUI is top-down.
                let map = { (rect: CGRect) -> CGRect in
                    CGRect(
                        x: (rect.minX - full.minX) * scale,
                        y: (full.maxY - rect.maxY) * scale,
                        width: rect.width * scale,
                        height: rect.height * scale
                    )
                }
                let app = map(layout.appFrame).insetBy(dx: 1.5, dy: 1.5)
                let clip = map(layout.clipFrame).insetBy(dx: 1.5, dy: 1.5)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.surface)
                        .strokeBorder(Theme.hairline)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.surfaceRaised)
                        .overlay {
                            if let icon = model.selectedApp?.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18).opacity(0.8)
                            }
                        }
                        .frame(width: max(app.width, 0), height: max(app.height, 0))
                        .offset(x: app.minX, y: app.minY)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                        .frame(width: max(clip.width, 0), height: max(clip.height, 0))
                        .offset(x: clip.minX, y: clip.minY)
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }

            Text("\(Int(layout.clipExtent))pt · \(Int((layout.clipShare(in: visible) * 100).rounded()))%")
                .font(.geistMono(10.5))
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}
