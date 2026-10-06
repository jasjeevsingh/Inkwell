import SwiftUI

enum SidebarTab: String {
    case files, outline
}

struct SidebarView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarTab) {
                Label("Files", systemImage: "folder").tag(SidebarTab.files)
                Label("Outline", systemImage: "list.bullet.indent").tag(SidebarTab.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            switch model.sidebarTab {
            case .files:
                FilesSidebar(workspace: model.workspace)
            case .outline:
                OutlineView(headings: model.headings, onSelect: model.jump(to:))
            }
        }
    }
}

// MARK: - Files

struct FilesSidebar: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if let root = workspace.root {
                tree(root)
            } else {
                emptyState
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Menu {
                if let root = workspace.root {
                    Section("Show Folder") {
                        ForEach(workspace.ancestors, id: \.self) { dir in
                            Button {
                                workspace.setRoot(dir)
                            } label: {
                                Label(dir.path == "/" ? "Macintosh HD" : dir.lastPathComponent, systemImage: "folder")
                            }
                        }
                    }
                    Divider()
                    Button("Reveal in Finder") { workspace.reveal(root) }
                    Button("Copy Path") { workspace.copyPath(root) }
                    Divider()
                }
                Button("Open Folder…") { workspace.chooseRoot() }
                Toggle("Show All Files", isOn: $workspace.showAllFiles)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(workspace.root?.lastPathComponent ?? "No Folder")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
            .help(workspace.root?.path ?? "Open a folder")

            Spacer(minLength: 4)

            Menu {
                Button("New Markdown File…") { workspace.beginNewFile() }
                Button("New Folder…") { workspace.beginNewFolder() }
                Divider()
                Button("New File in Another Location…") { workspace.createFileWithPanel() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New file or folder")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func tree(_ root: URL) -> some View {
        let rows = workspace.visibleRows()
        return List(selection: Binding(
            get: { workspace.selection },
            set: { url in
                workspace.selection = url
                if let url, !WorkspaceModel.isDirectory(url) { workspace.open(url) }
            }
        )) {
            if rows.isEmpty {
                Text(workspace.showAllFiles ? "This folder is empty" : "No Markdown files here yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
            ForEach(rows) { row in
                FileTreeRow(row: row, workspace: workspace)
                    .tag(row.id)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                itemMenu(url)
            } else {
                folderMenu(root)
            }
        } primaryAction: { urls in
            urls.first.map(workspace.activate)
        }
    }

    @ViewBuilder
    private func itemMenu(_ url: URL) -> some View {
        let isDir = WorkspaceModel.isDirectory(url)
        if isDir {
            folderMenu(url)
            Divider()
            Button("Show Only This Folder") { workspace.setRoot(url) }
        } else {
            Button("Open") { workspace.open(url) }
            Divider()
            Button("New Markdown File Here…") { workspace.beginNewFile(in: url.deletingLastPathComponent()) }
            Button("New Folder Here…") { workspace.beginNewFolder(in: url.deletingLastPathComponent()) }
        }
        Divider()
        Button("Rename…") { workspace.beginRename(url) }
        Button("Reveal in Finder") { workspace.reveal(url) }
        Button("Copy Path") { workspace.copyPath(url) }
        Divider()
        Button("Move to Trash", role: .destructive) { workspace.pendingTrash = url }
    }

    @ViewBuilder
    private func folderMenu(_ dir: URL) -> some View {
        Button("New Markdown File…") { workspace.beginNewFile(in: dir) }
        Button("New Folder…") { workspace.beginNewFolder(in: dir) }
        Button("New File in Another Location…") { workspace.createFileWithPanel() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No folder open")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { workspace.chooseRoot() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct FileTreeRow: View {
    let row: TreeRow
    @ObservedObject var workspace: WorkspaceModel

    private var item: FileItem { row.item }
    private var isCurrent: Bool { item.url == workspace.currentFile }
    private var isOpen: Bool { workspace.expanded.contains(item.url) }

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(.easeOut(duration: 0.12), value: isOpen)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.toggle(item.url) }
                } else {
                    Color.clear.frame(width: 14, height: 18)
                }
            }
            Image(systemName: icon)
                .foregroundStyle(iconStyle)
                .frame(width: 18)
            Text(item.isMarkdown ? (item.name as NSString).deletingPathExtension : item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(item.isDirectory || item.isMarkdown ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .help(item.url.path)
        .draggable(item.url)
    }

    private var icon: String {
        if item.isDirectory { return isOpen ? "folder" : "folder.fill" }
        if isCurrent { return "doc.text.fill" }
        return item.isMarkdown ? "doc.text" : "doc"
    }

    private var iconStyle: AnyShapeStyle {
        if item.isDirectory { return AnyShapeStyle(Color.accentColor.opacity(0.85)) }
        if isCurrent { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.secondary)
    }
}

// MARK: - Dialogs

/// Name prompts, trash confirmation and errors for workspace file operations.
struct WorkspaceDialogs: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel

    func body(content: Content) -> some View {
        content
            .alert(workspace.prompt?.title ?? "", isPresented: Binding(
                get: { workspace.prompt != nil },
                set: { if !$0 { workspace.prompt = nil } }
            ), presenting: workspace.prompt) { prompt in
                TextField("Name", text: $workspace.promptText)
                Button(prompt.actionTitle) { workspace.commit(prompt, name: workspace.promptText) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
            .confirmationDialog("Move “\(workspace.pendingTrash?.lastPathComponent ?? "")” to the Trash?",
                                isPresented: Binding(
                                    get: { workspace.pendingTrash != nil },
                                    set: { if !$0 { workspace.pendingTrash = nil } }
                                ), presenting: workspace.pendingTrash) { url in
                Button("Move to Trash", role: .destructive) { workspace.moveToTrash(url) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You can restore it from the Trash later.")
            }
            .alert("Couldn’t complete that", isPresented: Binding(
                get: { workspace.errorMessage != nil },
                set: { if !$0 { workspace.errorMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(workspace.errorMessage ?? "")
            }
    }
}
