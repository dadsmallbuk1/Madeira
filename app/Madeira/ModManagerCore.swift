import Foundation

// The mod manager's storage, installer and deployment (no UI; ModsView.swift
// is the screen, Fomod.swift the scripted installer). It is plain Foundation
// so ci/mods-tests.sh can compile and test it on the build Mac.
//
// How it works, the way Mod Organizer and Vortex do it on a PC:
// - Each installed mod is a folder of its own under Documents/Mods/<game>/mods,
//   laid out like the game folder (Data/..., and the odd file for the game's
//   own folder, such as an SKSE build).
// - Deploying puts the files of every enabled mod into the game folder, the
//   later mod in the list winning a conflict. Files go in as APFS clones, so a
//   deployed mod costs no extra space. A game file a mod replaces is moved to
//   backup/ first and comes back when no enabled mod provides it any more.
// - deploy.json records what is deployed. Only a file whose inode is still the
//   clone's is ever removed again: anything the game or the user changed or
//   put there stays.
// - plugins.txt (the game's load order) lists the enabled plugins; the
//   manager keeps every plugin's place in its own list, so a plugin that comes
//   back keeps its position.

// MARK: - Games

/// A game the mod manager supports.
struct ModGame: Equatable, Sendable {
    let key: String
    let title: String
    let steamAppIDs: [Int]
    /// Lower-case program names that identify a non-Steam install (GOG).
    let executables: [String]
    /// The game's folder under AppData/Local, which holds plugins.txt.
    let appDataFolder: String
    /// Plugins the game always loads first, never listed in plugins.txt.
    let baseMasters: [String]
    /// A file in the game folder listing more always-loaded plugins (Creation Club).
    let implicitPluginList: String?

    static let skyrimSE = ModGame(
        key: "SkyrimSE", title: "Skyrim Special Edition", steamAppIDs: [489830],
        executables: ["skyrimse.exe", "skyrimselauncher.exe"], appDataFolder: "Skyrim Special Edition",
        baseMasters: ["Skyrim.esm", "Update.esm", "Dawnguard.esm", "HearthFires.esm", "Dragonborn.esm"],
        implicitPluginList: "Skyrim.ccc")

    static let all: [ModGame] = [skyrimSE]

    static func detect(steamAppID: Int?, windowsPath: String) -> ModGame? {
        if let id = steamAppID, let game = all.first(where: { $0.steamAppIDs.contains(id) }) { return game }
        let exe = windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { $0.lowercased() } ?? ""
        return all.first { $0.executables.contains(exe) }
    }
}

// MARK: - Errors

enum ModError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// MARK: - Case-insensitive paths

/// Windows names folders and files without regard to case and mods rely on it
/// ("textures" and "Textures" are one folder). The app's files live on a
/// case-sensitive volume, so every path into the game folder is matched
/// against what is already on disk before anything is created.
final class CaseFolder {
    private var listings: [String: [String: String]] = [:]
    private let fm = FileManager.default

    /// Lower-cased name -> name on disk, for the folder at `dir`.
    private func listing(_ dir: URL) -> [String: String] {
        if let cached = listings[dir.path] { return cached }
        var map: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] { map[name.lowercased()] = name }
        listings[dir.path] = map
        return map
    }

    /// The existing child of `dir` called `name` in any case, or nil.
    func existing(_ dir: URL, _ name: String) -> URL? {
        listing(dir)[name.lowercased()].map { dir.appendingPathComponent($0) }
    }

    /// `relative` ("Data/Textures/a.dds") under `root`, every part spelt as on
    /// disk where it exists and as given where it does not.
    func resolve(_ root: URL, _ relative: String) -> URL {
        var url = root
        var missing = false
        for part in relative.split(separator: "/").map(String.init) {
            if !missing, let found = existing(url, part) { url = found } else { url.appendPathComponent(part); missing = true }
        }
        return url
    }

    /// Note a name that was just created (or removed) so later lookups see it.
    func noteCreated(_ url: URL) {
        let dir = url.deletingLastPathComponent().path
        if listings[dir] != nil { listings[dir]![url.lastPathComponent.lowercased()] = url.lastPathComponent }
    }
    func noteRemoved(_ url: URL) {
        let dir = url.deletingLastPathComponent().path
        listings[dir]?[url.lastPathComponent.lowercased()] = nil
        listings[url.path] = nil
    }
}

enum ModFiles {
    static let fm = FileManager.default

    /// Every regular file under `root`, as "a/b/c" paths relative to it.
    static func relativeFiles(_ root: URL) -> [String] {
        guard let walker = fm.enumerator(atPath: root.path) else { return [] }
        var out: [String] = []
        while let rel = walker.nextObject() as? String {
            if (walker.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { out.append(rel) }
        }
        return out
    }

    static func inode(_ url: URL) -> UInt64? {
        (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// `source` copied to `target` as an APFS clone (no extra space), or as a
    /// plain copy where cloning is not possible. `target` must not exist.
    static func cloneOrCopy(_ source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, 0) == 0 { return }
        try fm.copyItem(at: source, to: target)
    }

    /// Make sure the folder for `url` exists.
    static func makeParent(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Move (or merge) everything inside `source` into `target`, folders merged
    /// case-insensitively and files replaced.
    static func merge(_ source: URL, into target: URL, caseFolder: CaseFolder = CaseFolder()) throws {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isDir)
            if let existing = caseFolder.existing(target, name) {
                var existingIsDir: ObjCBool = false
                fm.fileExists(atPath: existing.path, isDirectory: &existingIsDir)
                if isDir.boolValue && existingIsDir.boolValue {
                    try merge(from, into: existing, caseFolder: caseFolder)
                    try? fm.removeItem(at: from)
                    continue
                }
                try fm.removeItem(at: existing)
                caseFolder.noteRemoved(existing)
            }
            let to = target.appendingPathComponent(name)
            try fm.moveItem(at: from, to: to)
            caseFolder.noteCreated(to)
        }
    }

    /// Copy a file, or a folder's contents, to `target` (folders merged
    /// case-insensitively, files replaced), as clones where possible.
    static func copyMerging(_ source: URL, to target: URL, caseFolder: CaseFolder) throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source.path) where !junk(name) {
                let dest = caseFolder.existing(target, name) ?? target.appendingPathComponent(name)
                try copyMerging(source.appendingPathComponent(name), to: dest, caseFolder: caseFolder)
                caseFolder.noteCreated(dest)
            }
        } else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try makeParent(target)
            try cloneOrCopy(source, to: target)
        }
    }

    /// Files no mod means to install: system clutter from the packing machine.
    static func junk(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "__macosx" || n == ".ds_store" || n == "thumbs.db" || n == "desktop.ini"
    }
}

// MARK: - Mods on disk

struct ModRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    /// The archive it came from, a file name in downloads/ (nil once deleted).
    var archive: String?
    var installed: Date
    /// The installer's choices, step name -> option names (shown, and kept for a reinstall).
    var choices: [String: [String]]?
}

/// A plugin's place in the manager's load order.
struct PluginState: Codable, Equatable, Sendable {
    var name: String
    var enabled: Bool
}

struct ModState: Codable, Sendable {
    /// Priority order: a later mod wins a conflict with an earlier one.
    var mods: [ModRecord] = []
    /// Every plugin the manager has seen, in load order.
    var plugins: [PluginState] = []
}

struct DeployState: Codable, Sendable {
    struct File: Codable, Sendable {
        var path: String      // relative to the game folder, as on disk
        var mod: UUID
        var inode: UInt64
    }
    /// Lower-cased game-relative path -> what is deployed there.
    var files: [String: File] = [:]
    /// Lower-cased game-relative path -> the original file's place under backup/.
    var backups: [String: String] = [:]
    /// Folders deployment created (game-relative), removed again once empty.
    var createdFolders: [String] = []
}

/// One game's mod storage: Documents/Mods/<game key>/.
struct ModStore: Sendable {
    let game: ModGame
    let root: URL
    /// The game's install folder (the one holding Data).
    let gameRoot: URL
    /// drive_c, for plugins.txt under the Wine user's AppData.
    let drive: URL

    var modsFolder: URL { root.appendingPathComponent("mods", isDirectory: true) }
    var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    var backups: URL { root.appendingPathComponent("backup", isDirectory: true) }
    var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("mods.json") }
    var deployFile: URL { root.appendingPathComponent("deploy.json") }

    init(game: ModGame, documents: URL, gameRoot: URL) {
        self.game = game
        self.root = documents.appendingPathComponent("Mods/\(game.key)", isDirectory: true)
        self.gameRoot = gameRoot
        self.drive = documents.appendingPathComponent("wine/drive_c", isDirectory: true)
    }

    func folder(of mod: ModRecord) -> URL { modsFolder.appendingPathComponent(mod.id.uuidString, isDirectory: true) }

    func prepare() throws {
        for dir in [modsFolder, downloads, backups, work] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func loadState() -> ModState { load(stateFile) ?? ModState() }
    func loadDeploy() -> DeployState { load(deployFile) ?? DeployState() }
    func save(_ state: ModState) throws { try save(state, to: stateFile) }
    func save(_ deploy: DeployState) throws { try save(deploy, to: deployFile) }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// The game's Data folder as spelt on disk.
    var dataFolder: URL { CaseFolder().existing(gameRoot, "Data") ?? gameRoot.appendingPathComponent("Data") }

    /// plugins.txt under the Wine user's AppData/Local/<game>. The user is the
    /// one whose AppData already has the game's folder, else "mobile" (Madeira's).
    var pluginsFile: URL {
        let users = drive.appendingPathComponent("users")
        let folder = CaseFolder()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [])
            .filter { $0.lowercased() != "public" }
        for name in names {
            let base = folder.resolve(users.appendingPathComponent(name), "AppData/Local/\(game.appDataFolder)")
            if FileManager.default.fileExists(atPath: base.path) { return base.appendingPathComponent("plugins.txt") }
        }
        let user = names.first { $0.lowercased() == "mobile" } ?? names.first ?? "mobile"
        return folder.resolve(users.appendingPathComponent(user), "AppData/Local/\(game.appDataFolder)/plugins.txt")
    }
}

// MARK: - Installing

/// Where an unpacked mod's files go, found from its folder layout the way
/// MO2 does: wrapper folders are skipped, a "Data" folder means the archive
/// mirrors the game folder, Data's own content (plugins, meshes, textures,
/// SKSE...) means it belongs in Data.
enum ModLayout {
    static let dataFolders: Set<String> = [
        "meshes", "textures", "scripts", "skse", "interface", "sound", "music", "seq", "strings",
        "shadersfx", "lodsettings", "grass", "video", "materials", "source", "dialogueviews",
        "calientetools", "nemesis_engine", "netscriptframework", "skyproc patchers", "fomod",
        "dyndolod", "tools", "facegen", "lightplacer", "mcm", "platform", "shaders", "distantlod",
        "lod", "trees", "actors", "terrain", "seasons", "sky", "particlelights",
    ]
    static let pluginExtensions: Set<String> = ["esp", "esm", "esl", "bsa", "ba2"]

    enum Kind: Equatable { case data, gameFolder }

    /// A folder's names without packing clutter, and without the scripted
    /// installer's own "fomod" folder, which is never installed.
    private static func visible(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !ModFiles.junk($0) && $0.lowercased() != "fomod" }
    }
    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    /// The folder that holds the mod's content: wrapper folders (one folder and
    /// nothing else, not itself a Data folder) are stepped into.
    static func contentRoot(_ root: URL) -> URL {
        var url = root
        for _ in 0..<4 {
            let names = visible(url)
            guard names.count == 1, isDir(url.appendingPathComponent(names[0])) else { break }
            let n = names[0].lowercased()
            if n == "data" || dataFolders.contains(n) { break }
            url.appendPathComponent(names[0])
        }
        return url
    }

    static func kind(_ content: URL) -> Kind {
        let names = visible(content)
        if names.contains(where: { $0.lowercased() == "data" && isDir(content.appendingPathComponent($0)) }) { return .gameFolder }
        for name in names {
            let lower = name.lowercased()
            if isDir(content.appendingPathComponent(name)) {
                if dataFolders.contains(lower) { return .data }
            } else if pluginExtensions.contains((lower as NSString).pathExtension) {
                return .data
            }
        }
        if names.contains(where: { ["exe", "dll"].contains(($0.lowercased() as NSString).pathExtension) }) { return .gameFolder }
        return .data
    }

    /// Move an unpacked mod's content into `target` (the mod's folder) laid
    /// out like the game folder.
    static func install(_ unpacked: URL, into target: URL) throws {
        let content = contentRoot(unpacked)
        let caseFolder = CaseFolder()
        switch kind(content) {
        case .data:
            try ModFiles.merge(content, into: target.appendingPathComponent("Data"), caseFolder: caseFolder)
        case .gameFolder:
            for name in visible(content) {
                let from = content.appendingPathComponent(name)
                if name.lowercased() == "data", isDir(from) {
                    try ModFiles.merge(from, into: target.appendingPathComponent("Data"), caseFolder: caseFolder)
                } else if isDir(from) {
                    try ModFiles.merge(from, into: target.appendingPathComponent(name), caseFolder: caseFolder)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    let to = target.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                    try FileManager.default.moveItem(at: from, to: to)
                }
            }
        }
    }

    /// The scripted installer's ModuleConfig.xml, if the unpacked mod has one:
    /// a "fomod" folder at most three folders down. Its parent is the root the
    /// installer's file paths are relative to.
    static func fomod(in unpacked: URL) -> (config: URL, root: URL)? {
        let folder = CaseFolder()
        var level = [unpacked]
        for _ in 0..<4 {
            var next: [URL] = []
            for dir in level {
                if let fomod = folder.existing(dir, "fomod"), isDir(fomod),
                   let config = folder.existing(fomod, "ModuleConfig.xml") {
                    return (config, dir)
                }
                next += visible(dir).map { dir.appendingPathComponent($0) }.filter(isDir)
            }
            level = next
        }
        return nil
    }
}

// MARK: - Deploying

struct DeployReport: Sendable {
    var deployed = 0
    var removed = 0
    var restored = 0
    var keptChanged: [String] = []
}

enum ModDeployer {
    /// Bring the game folder in line with `state`: every enabled mod's files in,
    /// the rest out, originals restored. `progress` gets a fraction 0...1.
    static func deploy(_ state: ModState, store: ModStore, record: inout DeployState,
                       progress: ((Double) -> Void)? = nil) throws -> DeployReport {
        let fm = FileManager.default
        var report = DeployReport()
        let caseFolder = CaseFolder()

        // What should be there: lower-cased path -> (path, mod, source).
        var wanted: [String: (path: String, mod: UUID, source: URL)] = [:]
        for mod in state.mods where mod.enabled {
            let folder = store.folder(of: mod)
            for rel in ModFiles.relativeFiles(folder) {
                wanted[rel.lowercased()] = (rel, mod.id, folder.appendingPathComponent(rel))
            }
        }
        let total = Double(max(1, record.files.count + wanted.count))
        var done = 0.0
        func step() { done += 1; if Int(done) % 200 == 0 { progress?(done / total) } }

        // Out: files no longer wanted, or now provided by another mod.
        for (key, file) in record.files.sorted(by: { $0.key < $1.key }) {
            step()
            if let want = wanted[key], want.mod == file.mod { continue }
            let target = caseFolder.resolve(store.gameRoot, file.path)
            if let ino = ModFiles.inode(target) {
                if ino == file.inode {
                    try fm.removeItem(at: target)
                    caseFolder.noteRemoved(target)
                    report.removed += 1
                } else {
                    report.keptChanged.append(file.path)
                }
            }
            record.files[key] = nil
            if wanted[key] == nil, let backup = record.backups[key] {
                let saved = store.backups.appendingPathComponent(backup)
                if fm.fileExists(atPath: saved.path), !fm.fileExists(atPath: target.path) {
                    try ModFiles.makeParent(target)
                    try fm.moveItem(at: saved, to: target)
                    caseFolder.noteCreated(target)
                    report.restored += 1
                }
                record.backups[key] = nil
            }
        }
        try store.save(record)

        // In: wanted files not deployed yet.
        var created = Set(record.createdFolders)
        for (key, want) in wanted.sorted(by: { $0.key < $1.key }) {
            step()
            if record.files[key] != nil { continue }
            let target = caseFolder.resolve(store.gameRoot, want.path)
            // Folders on the way that do not exist yet are ours to remove later.
            var parent = target.deletingLastPathComponent()
            var newFolders: [URL] = []
            while !fm.fileExists(atPath: parent.path), parent.path.count > store.gameRoot.path.count {
                newFolders.append(parent)
                parent = parent.deletingLastPathComponent()
            }
            for folder in newFolders.reversed() {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                caseFolder.noteCreated(folder)
                created.insert(relative(folder, to: store.gameRoot))
            }
            if fm.fileExists(atPath: target.path) {
                // A file nothing deployed: the game's own or put there by hand. Keep it safe.
                if record.backups[key] == nil {
                    let rel = relative(target, to: store.gameRoot)
                    let saved = store.backups.appendingPathComponent(rel)
                    if fm.fileExists(atPath: saved.path) { try fm.removeItem(at: saved) }
                    try ModFiles.makeParent(saved)
                    try fm.moveItem(at: target, to: saved)
                    record.backups[key] = rel
                } else {
                    try fm.removeItem(at: target)
                }
                caseFolder.noteRemoved(target)
            }
            try ModFiles.cloneOrCopy(want.source, to: target)
            caseFolder.noteCreated(target)
            record.files[key] = .init(path: relative(target, to: store.gameRoot), mod: want.mod,
                                      inode: ModFiles.inode(target) ?? 0)
            report.deployed += 1
            if report.deployed % 500 == 0 { try store.save(record) }
        }

        // Folders deployment made that are empty now, deepest first.
        for folder in created.sorted(by: { $0.count > $1.count }) {
            let url = store.gameRoot.appendingPathComponent(folder)
            if let items = try? fm.contentsOfDirectory(atPath: url.path) {
                if items.filter({ !ModFiles.junk($0) }).isEmpty {
                    try? fm.removeItem(at: url)
                    created.remove(folder)
                }
            } else {
                created.remove(folder)
            }
        }
        record.createdFolders = created.sorted()
        try store.save(record)
        progress?(1)
        return report
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
    }

    /// Which mods each mod overrides and is overridden by (enabled mods only),
    /// for the list's conflict marks.
    static func conflicts(_ state: ModState, store: ModStore) -> [UUID: (wins: Int, loses: Int)] {
        var owner: [String: UUID] = [:]
        var result: [UUID: (wins: Int, loses: Int)] = [:]
        for mod in state.mods where mod.enabled {
            for rel in ModFiles.relativeFiles(store.folder(of: mod)) {
                let key = rel.lowercased()
                if let previous = owner[key] {
                    result[mod.id, default: (0, 0)].wins += 1
                    result[previous, default: (0, 0)].loses += 1
                }
                owner[key] = mod.id
            }
        }
        return result
    }
}

// MARK: - Plugins

/// What a plugin's header (its TES4 record) says.
struct PluginHeader: Equatable, Sendable {
    var isMaster: Bool
    var isLight: Bool
    var masters: [String]

    /// Read the TES4 record of a .esp/.esm/.esl. Nil when it isn't one.
    static func read(_ url: URL) -> PluginHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 24), head.count == 24,
              head.prefix(4) == Data("TES4".utf8) else { return nil }
        let size = Int(head.loadLE(4) as UInt32)
        let flags = head.loadLE(8) as UInt32
        guard size < 1 << 20, let body = try? handle.read(upToCount: size), body.count == size else { return nil }
        var masters: [String] = []
        var i = 0
        while i + 6 <= body.count {
            let type = String(decoding: body[body.startIndex + i ..< body.startIndex + i + 4], as: UTF8.self)
            let len = Int(body.loadLE(i + 4) as UInt16)
            let start = body.startIndex + i + 6
            guard start + len <= body.endIndex else { break }
            if type == "MAST" {
                let bytes = body[start ..< start + len].prefix { $0 != 0 }
                masters.append(String(decoding: bytes, as: UTF8.self))
            }
            i += 6 + len
        }
        let ext = (url.pathExtension as NSString).lowercased
        return PluginHeader(isMaster: flags & 0x1 != 0 || ext == "esm" || ext == "esl",
                            isLight: flags & 0x200 != 0 || ext == "esl", masters: masters)
    }
}

private extension Data {
    /// A little-endian integer at `offset` (bytes from the start).
    func loadLE<T: FixedWidthInteger>(_ offset: Int) -> T {
        var value: T = 0
        for k in 0..<MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: self[self.startIndex + offset + k]) << (8 * k)
        }
        return value
    }
}

enum ModPlugins {
    static let extensions: Set<String> = ["esp", "esm", "esl"]

    /// Plugins in the Data folder, as spelt on disk.
    static func present(in data: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [])
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// Plugins the game always loads: its base masters and the Creation Club list.
    static func implicit(_ store: ModStore) -> Set<String> {
        var names = Set(store.game.baseMasters.map { $0.lowercased() })
        if let list = store.game.implicitPluginList,
           let url = CaseFolder().existing(store.gameRoot, list),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.insert(name.lowercased()) }
            }
        }
        return names
    }

    /// plugins.txt: "*Name.esp" is enabled, "Name.esp" disabled, "#" a comment.
    static func readPluginsTxt(_ url: URL) -> [PluginState] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var out: [PluginState] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("*") { out.append(.init(name: String(line.dropFirst()), enabled: true)) }
            else { out.append(.init(name: line, enabled: false)) }
        }
        return out
    }

    static func writePluginsTxt(_ plugins: [PluginState], to url: URL) throws {
        var text = "# This file is used by Skyrim to keep track of your downloaded content.\r\n# Please do not modify this file.\r\n"
        for p in plugins { text += (p.enabled ? "*" : "") + p.name + "\r\n" }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// The manager's load order brought up to date with what is in Data:
    /// known plugins keep their place, plugins.txt's order is adopted for
    /// plugins the manager hasn't seen, new ones go last (enabled), and
    /// masters always load before the rest.
    static func refresh(_ known: [PluginState], store: ModStore) -> [PluginState] {
        let data = store.dataFolder
        let onDisk = present(in: data)
        let implicit = implicit(store)
        let available = Dictionary(onDisk.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var order = known
        var seen = Set(order.map { $0.name.lowercased() })
        for p in readPluginsTxt(store.pluginsFile) where !seen.contains(p.name.lowercased()) {
            order.append(p); seen.insert(p.name.lowercased())
        }
        for name in onDisk.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where !seen.contains(name.lowercased()) {
            order.append(.init(name: name, enabled: true)); seen.insert(name.lowercased())
        }
        // Spelling as on disk; implicit plugins are the game's business.
        order = order.compactMap { p in
            if implicit.contains(p.name.lowercased()) { return nil }
            return PluginState(name: available[p.name.lowercased()] ?? p.name, enabled: p.enabled)
        }
        let masters = Set(order.filter { available[$0.name.lowercased()] != nil }
            .filter { PluginHeader.read(data.appendingPathComponent($0.name))?.isMaster ?? false }
            .map { $0.name.lowercased() })
        return order.filter { masters.contains($0.name.lowercased()) } + order.filter { !masters.contains($0.name.lowercased()) }
    }

    /// Write plugins.txt from the manager's order: plugins present in Data only.
    static func apply(_ order: [PluginState], store: ModStore) throws {
        let present = Set(present(in: store.dataFolder).map { $0.lowercased() })
        try writePluginsTxt(order.filter { present.contains($0.name.lowercased()) }, to: store.pluginsFile)
    }

    /// Enabled plugins' masters that are missing or not enabled, by plugin.
    static func missingMasters(_ order: [PluginState], store: ModStore) -> [String: [String]] {
        let data = store.dataFolder
        let presentNames = Set(present(in: data).map { $0.lowercased() })
        let implicit = implicit(store)
        let active = Set(order.filter { $0.enabled && presentNames.contains($0.name.lowercased()) }.map { $0.name.lowercased() })
            .union(implicit.filter { presentNames.contains($0) })
        var result: [String: [String]] = [:]
        for p in order where p.enabled && presentNames.contains(p.name.lowercased()) {
            guard let header = PluginHeader.read(data.appendingPathComponent(p.name)) else { continue }
            let missing = header.masters.filter { !active.contains($0.lowercased()) }
            if !missing.isEmpty { result[p.name] = missing }
        }
        return result
    }
}

// MARK: - Unpacking

enum ModUnpacker {
    final class ProgressBox { var handler: ((Int64, Int64) -> Bool)?; init(_ h: ((Int64, Int64) -> Bool)?) { handler = h } }

    /// Unpack `archive` into `dest` with libarchive (zip, 7z, rar).
    /// `progress(files, bytes)` returning false stops it.
    static func unpack(_ archive: URL, to dest: URL, progress: ((Int64, Int64) -> Bool)? = nil) throws {
        var message = [CChar](repeating: 0, count: 512)
        let box = ProgressBox(progress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }
        let callback: mod_archive_progress_fn = { ctx, files, bytes in
            guard let ctx else { return 0 }
            let p = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            return (p.handler?(files, bytes) ?? true) ? 0 : 1
        }
        let result = mod_archive_extract(archive.path, dest.path, callback, context, &message, message.count)
        if result != 0 {
            throw ModError.message(String(cString: message).isEmpty ? "The archive could not be unpacked." : String(cString: message))
        }
    }
}
