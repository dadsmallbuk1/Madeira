import Foundation

// Host tests for the mod manager (app/Madeira/ModManagerCore.swift, Fomod.swift,
// build/libarchive-ios/mod_archive.c). ci/mods-tests.sh builds the fixtures,
// compiles this with those files for the Mac and runs it inside a
// case-sensitive volume, as the iPhone's is.
//
// Usage: mods-tests <fixtures folder> <scratch folder on a case-sensitive volume>

let fm = FileManager.default
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let scratch = URL(fileURLWithPath: CommandLine.arguments[2])
var failures = 0

func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
func exists(_ url: URL, _ rel: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(rel).path) }
func text(_ url: URL, _ rel: String) -> String { (try? String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
func write(_ url: URL, _ rel: String, _ content: String) {
    let target = url.appendingPathComponent(rel)
    try! fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(content.utf8).write(to: target)
}
/// A minimal plugin: a TES4 record with the master flag and MAST entries.
func plugin(_ url: URL, _ rel: String, master: Bool, masters: [String] = []) {
    var body = Data()
    func sub(_ type: String, _ payload: Data) {
        body += Data(type.utf8)
        var n = UInt16(payload.count).littleEndian
        body += Data(bytes: &n, count: 2)
        body += payload
    }
    sub("HEDR", Data(count: 12))
    for m in masters { sub("MAST", Data(m.utf8) + Data([0])); sub("DATA", Data(count: 8)) }
    var head = Data("TES4".utf8)
    var size = UInt32(body.count).littleEndian
    var flags = UInt32(master ? 1 : 0).littleEndian
    head += Data(bytes: &size, count: 4)
    head += Data(bytes: &flags, count: 4)
    head += Data(count: 12)
    let target = url.appendingPathComponent(rel)
    try! fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! (head + body).write(to: target)
}

try? fm.removeItem(at: scratch)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)

// MARK: Unpacking

do {
    let out = scratch.appendingPathComponent("unpack-zip")
    try ModUnpacker.unpack(fixtures.appendingPathComponent("windows.zip"), to: out)
    check(exists(out, "My Mod/Data/textures/sky.dds"), "zip: backslash names become folders")
    check(!exists(scratch, "evil.txt") && !exists(out, "../evil.txt"), "zip: '..' entries are skipped")
    let out7 = scratch.appendingPathComponent("unpack-7z")
    try ModUnpacker.unpack(fixtures.appendingPathComponent("plain.7z"), to: out7)
    check(text(out7, "Plain/meshes/rock.nif") == "rock", "7z: unpacked")
    do {
        try ModUnpacker.unpack(fixtures.appendingPathComponent("broken.zip"), to: scratch.appendingPathComponent("broken"))
        check(false, "broken archive reports an error")
    } catch { check(true, "broken archive reports an error: \(error.localizedDescription)") }
} catch { check(false, "unpacking: \(error)") }

// MARK: Layout

do {
    let a = scratch.appendingPathComponent("layout-a")      // wrapper / Data + game-folder files (SKSE style)
    write(a, "skse64_2_03_01/skse64_loader.exe", "exe")
    write(a, "skse64_2_03_01/Data/Scripts/a.pex", "pex")
    check(ModLayout.kind(ModLayout.contentRoot(a)) == .gameFolder, "layout: wrapper with Data and an exe is game-folder")
    let modA = scratch.appendingPathComponent("mod-a")
    try ModLayout.install(a, into: modA)
    check(exists(modA, "skse64_loader.exe") && exists(modA, "Data/Scripts/a.pex"), "layout: SKSE-style install")

    let b = scratch.appendingPathComponent("layout-b")      // Data content at the top
    write(b, "Cool Mod.esp", "esp")
    write(b, "meshes/x.nif", "nif")
    write(b, "__MACOSX/junk", "junk")
    check(ModLayout.kind(ModLayout.contentRoot(b)) == .data, "layout: plugin + meshes is Data content")
    let modB = scratch.appendingPathComponent("mod-b")
    try ModLayout.install(b, into: modB)
    check(exists(modB, "Data/Cool Mod.esp") && exists(modB, "Data/meshes/x.nif") && !exists(modB, "Data/__MACOSX"), "layout: Data install, clutter dropped")

    let c = scratch.appendingPathComponent("layout-c")      // lower-case data folder
    write(c, "data/interface/a.swf", "swf")
    let modC = scratch.appendingPathComponent("mod-c")
    try ModLayout.install(c, into: modC)
    check(exists(modC, "Data/interface/a.swf"), "layout: 'data' becomes 'Data'")
} catch { check(false, "layout: \(error)") }

// MARK: FOMOD

do {
    let root = fixtures.appendingPathComponent("fomod-mod")
    guard let found = ModLayout.fomod(in: root) else { throw ModError.message("fomod not found") }
    let config = try FomodConfig.load(found.config)
    check(config.moduleName == "Test Installer", "fomod: UTF-16 ModuleConfig parsed")
    check(config.steps.map(\.name) == ["Main", "Extras", "Hidden"], "fomod: explicit step order kept")
    check(config.steps[0].groups[0].plugins.map(\.name) == ["A Option", "B Option"], "fomod: options sorted by name")

    var session = FomodSession(config: config) { name in name.lowercased() == "skyrim.esm" ? .active : .missing }
    session.prepare(step: 0)
    check(session.choices[0]?[0] == [1], "fomod: recommended option preselected in a one-of group")
    check(session.visibleSteps == [0, 1], "fomod: step shown by a flag, step hidden by a missing file")
    session.toggle(step: 0, group: 0, plugin: 0)
    check(session.choices[0]?[0] == [0], "fomod: one-of group switches")
    check(!session.isVisible(1), "fomod: flag change hides the Extras step")
    session.toggle(step: 0, group: 0, plugin: 1)
    session.prepare(step: 1)
    check(session.choices[1]?[0] == [], "fomod: any-group starts empty")
    session.toggle(step: 1, group: 0, plugin: 0)
    let files = session.files().map(\.source)
    check(files.first == "core", "fomod: required files first")
    check(files.contains("optB") && files.contains("extras/patch.esp") && files.contains("cond"), "fomod: chosen and conditional files")
    check(!files.contains("optA"), "fomod: unchosen option not installed")

    let mod = scratch.appendingPathComponent("mod-fomod")
    try session.install(from: found.root, into: mod)
    check(exists(mod, "Data/Core.esp"), "fomod install: folder with empty destination lands in Data")
    check(text(mod, "Data/textures/b.dds") == "B", "fomod install: higher priority wins")
    check(exists(mod, "Data/Patches/patch.esp"), "fomod install: file destination")
    check(exists(mod, "Data/cond.txt"), "fomod install: conditional install")
} catch { check(false, "fomod: \(error)") }

// MARK: Deploying and plugins

do {
    let docs = scratch.appendingPathComponent("Documents")
    let game = docs.appendingPathComponent("wine/drive_c/Program Files (x86)/Steam/steamapps/common/Skyrim Special Edition")
    plugin(game, "Data/Skyrim.esm", master: true)
    write(game, "Data/Textures/sky.dds", "vanilla")
    write(game, "Skyrim.ccc", "ccBGSSSE001-Fish.esm\r\n")
    plugin(game, "Data/ccBGSSSE001-Fish.esm", master: true)
    try fm.createDirectory(at: docs.appendingPathComponent("wine/drive_c/users/mobile/AppData/Local/Skyrim Special Edition"),
                           withIntermediateDirectories: true)

    let store = ModStore(game: .skyrimSE, documents: docs, gameRoot: game)
    try store.prepare()
    var state = ModState()
    let a = ModRecord(id: UUID(), name: "A", enabled: true, archive: nil, installed: Date(), choices: nil)
    let b = ModRecord(id: UUID(), name: "B", enabled: true, archive: nil, installed: Date(), choices: nil)
    write(store.folder(of: a), "Data/textures/sky.dds", "A")
    write(store.folder(of: a), "Data/textures/clouds.dds", "A")
    plugin(store.folder(of: a), "Data/A.esp", master: false, masters: ["Skyrim.esm"])
    write(store.folder(of: b), "Data/TEXTURES/SKY.DDS", "B")
    plugin(store.folder(of: b), "Data/B.esp", master: false, masters: ["Skyrim.esm", "Missing.esm"])
    plugin(store.folder(of: b), "Data/BMaster.esp", master: true)
    state.mods = [a, b]

    var record = store.loadDeploy()
    _ = try ModDeployer.deploy(state, store: store, record: &record)
    let dataEntries = try fm.contentsOfDirectory(atPath: game.appendingPathComponent("Data").path)
    check(!dataEntries.contains("textures") && !dataEntries.contains("TEXTURES"), "deploy: folders merged into existing 'Textures'")
    check(text(game, "Data/Textures/sky.dds") == "B", "deploy: later mod wins")
    check(text(game, "Data/Textures/clouds.dds") == "A", "deploy: non-conflicting file deployed")
    check(exists(store.backups, "Data/Textures/sky.dds"), "deploy: game file backed up")

    state.plugins = ModPlugins.refresh(state.plugins, store: store)
    check(state.plugins.map(\.name) == ["BMaster.esp", "A.esp", "B.esp"], "plugins: masters first, base and CC plugins left out")
    try ModPlugins.apply(state.plugins, store: store)
    check(text(store.pluginsFile.deletingLastPathComponent(), "plugins.txt").contains("*A.esp"), "plugins: plugins.txt written")
    check(ModPlugins.missingMasters(state.plugins, store: store)["B.esp"] == ["Missing.esm"], "plugins: missing master reported")

    state.mods[1].enabled = false
    _ = try ModDeployer.deploy(state, store: store, record: &record)
    check(text(game, "Data/Textures/sky.dds") == "A", "deploy: disabling B brings back A's file")
    check(!exists(game, "Data/B.esp"), "deploy: B's plugin removed")

    write(game, "Data/Textures/clouds.dds.tmp", "x")
    state.mods[0].enabled = false
    _ = try ModDeployer.deploy(state, store: store, record: &record)
    check(text(game, "Data/Textures/sky.dds") == "vanilla", "deploy: nothing enabled restores the game's file")
    check(!exists(game, "Data/Textures/clouds.dds") && exists(game, "Data/Textures"), "deploy: removed files gone, game folder kept")

    state.plugins = ModPlugins.refresh(state.plugins, store: store)
    try ModPlugins.apply(state.plugins, store: store)
    check(!text(store.pluginsFile.deletingLastPathComponent(), "plugins.txt").contains("A.esp"), "plugins: absent plugins left out of plugins.txt")
    check(state.plugins.contains { $0.name == "A.esp" }, "plugins: absent plugin keeps its place in the manager")
} catch { check(false, "deploy: \(error)") }

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
