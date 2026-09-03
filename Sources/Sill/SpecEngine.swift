import Foundation
import JavaScriptCore

/* Completion specs are the withfig/autocomplete corpus: one self-contained
   JS bundle per CLI, converted to IIFE form by Scripts/build-specs.sh so a
   plain JSContext can evaluate them (JSC has no ES-module loader). Each file
   evaluates to an object whose `default` property is the Fig.Spec root.

   The engine never bridges whole spec trees into Swift — the parser walks
   JSValues lazily through SpecNode, touching only the levels it needs. */
protocol SpecProviding {
    func spec(for command: String) -> SpecNode?
}

final class SpecEngine: SpecProviding {
    private let context: JSContext
    private var cache: [String: SpecNode] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 30

    /// Directories searched for `<command>.js`, in order.
    var specDirectories: [URL]
    /// Specs learned from `--help`, consulted when no file matches.
    let derived: DerivedSpecStore?

    init(specDirectories: [URL] = [], derived: DerivedSpecStore? = nil) {
        self.specDirectories = specDirectories
        self.derived = derived
        context = JSContext(virtualMachine: JSVirtualMachine())
        context.exceptionHandler = { _, exception in
            NSLog("Sill: spec JS exception: %@", exception?.toString() ?? "?")
        }
        if derived != nil {
            NotificationCenter.default.addObserver(
                forName: DerivedSpecStore.updated, object: nil, queue: .main
            ) { [weak self] note in
                if let command = note.userInfo?["command"] as? String {
                    self?.invalidate(command)
                } else {
                    self?.cache.removeAll()
                    self?.cacheOrder.removeAll()
                }
            }
        }
    }

    /// Drops a cached spec so the next lookup re-reads it.
    func invalidate(_ command: String) {
        cache.removeValue(forKey: command)
        cacheOrder.removeAll { $0 == command }
    }

    /// The spec for a command name ("git") or a `loadSpec` path ("aws/s3"),
    /// loading and caching on demand.
    func spec(for command: String) -> SpecNode? {
        // Paranoia: command names come from the user's buffer; never let one
        // traverse out of the spec directory.
        guard !command.isEmpty, !command.hasPrefix("/"),
              !command.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") })
        else { return nil }
        if let cached = cache[command] { return cached }
        for directory in specDirectories {
            let url = directory.appendingPathComponent("\(command).js")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let node = evaluate(source) else { return nil }
            cache[command] = node
            cacheOrder.append(command)
            if cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
            return node
        }
        if let json = derived?.specJSON(for: command), let node = evaluateJSON(json) {
            cache[command] = node
            cacheOrder.append(command)
            return node
        }
        return nil
    }

    /// Evaluates a Fig-shaped JSON document (a learned spec) into a node.
    func evaluateJSON(_ json: String) -> SpecNode? {
        guard let spec = context.evaluateScript("(\(json))"), spec.isObject else { return nil }
        return SpecNode(spec)
    }

    /// Evaluates one converted spec file (IIFE assigning `var __sillSpec`)
    /// in a function scope so nothing leaks into the shared global object.
    func evaluate(_ source: String) -> SpecNode? {
        let wrapped = "(function(){ \(source)\n; return __sillSpec; })()"
        guard let module = context.evaluateScript(wrapped), module.isObject,
              let spec = module.objectForKeyedSubscript("default"), spec.isObject
        else { return nil }
        return SpecNode(spec)
    }
}

/// A lazy view over one node of a Fig.Spec object graph (the spec root, a
/// subcommand, an option, or an arg).
struct SpecNode {
    let value: JSValue

    init(_ value: JSValue) { self.value = value }

    init?(optional value: JSValue?) {
        guard let value, value.isObject else { return nil }
        self.value = value
    }

    private func property(_ name: String) -> JSValue? {
        guard let v = value.objectForKeyedSubscript(name), !v.isUndefined, !v.isNull
        else { return nil }
        return v
    }

    /// `name` may be a string or an array of aliases ("-m" / "--message").
    var names: [String] {
        guard let name = property("name") else { return [] }
        if name.isString { return [name.toString()] }
        if name.isArray {
            return (0..<Int(name.toArray()?.count ?? 0)).compactMap {
                let element = name.atIndex($0)
                return element?.isString == true ? element?.toString() : nil
            }
        }
        return []
    }

    var primaryName: String { names.first ?? "" }

    var specDescription: String {
        guard let d = property("description"), d.isString else { return "" }
        return d.toString()
    }

    var isHidden: Bool { property("hidden")?.toBool() ?? false }

    /// A learned subcommand whose own options haven't been read yet
    /// (DerivedSpecStore explores it when the user gets there).
    var needsExploration: Bool { property("_sillUnexplored")?.toBool() ?? false }

    var priority: Int {
        guard let p = property("priority"), p.isNumber else { return 50 }
        return Int(p.toInt32())
    }

    var insertValue: String? {
        guard let v = property("insertValue"), v.isString else { return nil }
        return v.toString()
    }

    /// Big CLIs split subtrees into separate files: `loadSpec: "aws/s3"`.
    /// (The function form is rare and unsupported in v1.)
    var loadSpecName: String? {
        guard let v = property("loadSpec"), v.isString else { return nil }
        return v.toString()
    }

    var subcommands: [SpecNode] { nodeArray("subcommands") }
    var options: [SpecNode] { nodeArray("options") }

    /// `args` may be a single object or an array — normalized to an array.
    var args: [SpecNode] {
        guard let a = property("args") else { return [] }
        if a.isArray { return nodeArray("args") }
        return a.isObject ? [SpecNode(a)] : []
    }

    // Arg-node accessors.
    var isOptional: Bool { property("isOptional")?.toBool() ?? false }
    var isVariadic: Bool { property("isVariadic")?.toBool() ?? false }

    /// `template` may be a string or an array of strings.
    var templates: [String] {
        guard let t = property("template") else { return [] }
        if t.isString { return [t.toString()] }
        if t.isArray {
            return (0..<Int(t.toArray()?.count ?? 0)).compactMap {
                let element = t.atIndex($0)
                return element?.isString == true ? element?.toString() : nil
            }
        }
        return []
    }

    /// Static `suggestions`: strings or {name, description, …} objects.
    var staticSuggestions: [(name: String, description: String, insertValue: String?)] {
        guard let s = property("suggestions"), s.isArray else { return [] }
        var result: [(String, String, String?)] = []
        for i in 0..<Int(s.toArray()?.count ?? 0) {
            guard let element = s.atIndex(i) else { continue }
            if element.isString {
                result.append((element.toString(), "", nil))
            } else if element.isObject {
                let node = SpecNode(element)
                for name in node.names {
                    result.append((name, node.specDescription, node.insertValue))
                }
            }
        }
        return result
    }

    var generators: [JSValue] {
        guard let g = property("generators") else { return [] }
        if g.isArray {
            return (0..<Int(g.toArray()?.count ?? 0)).compactMap { g.atIndex($0) }
        }
        return g.isObject ? [g] : []
    }

    private func nodeArray(_ name: String) -> [SpecNode] {
        guard let array = property(name), array.isArray else { return [] }
        return (0..<Int(array.toArray()?.count ?? 0)).compactMap {
            SpecNode(optional: array.atIndex($0))
        }
    }
}
