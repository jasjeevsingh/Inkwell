import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.editorFont) private var editorFont = EditorFontStyle.mono.rawValue
    @AppStorage(Prefs.editorFontSize) private var editorFontSize = 15.0
    @AppStorage(Prefs.readableWidth) private var readableWidth = true
    @AppStorage(Prefs.spellCheck) private var spellCheck = false
    @AppStorage(Prefs.previewFont) private var previewFont = "sans"
    @AppStorage(Prefs.previewFontSize) private var previewFontSize = 16.0
    @AppStorage(Prefs.previewWidth) private var previewWidth = 780.0
    @AppStorage(Prefs.syncScroll) private var syncScroll = true
    @AppStorage(Prefs.defaultMode) private var defaultMode = ViewMode.split.rawValue
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @AppStorage(Prefs.showSidebar) private var showSidebar = true
    @AppStorage(Prefs.openInTabs) private var openInTabs = true

    @State private var isDefault = DefaultApp.isDefault
    @State private var settingDefault = false

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Open documents in", selection: $defaultMode) {
                    ForEach(ViewMode.allCases) { Text($0 == .split ? "Editor and Preview" : $0.label).tag($0.rawValue) }
                }
                Toggle("Show the folder sidebar when opening a document", isOn: $showSidebar)
                Picker("Open files from the sidebar in", selection: $openInTabs) {
                    Text("Tabs").tag(true)
                    Text("New windows").tag(false)
                }
                LabeledContent("Default Markdown app") {
                    if isDefault {
                        Label("Inkwell", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(settingDefault ? "Setting…" : "Make Inkwell the Default") {
                            settingDefault = true
                            Task {
                                _ = await DefaultApp.makeDefault()
                                isDefault = DefaultApp.isDefault
                                settingDefault = false
                            }
                        }
                        .disabled(settingDefault)
                    }
                }
            }

            Section("Editor") {
                Picker("Font", selection: $editorFont) {
                    ForEach(EditorFontStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Stepper(value: $editorFontSize, in: 10...28, step: 1) {
                    LabeledContent("Font size", value: "\(Int(editorFontSize)) pt")
                }
                Toggle("Limit line width for readability", isOn: $readableWidth)
                Toggle("Check spelling while typing", isOn: $spellCheck)
            }

            Section("Preview") {
                Picker("Font", selection: $previewFont) {
                    Text("System").tag("sans")
                    Text("Serif").tag("serif")
                    Text("Monospaced").tag("mono")
                }
                Stepper(value: $previewFontSize, in: 11...26, step: 1) {
                    LabeledContent("Font size", value: "\(Int(previewFontSize)) pt")
                }
                LabeledContent("Content width") {
                    Slider(value: $previewWidth, in: 560...1200, step: 20)
                        .frame(width: 180)
                    Text("\(Int(previewWidth)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Toggle("Sync scrolling with editor", isOn: $syncScroll)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance) { _, value in Appearance.apply(value) }
        .onAppear { isDefault = DefaultApp.isDefault }
    }
}
