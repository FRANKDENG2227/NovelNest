import NovelNestCore
import SwiftData
import SwiftUI

/// 书源: import a yck (源仓库) subscription link, turn sources on and off,
/// pick the default source, check which sites still answer, and delete
/// the ones that can't be used.
struct SourceListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case usable = "可用"
        case unusable = "不能用"
        var id: Self { self }
    }

    /// A common word for checking that a source's search still works.
    static let checkKeyword = "我的"

    @Environment(\.modelContext) private var context
    @Query(sort: \BookSource.importedAt) private var sources: [BookSource]
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.defaultSource) private var defaultSource = ""

    @State private var showImport = false
    @State private var link = ""
    @State private var isImporting = false
    @State private var message: String?
    @State private var filter = ""
    @State private var shown = Filter.all
    @State private var showDeleteOptions = false
    @State private var isChecking = false
    @State private var checkedCount = 0
    @State private var checkTotal = 0
    @State private var exportFile: ExportFile?
    @State private var confirmInsecure = false

    private var library: LibraryService { LibraryService(context: context) }

    private var visibleSources: [BookSource] {
        let key = filter.trimmingCharacters(in: .whitespaces)
        return sources.filter { source in
            switch shown {
            case .all: true
            case .usable: !source.isUnusable
            case .unusable: source.isUnusable
            }
        }.filter { key.isEmpty || $0.name.localizedCaseInsensitiveContains(key) || ($0.group ?? "").contains(key) || $0.sourceURL.contains(key) }
    }

    private var unsupported: [BookSource] { sources.filter { !$0.isSupported } }
    /// Supported, but the site failed the last time it was searched.
    private var failing: [BookSource] { sources.filter { $0.isSupported && $0.lastError != nil } }

    var body: some View {
        List {
            Section {
                Button("导入书源链接", systemImage: "link.badge.plus") { showImport = true }
                    .disabled(isImporting)
            } footer: {
                Text("支持源仓库的书源订阅链接（.json）和 yuedu:// 导入链接。需要解密、内置浏览器、登录、设备标识、Java 类或 XPath 的书源会导入但保持关闭。左滑书源可设为默认，搜索时优先使用。")
            }
            .listRowBackground(theme.secondaryBackground)

            if !sources.isEmpty {
                Section {
                    Picker("显示", selection: $shown) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)

                    ForEach(visibleSources) { source in
                        SourceRow(source: source, isDefault: source.sourceURL == defaultSource)
                            .swipeActions(edge: .leading) {
                                if source.isSupported {
                                    Button(source.sourceURL == defaultSource ? "取消默认" : "设为默认") {
                                        setDefault(source)
                                    }
                                    .tint(.accentColor)
                                }
                            }
                            .contextMenu {
                                if source.isSupported {
                                    Button(source.sourceURL == defaultSource ? "取消默认" : "设为默认书源", systemImage: "star") {
                                        setDefault(source)
                                    }
                                }
                            }
                    }
                    .onDelete { offsets in delete(offsets.map { visibleSources[$0] }) }
                } header: {
                    Text("共 \(sources.count) 个，可用 \(sources.filter { !$0.isUnusable }.count) 个，已启用 \(sources.filter(\.isEnabled).count) 个")
                        .textCase(nil)
                }
                .listRowBackground(theme.secondaryBackground)

                Section {
                    Button {
                        Task { await checkSources() }
                    } label: {
                        HStack {
                            Label(isChecking ? "正在检测 \(checkedCount)/\(checkTotal)…" : "检测已启用的书源", systemImage: "stethoscope")
                            if isChecking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isChecking)
                    Button("启用全部可用书源") {
                        for source in sources where source.isSupported && source.lastError == nil { source.isEnabled = true }
                        try? context.save()
                    }
                    Button("删除不能用的书源（\(unsupported.count + failing.count)）", role: .destructive) {
                        showDeleteOptions = true
                    }
                    .disabled(unsupported.isEmpty && failing.isEmpty)
                } footer: {
                    Text("「不能用」包括规则不支持的书源，和上次搜索时网站拒绝访问、要求验证、超时或出错的书源。脚本卡住、请求过多或嵌套过深的书源会自动关闭。检测会用「\(Self.checkKeyword)」在每个已启用的书源搜索一次。")
                }
                .listRowBackground(theme.secondaryBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("书源")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { exportMenu }
        }
        .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
        .searchable(text: $filter, prompt: "书源名称或网址")
        .overlay { if isImporting { ProgressView("正在导入…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .confirmationDialog("删除不能用的书源", isPresented: $showDeleteOptions, titleVisibility: .visible) {
            Button("全部删除（\(unsupported.count + failing.count) 个）", role: .destructive) { delete(unsupported + failing) }
            if !unsupported.isEmpty && !failing.isEmpty {
                Button("只删除不支持的（\(unsupported.count) 个）", role: .destructive) { delete(unsupported) }
                Button("只删除失效的（\(failing.count) 个）", role: .destructive) { delete(failing) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不支持 \(unsupported.count) 个，网站失效 \(failing.count) 个。已加入书架的书不受影响，但用这些书源的书将无法下载新章节。")
        }
        .alert("链接没有加密", isPresented: $confirmInsecure) {
            Button("仍然导入", role: .destructive) { Task { await importLink(allowInsecure: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(LibraryService.SourceImportError.insecure.localizedDescription + "只在可信的网络上导入，或换成 https 链接。")
        }
        .alert("导入书源", isPresented: $showImport) {
            TextField("https://www.yckceo.com/…json", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("导入") { Task { await importLink() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("粘贴源仓库（yckceo.com）的书源订阅链接。")
        }
        .alert("导入书源", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        } message: {
            Text(message ?? "")
        }
    }

    /// What can be exported: usable, enabled, or everything.
    private var exportChoices: [(title: String, sources: [BookSource])] {
        [("可用的书源", sources.filter { !$0.isUnusable }),
         ("已启用的书源", sources.filter(\.isEnabled)),
         ("全部书源", sources)]
    }

    private var exportMenu: some View {
        Menu {
            Section("分享为文件（AirDrop、微信、存到文件…）") {
                ForEach(exportChoices, id: \.title) { choice in
                    Button("\(choice.title)（\(choice.sources.count)）", systemImage: "square.and.arrow.up") {
                        share(choice.sources)
                    }
                    .disabled(choice.sources.isEmpty)
                }
            }
            Section("复制 JSON 到剪贴板") {
                ForEach(exportChoices, id: \.title) { choice in
                    Button("\(choice.title)（\(choice.sources.count)）", systemImage: "doc.on.doc") {
                        copy(choice.sources)
                    }
                    .disabled(choice.sources.isEmpty)
                }
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .disabled(sources.isEmpty)
    }

    private func share(_ sources: [BookSource]) {
        do {
            exportFile = ExportFile(url: try library.exportSourcesFile(sources))
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func copy(_ sources: [BookSource]) {
        do {
            UIPasteboard.general.string = String(decoding: try library.exportSources(sources), as: UTF8.self)
            message = "已复制 \(sources.count) 个书源。在阅读（Legado）等 App 的书源管理里选择「剪贴板导入」或「本地导入」即可使用。"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func delete(_ removed: [BookSource]) {
        if removed.contains(where: { $0.sourceURL == defaultSource }) { defaultSource = "" }
        library.deleteSources(removed)
    }

    /// Searches every enabled source once and records which ones answer.
    private func checkSources() async {
        let sources = library.searchableSources()
        checkTotal = sources.count
        checkedCount = 0
        isChecking = true
        defer { isChecking = false }
        for await event in WebSearch.searchAll(sources, key: Self.checkKeyword) {
            library.recordCheck(event)
            checkedCount += 1
        }
        let failed = failing.count
        message = failed == 0 ? "\(checkTotal) 个书源都能正常搜索。" : "\(failed) 个书源失效，可以在下方删除。"
    }

    private func setDefault(_ source: BookSource) {
        if source.sourceURL == defaultSource {
            defaultSource = ""
        } else {
            defaultSource = source.sourceURL
            source.isEnabled = true
            try? context.save()
        }
    }

    private func importLink(allowInsecure: Bool = false) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let summary = try await library.importSources(from: link, allowInsecure: allowInsecure)
            var text = "新增 \(summary.added) 个，更新 \(summary.updated) 个。"
            if summary.unsupported > 0 { text += "\n其中 \(summary.unsupported) 个不支持，已保持关闭。" }
            message = text
            link = ""
        } catch LibraryService.SourceImportError.insecure {
            confirmInsecure = true
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct SourceRow: View {
    @Bindable var source: BookSource
    let isDefault: Bool
    @Environment(\.modelContext) private var context

    var body: some View {
        Toggle(isOn: Binding(get: { source.isEnabled }, set: { source.isEnabled = $0; try? context.save() })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).lineLimit(1)
                    if isDefault {
                        Text("默认").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: .capsule)
                    }
                }
                Text([source.group, URL(string: source.sourceURL)?.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !source.isSupported {
                    Text("不支持：" + source.unsupportedReasons.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.orange)
                } else if let error = source.lastError {
                    Text("失效：\(error)" + (source.failureCount > 1 ? "（连续 \(source.failureCount) 次）" : ""))
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .disabled(!source.isSupported)
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for exported files.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
