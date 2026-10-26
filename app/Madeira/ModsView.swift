import SwiftUI
import UniformTypeIdentifiers

// The Mods page of a supported game's Game details (LibraryDetail, Page.mods):
// install a mod from a zip/7z/rar (with its FOMOD installer when it has one),
// turn mods on and off, order them, and order and turn on plugins. The work is
// ModManagerCore.swift and Fomod.swift; this is the screen and its model.

extension LibraryEntry {
    /// The mod manager's game for this entry, nil when it isn't a supported one.
    var modGame: ModGame? { ModGame.detect(steamAppID: steamAppID, windowsPath: windowsPath) }

    /// The game's install folder on the host (the folder holding Data).
    @MainActor var modGameRoot: URL? {
        if let id = steamAppID, let game = SteamGamesModel.shared.games.first(where: { $0.id == id }) {
            return LibraryEntry.hostURL(ofWindowsPath: game.windowsInstallPath)
        }
        return LibraryEntry.hostURL(ofWindowsPath: LibraryEntry.folder(of: windowsPath))
    }
}

// MARK: - Model

@MainActor final class ModManager: ObservableObject {
    let store: ModStore
    @Published var state = ModState()
    @Published var busy: String?
    @Published var progress: Double?
    @Published var error: String?
    @Published var notice: String?
    @Published var conflicts: [UUID: (wins: Int, loses: Int)] = [:]
    @Published var missingMasters: [String: [String]] = [:]
    @Published var deployedFiles = 0
    /// A FOMOD installer waiting for its choices.
    @Published var pending: PendingInstall?

    struct PendingInstall: Identifiable {
        let id = UUID()
        var name: String
        var archive: String
        var unpacked: URL
        var root: URL
        var config: FomodConfig
        var replacing: UUID?
    }

    private var deploying = false
    private var deployAgain = false

    init(store: ModStore) {
        self.store = store
    }

    func load() {
        do { try store.prepare() } catch { self.error = error.localizedDescription }
        state = store.loadState()
        deployedFiles = store.loadDeploy().files.count
        // Leftovers of an install that never finished.
        try? FileManager.default.removeItem(at: store.work)
        try? FileManager.default.createDirectory(at: store.work, withIntermediateDirectories: true)
        refreshPlugins()
    }

    private func save() {
        do { try store.save(state) } catch { self.error = "The mod list could not be saved: \(error.localizedDescription)" }
    }

    // MARK: Deploying

    /// Save the list and bring the game folder in line with it. Changes made
    /// while a deployment runs are picked up by one more run afterwards.
    func apply() {
        save()
        if deploying { deployAgain = true; return }
        deploying = true
        let snapshot = state
        let store = self.store
        busy = "Updating the game folder…"
        progress = 0
        Task.detached(priority: .userInitiated) {
            var record = store.loadDeploy()
            var message: String?
            var report = DeployReport()
            do {
                report = try ModDeployer.deploy(snapshot, store: store, record: &record) { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
            } catch {
                message = "Updating the game folder failed: \(error.localizedDescription)"
            }
            let conflicts = ModDeployer.conflicts(snapshot, store: store)
            let files = record.files.count
            await MainActor.run {
                self.deploying = false
                self.busy = nil
                self.progress = nil
                self.conflicts = conflicts
                self.deployedFiles = files
                if let message { self.error = message }
                if !report.keptChanged.isEmpty {
                    self.notice = "\(report.keptChanged.count) deployed file(s) were changed outside the manager and were left in place."
                }
                self.refreshPlugins()
                if self.deployAgain { self.deployAgain = false; self.apply() }
            }
        }
    }

    /// Bring the load order up to date with Data and write plugins.txt.
    func refreshPlugins() {
        state.plugins = ModPlugins.refresh(state.plugins, store: store)
        do { try ModPlugins.apply(state.plugins, store: store) } catch {
            self.error = "plugins.txt could not be written: \(error.localizedDescription)"
        }
        missingMasters = ModPlugins.missingMasters(state.plugins, store: store)
        conflicts = ModDeployer.conflicts(state, store: store)
        save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = state.mods.firstIndex(where: { $0.id == id }), state.mods[i].enabled != on else { return }
        state.mods[i].enabled = on
        apply()
    }

    func moveMods(_ from: IndexSet, _ to: Int) {
        state.mods.move(fromOffsets: from, toOffset: to)
        apply()
    }

    func setPlugin(_ name: String, _ on: Bool) {
        guard let i = state.plugins.firstIndex(where: { $0.name == name }) else { return }
        state.plugins[i].enabled = on
        refreshPlugins()
    }

    func movePlugins(_ from: IndexSet, _ to: Int) {
        state.plugins.move(fromOffsets: from, toOffset: to)
        refreshPlugins()   // puts masters back in front
    }

    func remove(_ mod: ModRecord) {
        state.mods.removeAll { $0.id == mod.id }
        save()
        let folder = store.folder(of: mod)
        apply()
        Task.detached { try? FileManager.default.removeItem(at: folder) }
    }

    func disableAll() {
        for i in state.mods.indices { state.mods[i].enabled = false }
        apply()
    }

    // MARK: Installing

    /// Copy a picked archive into downloads/ and install it.
    func importArchive(_ picked: URL) {
        let store = self.store
        busy = "Copying \(picked.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            do {
                let target = Self.freeName(in: store.downloads, picked.lastPathComponent)
                try FileManager.default.copyItem(at: picked, to: target)
                await MainActor.run { self.install(archive: target.lastPathComponent) }
            } catch {
                await MainActor.run { self.busy = nil; self.error = "The file could not be copied: \(error.localizedDescription)" }
            }
        }
    }

    /// Unpack an archive from downloads/ and install it: through its FOMOD
    /// installer when it has one (the wizard asks first), as-is otherwise.
    func install(archive: String, replacing: UUID? = nil) {
        let store = self.store
        let archiveURL = store.downloads.appendingPathComponent(archive)
        let unpacked = store.work.appendingPathComponent(UUID().uuidString)
        busy = "Unpacking \(archive)…"
        progress = nil
        Task.detached(priority: .userInitiated) {
            do {
                try ModUnpacker.unpack(archiveURL, to: unpacked) { files, _ in
                    if files % 50 == 0 { Task { @MainActor in self.busy = "Unpacking \(archive)… \(files) files" } }
                    return true
                }
                let name = Self.modName(archive: archive, unpacked: unpacked)
                if let fomod = ModLayout.fomod(in: unpacked) {
                    let config = try FomodConfig.load(fomod.config)
                    await MainActor.run {
                        self.busy = nil
                        if config.steps.isEmpty {
                            self.finishFomod(PendingInstall(name: name, archive: archive, unpacked: unpacked, root: fomod.root,
                                                            config: config, replacing: replacing),
                                             session: FomodSession(config: config, fileState: self.fileState))
                        } else {
                            self.pending = PendingInstall(name: config.moduleName.isEmpty ? name : config.moduleName,
                                                          archive: archive, unpacked: unpacked, root: fomod.root,
                                                          config: config, replacing: replacing)
                        }
                    }
                    return
                }
                let record = ModRecord(id: UUID(), name: name, enabled: true, archive: archive, installed: Date(), choices: nil)
                try ModLayout.install(unpacked, into: store.folder(of: record))
                try? FileManager.default.removeItem(at: unpacked)
                await MainActor.run { self.add(record, replacing: replacing) }
            } catch {
                try? FileManager.default.removeItem(at: unpacked)
                await MainActor.run { self.busy = nil; self.error = error.localizedDescription }
            }
        }
    }

    /// Install with the FOMOD wizard's choices.
    func finishFomod(_ pending: PendingInstall, session: FomodSession) {
        self.pending = nil
        let store = self.store
        busy = "Installing \(pending.name)…"
        Task.detached(priority: .userInitiated) {
            let record = ModRecord(id: UUID(), name: pending.name, enabled: true, archive: pending.archive,
                                   installed: Date(), choices: session.summary())
            do {
                try session.install(from: pending.root, into: store.folder(of: record))
                try? FileManager.default.removeItem(at: pending.unpacked)
                await MainActor.run { self.add(record, replacing: pending.replacing) }
            } catch {
                try? FileManager.default.removeItem(at: store.folder(of: record))
                try? FileManager.default.removeItem(at: pending.unpacked)
                await MainActor.run { self.busy = nil; self.error = error.localizedDescription }
            }
        }
    }

    func cancelFomod() {
        if let pending { try? FileManager.default.removeItem(at: pending.unpacked) }
        pending = nil
    }

    /// A new mod goes last; one replacing an older install (a reinstall, or an
    /// archive of the same mod) takes its place and its on/off state.
    private func add(_ record: ModRecord, replacing: UUID?) {
        var record = record
        let old = replacing.flatMap { id in state.mods.firstIndex { $0.id == id } }
            ?? state.mods.firstIndex { $0.name.caseInsensitiveCompare(record.name) == .orderedSame }
        if let old {
            let previous = state.mods[old]
            record.enabled = previous.enabled
            state.mods[old] = record
            let folder = store.folder(of: previous)
            Task.detached { try? FileManager.default.removeItem(at: folder) }
            notice = "Updated \(record.name)."
        } else {
            state.mods.append(record)
            notice = "Installed \(record.name)."
        }
        busy = nil
        apply()
    }

    /// For FOMOD file conditions: present in Data, and for a plugin, enabled.
    nonisolated var fileState: (String) -> FomodFileState {
        let store = self.store
        return { name in
            let data = store.dataFolder
            let path = FomodFile.normalize(name)
            guard FileManager.default.fileExists(atPath: CaseFolder().resolve(data, path).path) else { return .missing }
            guard ModPlugins.extensions.contains((path as NSString).pathExtension.lowercased()) else { return .active }
            let order = store.loadState().plugins
            let enabled = order.first { $0.name.caseInsensitiveCompare(path) == .orderedSame }?.enabled ?? true
            return enabled ? .active : .inactive
        }
    }

    // MARK: Names

    nonisolated static func freeName(in folder: URL, _ name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 2... {
            url = folder.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return url
    }

    /// The mod's name: fomod/info.xml's, else the archive's without Nexus's
    /// "-<id>-<version>-<timestamp>" tail.
    nonisolated static func modName(archive: String, unpacked: URL) -> String {
        let folder = CaseFolder()
        var dir = unpacked
        for _ in 0..<3 {
            if let fomod = folder.existing(dir, "fomod"), let info = folder.existing(fomod, "info.xml"),
               let data = try? Data(contentsOf: info), let xml = try? FomodXMLReader.parse(data),
               let name = xml.child("Name")?.trimmedText, !name.isEmpty {
                return name
            }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !ModFiles.junk($0) }
            guard names.count == 1 else { break }
            dir.appendPathComponent(names[0])
        }
        var name = (archive as NSString).deletingPathExtension
        if let range = name.range(of: #"-\d+(-[0-9A-Za-z]+)*-\d{9,}$"#, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        return name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Screen

struct ModsScreen: View {
    @StateObject private var manager: ModManager
    @State private var tab = 0
    @State private var importing = false
    @State private var confirmRemove: ModRecord?
    @State private var confirmDisableAll = false
    @State private var editMode: EditMode = .inactive

    init(game: ModGame, gameRoot: URL) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        _manager = StateObject(wrappedValue: ModManager(store: ModStore(game: game, documents: documents, gameRoot: gameRoot)))
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $tab) {
                    Text("Mods").tag(0)
                    Text("Plugins").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if let busy = manager.busy {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text(busy).font(.callout)
                            if let p = manager.progress { ProgressView(value: p) }
                        }
                    }
                }
            }
            if let notice = manager.notice {
                Section { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
            if tab == 0 { modsSection } else { pluginsSection }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { importing = true } label: { Label("Install a mod", systemImage: "plus") }
                    .disabled(manager.busy != nil)
                Button(editMode.isEditing ? "Done" : "Order") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let ext = url.pathExtension.lowercased()
                if ["zip", "7z", "rar"].contains(ext) { manager.importArchive(url) }
                else { manager.error = "Choose a .zip, .7z or .rar file." }
            }
        }
        .sheet(item: $manager.pending) { pending in
            FomodWizard(pending: pending, fileState: manager.fileState,
                        install: { manager.finishFomod(pending, session: $0) },
                        cancel: { manager.cancelFomod() })
        }
        .alert("Mods", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(manager.error ?? "") }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let mod = confirmRemove { manager.remove(mod) } }
        } message: { Text("Its files leave the game folder. The archive stays in Downloads for a later reinstall.") }
        .confirmationDialog("Turn every mod off?", isPresented: $confirmDisableAll, titleVisibility: .visible) {
            Button("Turn all off", role: .destructive) { manager.disableAll() }
        } message: { Text("All mod files leave the game folder and the game's own files come back. Mods stay installed.") }
        .onAppear { manager.load() }
    }

    @ViewBuilder private var modsSection: some View {
        Section {
            if manager.state.mods.isEmpty {
                Text("No mods yet. Tap + and choose a mod's .zip, .7z or .rar.")
                    .foregroundStyle(.secondary)
            }
            ForEach(manager.state.mods) { mod in
                modRow(mod)
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { confirmRemove = mod }
                        if let archive = mod.archive,
                           FileManager.default.fileExists(atPath: manager.store.downloads.appendingPathComponent(archive).path) {
                            Button("Reinstall") { manager.install(archive: archive, replacing: mod.id) }.tint(.blue)
                        }
                    }
            }
            .onMove { manager.moveMods($0, $1) }
        } header: {
            Text("Mods · lowest priority first")
        } footer: {
            Text("A mod lower in the list wins when two change the same file. Tap Order to drag. \(manager.deployedFiles) files deployed.")
        }
        if !manager.state.mods.isEmpty {
            Section {
                Button("Turn all mods off", role: .destructive) { confirmDisableAll = true }
                Button("Redeploy") { manager.apply() }
            }
        }
    }

    private func modRow(_ mod: ModRecord) -> some View {
        Toggle(isOn: Binding(get: { mod.enabled }, set: { manager.setEnabled(mod.id, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name)
                if let c = manager.conflicts[mod.id], mod.enabled {
                    Text([c.wins > 0 ? "Wins \(c.wins) conflicts" : nil, c.loses > 0 ? "Loses \(c.loses)" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(c.loses > 0 ? .orange : .secondary)
                }
                if let choices = mod.choices, !choices.isEmpty {
                    Text(choices.values.flatMap { $0 }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .disabled(manager.busy != nil)
    }

    @ViewBuilder private var pluginsSection: some View {
        Section {
            if manager.state.plugins.isEmpty {
                Text("No plugins besides the game's own.").foregroundStyle(.secondary)
            }
            ForEach(manager.state.plugins, id: \.name) { plugin in
                Toggle(isOn: Binding(get: { plugin.enabled }, set: { manager.setPlugin(plugin.name, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name)
                        if plugin.enabled, let missing = manager.missingMasters[plugin.name] {
                            Text("Needs \(missing.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .onMove { manager.movePlugins($0, $1) }
        } header: {
            Text("Load order")
        } footer: {
            Text("Masters (.esm and master-flagged plugins) always load first. The game's own and Creation Club plugins load before these and aren't listed.")
        }
    }
}

// MARK: - FOMOD wizard

struct FomodWizard: View {
    let pending: ModManager.PendingInstall
    let install: (FomodSession) -> Void
    let cancel: () -> Void
    @State private var session: FomodSession
    @State private var position = 0
    @State private var focus: (step: Int, group: Int, plugin: Int)?
    @Environment(\.dismiss) private var dismiss

    init(pending: ModManager.PendingInstall, fileState: @escaping (String) -> FomodFileState,
         install: @escaping (FomodSession) -> Void, cancel: @escaping () -> Void) {
        self.pending = pending
        self.install = install
        self.cancel = cancel
        var session = FomodSession(config: pending.config, fileState: fileState)
        if let first = session.visibleSteps.first { session.prepare(step: first) }
        _session = State(initialValue: session)
    }

    private var steps: [Int] { session.visibleSteps }
    private var step: Int? { position < steps.count ? steps[position] : nil }
    private var isLast: Bool { position >= steps.count - 1 }

    var body: some View {
        NavigationStack {
            List {
                if let image = focusImage {
                    Section {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                    }
                }
                if let step {
                    ForEach(Array(session.config.steps[step].groups.enumerated()), id: \.offset) { g, group in
                        Section {
                            ForEach(Array(group.plugins.enumerated()), id: \.offset) { p, plugin in
                                optionRow(step: step, group: g, plugin: p, option: plugin, groupType: group.type)
                            }
                        } header: {
                            Text(group.name)
                        } footer: {
                            Text(rule(group.type))
                        }
                    }
                    if let problem = session.problem(step: step) {
                        Section { Text(problem).foregroundStyle(.orange) }
                    }
                } else {
                    Section { Text("This installer has no choices to make.") }
                }
                if position == 0, let deps = session.config.dependencies,
                   !deps.holds(flags: [:], fileState: session.fileState) {
                    Section { Text("This mod lists requirements that aren't installed. It may not work until they are.").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(step.map { session.config.steps[$0].name } ?? pending.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel(); dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back") { move(-1) }.disabled(position == 0)
                    Spacer()
                    Text(steps.isEmpty ? pending.name : "\(position + 1) of \(steps.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isLast {
                        Button("Install") { install(session); dismiss() }
                            .bold().disabled(step.flatMap { session.problem(step: $0) } != nil)
                    } else {
                        Button("Next") { move(1) }
                            .disabled(step.flatMap { session.problem(step: $0) } != nil)
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func move(_ delta: Int) {
        position = max(0, min(steps.count - 1, position + delta))
        if let step { session.prepare(step: step) }
        focus = nil
    }

    private func rule(_ type: FomodGroupType) -> String {
        switch type {
        case .exactlyOne: return "Choose one."
        case .atMostOne: return "Choose one or none."
        case .atLeastOne: return "Choose at least one."
        case .all: return "All of these are installed."
        case .any: return "Choose any."
        }
    }

    private func optionRow(step: Int, group: Int, plugin: Int, option: FomodPlugin, groupType: FomodGroupType) -> some View {
        let chosen = session.choices[step]?[group]?.contains(plugin) ?? false
        let kind = session.type(step: step, group: group, plugin: plugin)
        let symbol = groupType.single ? (chosen ? "largecircle.fill.circle" : "circle") : (chosen ? "checkmark.square.fill" : "square")
        return Button {
            session.toggle(step: step, group: group, plugin: plugin)
            focus = (step, group, plugin)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).foregroundStyle(kind == .notUsable ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(option.name).foregroundStyle(kind == .notUsable ? .secondary : .primary)
                        switch kind {
                        case .recommended: badge("Recommended", .green)
                        case .required: badge("Required", .blue)
                        case .notUsable: badge("Not usable", .gray)
                        case .couldBeUsable: badge("May not work", .orange)
                        case .optional: EmptyView()
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(isFocused(step, group, plugin) ? nil : 3)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }

    private func isFocused(_ s: Int, _ g: Int, _ p: Int) -> Bool {
        guard let focus else { return false }
        return focus.step == s && focus.group == g && focus.plugin == p
    }

    /// The tapped option's picture, else the installer's own.
    private var focusImage: UIImage? {
        var path: String?
        if let focus, focus.step < session.config.steps.count,
           focus.group < session.config.steps[focus.step].groups.count,
           focus.plugin < session.config.steps[focus.step].groups[focus.group].plugins.count {
            path = session.config.steps[focus.step].groups[focus.group].plugins[focus.plugin].image
        }
        path = path ?? session.config.moduleImage
        guard let path, !path.isEmpty else { return nil }
        return UIImage(contentsOfFile: CaseFolder().resolve(pending.root, path).path)
    }
}
