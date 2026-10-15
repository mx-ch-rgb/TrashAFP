import Foundation
import Network
import Darwin

struct ScanOptions {
    var extended = true   // Documents, Bureau, Téléchargements, /Library
}

enum ShareScanner {
    typealias Progress = @Sendable (String) -> Void

    static let urlRegex = try! NSRegularExpression(
        pattern: #"(?:afp|smb|cifs)://[^\s"'<>\\)\]\x00-\x1f]+"#, options: [.caseInsensitive])
    static let cmdRegex = try! NSRegularExpression(
        pattern: #"mount_afp|mount_smbfs"#, options: [])

    static let textExtensions: Set<String> = [
        "plist", "sh", "zsh", "bash", "command", "applescript", "scpt", "workflow", "xml",
        "json", "yaml", "yml", "conf", "cfg", "desktop", "url", "webloc", "inetloc", "fileloc",
        "sfl", "sfl2", "sfl3", "sfl4", "txt", "py", "rb", "plist"
    ]
    static let skipDirs: Set<String> = [
        "Caches", "Logs", "Containers", "Group Containers", "Developer", "Metadata", "Biome",
        "Mail", "Messages", "Photos Library.photoslibrary", "Safari", "node_modules", ".git",
        "CloudStorage", "Mobile Documents", "Trial", "Saved Application State", "WebKit",
        "venv", ".venv", "site-packages", "__pycache__", "DerivedData", "Pods", "build", "target", "vendor",
        "Frameworks", "Updates", "Printers", "Fonts", "Audio", "Apple", "Image Capture", "Extensions"
    ]

    // MARK: Orchestration

    static func scan(options: ScanOptions, progress: @escaping Progress) async -> [Share] {
        var all: [Share] = []
        progress("Montages actifs…")
        all += activeMounts()
        progress("Time Machine…")
        all += timeMachine()
        progress("crontab et nsmb.conf…")
        all += crontab()
        all += nsmbConf()
        progress("LaunchAgents / LaunchDaemons…")
        all += launchd()
        progress("Fichiers de configuration et réseau (Bonjour)…")
        // Le parcours des fichiers et la découverte Bonjour (≈ 3 s d'attente) se font en parallèle.
        async let bonjourFound = bonjour()
        let files = await Task.detached { fileScan(options: options, progress: progress) }.value
        all += files
        all += await bonjourFound

        var seen = Set<String>()
        return all.filter { seen.insert($0.dedupeKey).inserted }
    }

    // MARK: Active mounts (getfsstat)

    static func cString<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func activeMounts() -> [Share] {
        let n = getfsstat(nil, 0, MNT_NOWAIT)
        guard n > 0 else { return [] }
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: Int(n))
        defer { buf.deallocate() }
        memset(buf, 0, Int(n) * MemoryLayout<statfs>.stride)
        let m = getfsstat(buf, Int32(Int(n) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard m > 0 else { return [] }
        var out: [Share] = []
        for i in 0..<Int(m) {
            let type = cString(buf[i].f_fstypename)
            let from = cString(buf[i].f_mntfromname)
            let on = cString(buf[i].f_mntonname)
            switch type {
            case "smbfs":
                out.append(Share(proto: .smb, source: .mount, address: "smb:" + from, location: on))
            case "afpfs":
                out.append(Share(proto: .afp, source: .mount, address: from, location: on))
            default: break
            }
        }
        return out
    }

    // MARK: Helpers

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func matches(in text: String) -> [String] {
        let ns = text as NSString
        return urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    static func hasCommand(_ text: String) -> [String] {
        let ns = text as NSString
        return cmdRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    static func shares(fromText text: String, source: ShareSource, location: String,
                       includeCommands: Bool = false) -> [Share] {
        var out = matches(in: text).map {
            Share(proto: Share.protocolFor(url: $0), source: source, address: $0, location: location)
        }
        if includeCommands {
            out += hasCommand(text).map {
                Share(proto: Share.protocolFor(url: $0), source: source, address: "commande \($0)", location: location)
            }
        }
        return out
    }

    // MARK: Time Machine, cron, nsmb

    static func timeMachine() -> [Share] {
        let out = run("/usr/bin/tmutil", ["destinationinfo"])
        return shares(fromText: out, source: .timeMachine, location: "tmutil destinationinfo")
    }

    static func crontab() -> [Share] {
        shares(fromText: run("/usr/bin/crontab", ["-l"]), source: .crontab,
               location: "crontab utilisateur", includeCommands: true)
    }

    static func nsmbConf() -> [Share] {
        var out: [Share] = []
        for path in ["/etc/nsmb.conf", NSHomeDirectory() + "/Library/Preferences/nsmb.conf"] {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let urls = shares(fromText: s, source: .nsmb, location: path)
            out += urls
            if urls.isEmpty {
                out.append(Share(proto: .smb, source: .nsmb, address: "configuration SMB présente", location: path))
            }
        }
        return out
    }

    // MARK: launchd

    static let launchDirs = [
        NSHomeDirectory() + "/Library/LaunchAgents",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons"
    ]

    static func readText(_ path: String, maxBytes: Int = 8_000_000) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func launchd() -> [Share] {
        var out: [Share] = []
        let fm = FileManager.default
        for dir in launchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in items where name.hasSuffix(".plist") {
                let path = dir + "/" + name
                // plist XML ou binaire : on le convertit en XML pour la recherche
                var text = readText(path) ?? ""
                if let d = fm.contents(atPath: path),
                   let obj = try? PropertyListSerialization.propertyList(from: d, format: nil),
                   let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) {
                    text = String(decoding: xml, as: UTF8.self)
                }
                out += shares(fromText: text, source: .launchd, location: path, includeCommands: true)
            }
        }
        return out
    }

    // MARK: File scan

    static let needles = ["afp://", "smb://", "cifs://", "AFP://", "SMB://", "CIFS://"].map { Data($0.utf8) }
    static let maxFileSize = 4_000_000
    static let SF_DATALESS: UInt32 = 0x4000_0000

    /// Lit un fichier ordinaire sans jamais bloquer (tubes, sockets) ni déclencher
    /// le téléchargement d'un fichier iCloud non local (« dataless »).
    static func readRegularFile(_ path: String) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_flags & SF_DATALESS == 0,
              st.st_size > 0, st.st_size < maxFileSize else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        return data.prefix(n)
    }

    static func scanRoot(_ root: String, progress: Progress) -> [Share] {
        progress("Analyse de \(root)…")
        let fm = FileManager.default
        var out: [Share] = []
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        for case let url as URL in en {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skipDirs.contains(name) || name.hasPrefix(".") || launchDirs.contains(url.path) { en.skipDescendants() }
                continue
            }
            guard textExtensions.contains(url.pathExtension.lowercased()),
                  let data = readRegularFile(url.path),
                  needles.contains(where: { data.range(of: $0) != nil })
            else { continue }
            let latin = String(data: data, encoding: .isoLatin1) ?? ""
            let path = url.path
            let src: ShareSource = (path.contains("/Preferences/com.apple.finder")
                || path.contains("sharedfilelist") || path.contains("com.apple.sidebarlists")
                || path.contains("com.apple.recentitems")) ? .finder : .file
            out += shares(fromText: latin, source: src, location: path)
        }
        return out
    }

    static func fileScan(options: ScanOptions, progress: @escaping Progress) -> [Share] {
        let home = NSHomeDirectory()
        var roots = [home + "/Library"]
        if options.extended {
            roots += [home + "/Documents", home + "/Desktop", home + "/Downloads", "/Library"]
        }
        // Les racines sont indépendantes : on les parcourt en parallèle.
        let lock = NSLock()
        var out: [Share] = []
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let r = scanRoot(roots[i], progress: progress)
            lock.lock(); out += r; lock.unlock()
        }
        return out
    }

    // MARK: Bonjour

    static func bonjour() async -> [Share] {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [Share] = []
            func add(_ s: [Share]) { lock.lock(); items += s; lock.unlock() }
        }
        let box = Box()
        let types: [(String, ShareProtocol)] = [("_smb._tcp", .smb), ("_afpovertcp._tcp", .afp)]
        var browsers: [NWBrowser] = []
        for (type, proto) in types {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { results, _ in
                let found: [Share] = results.compactMap { r in
                    guard case let .service(name, _, domain, _) = r.endpoint else { return nil }
                    let scheme = proto == .smb ? "smb" : "afp"
                    return Share(proto: proto, source: .bonjour,
                                 address: "\(scheme)://\(name).local", location: "Bonjour \(domain) — \(type)")
                }
                box.add(found)
            }
            b.start(queue: .global())
            browsers.append(b)
        }
        try? await Task.sleep(for: .seconds(3))
        browsers.forEach { $0.cancel() }
        return box.items
    }
}
