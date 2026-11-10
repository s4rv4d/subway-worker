import SwiftUI

/// The things you set once: sound and how the session behaves. (⌘,)
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Button {
                            model.toggleMute()
                        } label: {
                            Image(systemName: model.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .frame(width: 18)
                        }
                        .buttonStyle(.borderless)
                        .help(model.playback.isMuted ? "Unmute" : "Mute")
                        Slider(value: Binding(get: { model.playback.volume }, set: { model.setVolume($0) }), in: 0...1)
                            .controlSize(.small)
                    }
                    .frame(width: 190)
                }
                Picker("When I switch apps", selection: Binding(
                    get: { model.switchAwayBehavior },
                    set: { model.switchAwayBehavior = $0 }
                )) {
                    ForEach(SwitchAwayBehavior.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Behind the split", selection: Binding(get: { model.frameStyle }, set: { model.frameStyle = $0 })) {
                    ForEach(FrameStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep the app snapped in place", isOn: Binding(get: { model.keepSnapped }, set: { model.keepSnapped = $0 }))
                Toggle("Put the window back when I'm done", isOn: Binding(get: { model.restoreOnEnd }, set: { model.restoreOnEnd = $0 }))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .font(.geist(13))
        .tint(Theme.accent)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .frame(width: 460, height: 248)
    }
}
