import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// FOMOD, the scripted installer many Skyrim mods ship (fomod/ModuleConfig.xml):
// pages of options, the files each option installs, flags options set and
// later pages and files depend on. This is the model and its rules; the
// wizard is FomodWizard in ModsView.swift. Plain Foundation, so
// ci/mods-tests.sh tests it on the build Mac.
//
// Follows the schema (ModuleConfig.xsd 5.x) as Vortex and MO2 read it:
// - steps, groups and options are sorted by name unless order="Explicit";
// - a step shows only when its visibility dependencies hold for the flags
//   the options chosen on earlier steps set;
// - an option's type (Required, Recommended, Optional, NotUsable,
//   CouldBeUsable) is fixed or the first matching dependency pattern's;
// - the files are the required ones, the chosen options' ones, and the
//   conditional installs whose dependencies hold at the end, installed in
//   priority order (equal priorities: document order), a later one replacing
//   an earlier one at the same place.

// MARK: - XML

/// A minimal element tree; names are compared without case, since installers
/// are hand-written and not always exact.
final class FomodElement {
    let name: String
    var attributes: [String: String] = [:]
    var children: [FomodElement] = []
    var text = ""

    init(name: String) { self.name = name }

    func attribute(_ key: String) -> String? {
        if let v = attributes[key] { return v }
        let lower = key.lowercased()
        return attributes.first { $0.key.lowercased() == lower }?.value
    }
    func child(_ name: String) -> FomodElement? { children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func all(_ name: String) -> [FomodElement] { children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

final class FomodXMLReader: NSObject, XMLParserDelegate {
    private var stack: [FomodElement] = []
    private var root: FomodElement?
    private var failure: Error?

    /// Parse ModuleConfig.xml / info.xml. Files are often UTF-16 or carry a
    /// wrong encoding declaration, so the text is decoded here and handed to
    /// the parser as UTF-8 without its declaration.
    static func parse(_ data: Data) throws -> FomodElement {
        let text = decode(data)
        var body = text
        if let start = body.range(of: "<?xml"), let end = body.range(of: "?>", range: start.upperBound..<body.endIndex) {
            body.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let reader = FomodXMLReader()
        let parser = XMLParser(data: Data(body.utf8))
        parser.delegate = reader
        if !parser.parse() || reader.root == nil {
            throw ModError.message("The installer's ModuleConfig.xml could not be read"
                + (parser.parserError.map { ": \($0.localizedDescription)" } ?? "."))
        }
        return reader.root!
    }

    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        func dropBOM(_ text: String) -> String { text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return dropBOM(String(data: data, encoding: .utf16LittleEndian) ?? "") }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return dropBOM(String(data: data, encoding: .utf16BigEndian) ?? "") }
        if bytes.count >= 4, bytes[0] == 0x3C, bytes[1] == 0, bytes[2] == 0x3F, bytes[3] == 0 { return String(data: data, encoding: .utf16LittleEndian) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return dropBOM(text) }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // "fomod:config" and plain "config" alike.
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let element = FomodElement(name: name)
        element.attributes = attributeDict
        stack.last?.children.append(element)
        if stack.isEmpty { root = element }
        stack.append(element)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

// MARK: - Model

enum FomodPluginType: String, Sendable {
    case required = "Required", optional = "Optional", recommended = "Recommended"
    case notUsable = "NotUsable", couldBeUsable = "CouldBeUsable"

    init(_ raw: String?) {
        self = FomodPluginType.allCases.first { $0.rawValue.caseInsensitiveCompare(raw ?? "") == .orderedSame } ?? .optional
    }
    static let allCases: [FomodPluginType] = [.required, .optional, .recommended, .notUsable, .couldBeUsable]
}

enum FomodGroupType: String, Sendable {
    case exactlyOne = "SelectExactlyOne", atMostOne = "SelectAtMostOne", atLeastOne = "SelectAtLeastOne"
    case all = "SelectAll", any = "SelectAny"

    init(_ raw: String?) {
        let all: [FomodGroupType] = [.exactlyOne, .atMostOne, .atLeastOne, .all, .any]
        self = all.first { $0.rawValue.caseInsensitiveCompare(raw ?? "") == .orderedSame } ?? .any
    }
    var single: Bool { self == .exactlyOne || self == .atMostOne }
}

enum FomodFileState: String, Sendable { case active = "Active", inactive = "Inactive", missing = "Missing" }

indirect enum FomodCondition: Sendable {
    case all([FomodCondition])
    case any([FomodCondition])
    case flag(name: String, value: String)
    case file(name: String, state: FomodFileState)
    /// gameDependency / fommDependency: versions this manager doesn't check.
    case always

    /// <dependencies operator="And|Or"> or <visible>/<moduleDependencies>.
    static func parse(_ element: FomodElement) -> FomodCondition {
        var parts: [FomodCondition] = []
        for child in element.children {
            switch child.name.lowercased() {
            case "flagdependency":
                parts.append(.flag(name: child.attribute("flag") ?? "", value: child.attribute("value") ?? ""))
            case "filedependency":
                let raw = (child.attribute("state") ?? "").lowercased()
                let state: FomodFileState = raw == "missing" ? .missing : raw == "inactive" ? .inactive : .active
                parts.append(.file(name: child.attribute("file") ?? "", state: state))
            case "dependencies":
                parts.append(parse(child))
            default:
                parts.append(.always)   // gameDependency, fommDependency, foseDependency...
            }
        }
        return (element.attribute("operator") ?? "And").caseInsensitiveCompare("Or") == .orderedSame ? .any(parts) : .all(parts)
    }

    func holds(flags: [String: String], fileState: (String) -> FomodFileState) -> Bool {
        switch self {
        case .all(let parts): return parts.allSatisfy { $0.holds(flags: flags, fileState: fileState) }
        case .any(let parts): return parts.isEmpty || parts.contains { $0.holds(flags: flags, fileState: fileState) }
        case .flag(let name, let value): return (flags[name] ?? "") == value
        case .file(let name, let state): return fileState(name) == state
        case .always: return true
        }
    }
}

struct FomodFile: Sendable {
    var source: String
    /// Relative to Data; nil when the installer gave none (then: the source's path).
    var destination: String?
    var isFolder: Bool
    var priority: Int
    var alwaysInstall: Bool
    var installIfUsable: Bool

    static func parseList(_ element: FomodElement?) -> [FomodFile] {
        guard let element else { return [] }
        return element.children.compactMap { child in
            let kind = child.name.lowercased()
            guard kind == "file" || kind == "folder" else { return nil }
            return FomodFile(source: normalize(child.attribute("source") ?? ""),
                             destination: child.attribute("destination").map(normalize),
                             isFolder: kind == "folder",
                             priority: Int(child.attribute("priority") ?? "") ?? 0,
                             alwaysInstall: (child.attribute("alwaysInstall") ?? "").lowercased() == "true",
                             installIfUsable: (child.attribute("installIfUsable") ?? "").lowercased() == "true")
        }
    }

    static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .filter { $0 != "." && !$0.isEmpty }.joined(separator: "/")
    }
}

struct FomodPlugin: Sendable {
    var name: String
    var description: String
    var image: String?
    var files: [FomodFile]
    var flags: [(name: String, value: String)]
    var fixedType: FomodPluginType
    var typePatterns: [(condition: FomodCondition, type: FomodPluginType)]

    func type(flags: [String: String], fileState: (String) -> FomodFileState) -> FomodPluginType {
        for pattern in typePatterns where pattern.condition.holds(flags: flags, fileState: fileState) { return pattern.type }
        return fixedType
    }
}

struct FomodGroup: Sendable {
    var name: String
    var type: FomodGroupType
    var plugins: [FomodPlugin]
}

struct FomodStep: Sendable {
    var name: String
    var visible: FomodCondition?
    var groups: [FomodGroup]
}

struct FomodConfig: Sendable {
    var moduleName: String
    var moduleImage: String?
    var dependencies: FomodCondition?
    var required: [FomodFile]
    var steps: [FomodStep]
    var conditional: [(condition: FomodCondition, files: [FomodFile])]

    init(xml root: FomodElement) {
        moduleName = root.child("moduleName")?.trimmedText ?? ""
        moduleImage = root.child("moduleImage")?.attribute("path").map(FomodFile.normalize)
        dependencies = root.child("moduleDependencies").map(FomodCondition.parse)
        required = FomodFile.parseList(root.child("requiredInstallFiles"))

        func sorted<T>(_ items: [T], _ order: String?, _ name: (T) -> String) -> [T] {
            switch (order ?? "Ascending").lowercased() {
            case "explicit": return items
            case "descending": return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedDescending }
            default: return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            }
        }

        let stepsElement = root.child("installSteps")
        let parsedSteps: [FomodStep] = (stepsElement?.all("installStep") ?? []).map { step in
            let groupsElement = step.child("optionalFileGroups")
            let groups: [FomodGroup] = (groupsElement?.all("group") ?? []).map { group in
                let pluginsElement = group.child("plugins")
                let plugins: [FomodPlugin] = (pluginsElement?.all("plugin") ?? []).map { plugin in
                    let descriptor = plugin.child("typeDescriptor")
                    var fixed = FomodPluginType(descriptor?.child("type")?.attribute("name"))
                    var patterns: [(FomodCondition, FomodPluginType)] = []
                    if let dependent = descriptor?.child("dependencyType") {
                        fixed = FomodPluginType(dependent.child("defaultType")?.attribute("name"))
                        for pattern in dependent.child("patterns")?.all("pattern") ?? [] {
                            guard let deps = pattern.child("dependencies") else { continue }
                            patterns.append((FomodCondition.parse(deps), FomodPluginType(pattern.child("type")?.attribute("name"))))
                        }
                    }
                    let flags = (plugin.child("conditionFlags")?.all("flag") ?? []).map {
                        (name: $0.attribute("name") ?? "", value: $0.trimmedText)
                    }
                    return FomodPlugin(name: plugin.attribute("name") ?? "",
                                       description: plugin.child("description")?.trimmedText ?? "",
                                       image: plugin.child("image")?.attribute("path").map(FomodFile.normalize),
                                       files: FomodFile.parseList(plugin.child("files")),
                                       flags: flags, fixedType: fixed,
                                       typePatterns: patterns.map { (condition: $0.0, type: $0.1) })
                }
                return FomodGroup(name: group.attribute("name") ?? "", type: FomodGroupType(group.attribute("type")),
                                  plugins: sorted(plugins, pluginsElement?.attribute("order")) { $0.name })
            }
            return FomodStep(name: step.attribute("name") ?? "",
                             visible: step.child("visible").map(FomodCondition.parse),
                             groups: sorted(groups, groupsElement?.attribute("order")) { $0.name })
        }
        steps = sorted(parsedSteps, stepsElement?.attribute("order")) { $0.name }

        conditional = (root.child("conditionalFileInstalls")?.child("patterns")?.all("pattern") ?? []).compactMap { pattern in
            guard let deps = pattern.child("dependencies") else { return nil }
            return (condition: FomodCondition.parse(deps), files: FomodFile.parseList(pattern.child("files")))
        }
    }

    static func load(_ url: URL) throws -> FomodConfig {
        FomodConfig(xml: try FomodXMLReader.parse(try Data(contentsOf: url)))
    }
}

// MARK: - A run through the installer

/// The choices made so far and what follows from them. Steps are indexed in
/// the config's (sorted) order; only visible ones are shown.
struct FomodSession {
    let config: FomodConfig
    /// Whether a file named by a fileDependency is in the game's Data folder,
    /// and if a plugin, enabled.
    let fileState: (String) -> FomodFileState
    /// step -> group -> chosen option indexes.
    var choices: [Int: [Int: Set<Int>]] = [:]

    init(config: FomodConfig, fileState: @escaping (String) -> FomodFileState) {
        self.config = config
        self.fileState = fileState
    }

    /// Flags set by the choices on visible steps before `step` (all steps when nil).
    func flags(before step: Int? = nil) -> [String: String] {
        var flags: [String: String] = [:]
        for (s, item) in config.steps.enumerated() {
            if let step, s >= step { break }
            guard isVisible(s, flags: flags) else { continue }
            for (g, group) in item.groups.enumerated() {
                for p in (choices[s]?[g] ?? []).sorted() where p < group.plugins.count {
                    for flag in group.plugins[p].flags { flags[flag.name] = flag.value }
                }
            }
        }
        return flags
    }

    private func isVisible(_ step: Int, flags: [String: String]) -> Bool {
        config.steps[step].visible?.holds(flags: flags, fileState: fileState) ?? true
    }
    func isVisible(_ step: Int) -> Bool { isVisible(step, flags: flags(before: step)) }

    var visibleSteps: [Int] { config.steps.indices.filter(isVisible) }

    func type(step: Int, group: Int, plugin: Int) -> FomodPluginType {
        config.steps[step].groups[group].plugins[plugin].type(flags: flags(before: step), fileState: fileState)
    }

    /// Fill in a step's groups the way installers expect on arrival: required
    /// and recommended options chosen, a one-of group given its first usable
    /// option, a choose-all group everything. Groups already answered stay.
    mutating func prepare(step: Int) {
        for (g, group) in config.steps[step].groups.enumerated() where choices[step]?[g] == nil {
            var chosen = Set<Int>()
            let types = group.plugins.indices.map { type(step: step, group: g, plugin: $0) }
            switch group.type {
            case .all:
                chosen = Set(group.plugins.indices)
            case .exactlyOne, .atMostOne:
                if let first = types.firstIndex(of: .required) ?? types.firstIndex(of: .recommended) {
                    chosen = [first]
                } else if group.type == .exactlyOne, let first = types.firstIndex(where: { $0 != .notUsable }) {
                    chosen = [first]
                }
            case .atLeastOne, .any:
                chosen = Set(types.indices.filter { types[$0] == .required || types[$0] == .recommended })
                if group.type == .atLeastOne, chosen.isEmpty, let first = types.firstIndex(where: { $0 != .notUsable }) {
                    chosen = [first]
                }
            }
            choices[step, default: [:]][g] = chosen
        }
    }

    /// Choose or unchoose an option, keeping the group's rule.
    mutating func toggle(step: Int, group g: Int, plugin p: Int) {
        let group = config.steps[step].groups[g]
        let kind = type(step: step, group: g, plugin: p)
        var chosen = choices[step]?[g] ?? []
        if kind == .required || kind == .notUsable || group.type == .all { return }
        if group.type.single {
            if chosen.contains(p) {
                if group.type == .atMostOne { chosen = [] }
            } else {
                chosen = [p]
            }
        } else if chosen.contains(p) {
            if !(group.type == .atLeastOne && chosen.count == 1) { chosen.remove(p) }
        } else {
            chosen.insert(p)
        }
        choices[step, default: [:]][g] = chosen
        // Later steps may change with the flags: let them be prepared afresh.
        for later in Array(choices.keys) where later > step { choices[later] = nil }
    }

    /// Why the step can't be left yet, or nil.
    func problem(step: Int) -> String? {
        for (g, group) in config.steps[step].groups.enumerated() {
            let count = choices[step]?[g]?.count ?? 0
            if (group.type == .exactlyOne || group.type == .atLeastOne) && count == 0 {
                return "Choose an option in “\(group.name)”."
            }
        }
        return nil
    }

    /// What to install, lowest priority first.
    func files() -> [FomodFile] {
        let finalFlags = flags()
        var list: [(order: Int, file: FomodFile)] = []
        func add(_ files: [FomodFile]) { for f in files { list.append((list.count, f)) } }
        add(config.required)
        for s in visibleSteps {
            let step = config.steps[s]
            for (g, group) in step.groups.enumerated() {
                let chosen = choices[s]?[g] ?? []
                for (p, plugin) in group.plugins.enumerated() {
                    let usable = type(step: s, group: g, plugin: p) != .notUsable
                    for file in plugin.files where chosen.contains(p) || file.alwaysInstall || (file.installIfUsable && usable) {
                        list.append((list.count, file))
                    }
                }
            }
        }
        for pattern in config.conditional where pattern.condition.holds(flags: finalFlags, fileState: fileState) {
            add(pattern.files)
        }
        return list.sorted { $0.file.priority != $1.file.priority ? $0.file.priority < $1.file.priority : $0.order < $1.order }
            .map(\.file)
    }

    /// The choices as step name -> option names, for the mod's record.
    func summary() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for s in visibleSteps {
            var names: [String] = []
            for (g, group) in config.steps[s].groups.enumerated() {
                for p in (choices[s]?[g] ?? []).sorted() where p < group.plugins.count { names.append(group.plugins[p].name) }
            }
            out[config.steps[s].name] = names
        }
        return out
    }

    /// Copy the chosen files from the unpacked mod (`root` holds the fomod
    /// folder) into the mod's folder, under Data.
    func install(from root: URL, into modFolder: URL) throws {
        let data = modFolder.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let sourceFolder = CaseFolder()
        let targetFolder = CaseFolder()
        var missing: [String] = []
        for file in files() {
            let source = file.source.isEmpty ? root : sourceFolder.resolve(root, file.source)
            guard FileManager.default.fileExists(atPath: source.path) else { missing.append(file.source); continue }
            let destination: String
            if let d = file.destination {
                // A file's destination names the file; an empty one keeps the source's name at Data's top.
                destination = (!file.isFolder && d.isEmpty) ? (file.source as NSString).lastPathComponent : d
            } else {
                destination = file.source
            }
            let target = destination.isEmpty ? data : targetFolder.resolve(data, destination)
            try ModFiles.copyMerging(source, to: target, caseFolder: targetFolder)
        }
        if !missing.isEmpty && missing.count == files().count {
            throw ModError.message("The installer names files the archive doesn't have: \(missing.prefix(3).joined(separator: ", "))")
        }
    }
}
