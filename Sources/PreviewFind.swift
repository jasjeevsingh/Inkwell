import SwiftUI
import WebKit

/// Find-in-page for the preview pane (the editor uses AppKit's built-in find bar).
@MainActor
final class PreviewFind: ObservableObject {
    @Published var visible = false
    @Published var query = ""
    @Published private(set) var count = 0
    @Published private(set) var found = true
    @Published var focusRequest = 0

    weak var controller: PreviewController?
    private var searchTask: Task<Void, Never>?

    var isActive: Bool { visible }

    func show() {
        visible = true
        focusRequest += 1
        if !query.isEmpty { refresh(fromCurrent: true) }
    }

    func useSelection() {
        Task {
            guard let text = await controller?.selectedText(), !text.isEmpty else { return show() }
            query = text.trimmingCharacters(in: .newlines)
            show()
        }
    }

    func close(refocus: Bool = true) {
        guard visible else { return }
        visible = false
        searchTask?.cancel()
        clearHighlight()
        if refocus, let webView = controller?.webView { webView.window?.makeFirstResponder(webView) }
    }

    /// WebKit keeps the last match highlighted; searching for something that can't match clears it.
    private func clearHighlight() {
        guard let webView = controller?.webView else { return }
        webView.find("\u{F8FF}\u{F8FE}\u{F8FD}", configuration: WKFindConfiguration()) { _ in }
    }

    /// Called as the query changes: counts matches and jumps to the first one at or after the selection.
    func queryChanged() {
        refresh(fromCurrent: true)
    }

    private func refresh(fromCurrent: Bool) {
        searchTask?.cancel()
        let q = query
        searchTask = Task {
            guard let controller else { return }
            guard !q.isEmpty else {
                count = 0
                found = true
                return
            }
            count = await controller.countMatches(q)
            guard !Task.isCancelled else { return }
            if fromCurrent { await controller.collapseSelectionToStart() }
            await search(q, backwards: false)
        }
    }

    func next(backwards: Bool) {
        if !visible { show() }
        guard !query.isEmpty else { return }
        let q = query
        Task { await search(q, backwards: backwards) }
    }

    private func search(_ q: String, backwards: Bool) async {
        guard let webView = controller?.webView else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.find(q, configuration: config) { cont.resume(returning: $0.matchFound) }
        }
        found = result
    }
}

struct PreviewFindBar: View {
    @ObservedObject var find: PreviewFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in Preview", text: $find.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { find.next(backwards: false) }
                    .onKeyPress(.escape) {
                        find.close()
                        return .handled
                    }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        find.next(backwards: true)
                        return .handled
                    }
                if !find.query.isEmpty {
                    Text(find.count == 0 ? "Not found" : "\(find.count) \(find.count == 1 ? "match" : "matches")")
                        .font(.system(size: 11))
                        .foregroundStyle(find.count == 0 ? .red : .secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            ControlGroup {
                Button { find.next(backwards: true) } label: { Image(systemName: "chevron.left") }
                    .help("Previous ⇧⌘G")
                Button { find.next(backwards: false) } label: { Image(systemName: "chevron.right") }
                    .help("Next ⌘G")
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(find.query.isEmpty || find.count == 0)

            Button("Done") { find.close() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: find.query) { _, _ in find.queryChanged() }
        .onChange(of: find.focusRequest) { _, _ in focused = true }
        .onAppear { focused = true }
    }
}
