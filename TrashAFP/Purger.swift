import Foundation

/// Une action de purge AFP, calculée à partir des résultats de l'analyse.
struct PurgeAction: Identifiable, Hashable {
    enum Kind: String {
        case launchAgent = "LaunchAgent"
        case neutralize = "Neutraliser afp://"
        case finderRecents = "Serveurs récents Finder"
        case unmount = "Démonter"
        case manual = "Manuel"
    }
    let id = UUID()
    let kind: Kind
    let target: String      // chemin, label ou point de montage
    let note: String
}

enum Purger {
    static let afpURL = try! NSRegularExpression(pattern: #"afp://[^"'\s<>]*"#, options: [.caseInsensitive])
    static let home = NSHomeDirectory()
    #if DEBUG
    nonisolated(unsafe) static var assumeWritable = false   // mode démo uniquement
    #endif
    static func writable(_ path: String) -> Bool {
        #if DEBUG
        if assumeWritable { return true }
        #endif
        return FileManager.default.isWritableFile(atPath: path)
    }

    // MARK: Plan (simulation)

    static func plan(from shares: [Share]) -> [PurgeAction] {
        var out: [PurgeAction] = []
        var seen = Set<String>()
        func add(_ a: PurgeAction) { if seen.insert("\(a.kind.rawValue)|\(a.target)").inserted { out.append(a) } }
        let fm = FileManager.default

        for s in shares where s.proto == .afp {
            switch s.source {
            case .mount:
                add(.init(kind: .unmount, target: s.location, note: "Volume AFP monté (démontage sans forcer)"))
            case .launchd:
                if s.location.hasPrefix(home + "/Library/LaunchAgents/") {
                    add(.init(kind: .launchAgent, target: s.location, note: "Déchargé (bootout) puis supprimé"))
                } else {
                    add(.init(kind: .manual, target: s.location, note: "Item système : à traiter avec sudo launchctl bootout"))
                }
            case .finder:
                if s.location.hasSuffix("com.apple.finder.plist") {
                    add(.init(kind: .finderRecents, target: s.location, note: "Supprime FXRecentServers et relance le Finder"))
                } else {
                    add(.init(kind: .manual, target: s.location, note: "Liste de favoris binaire : supprimez le favori dans le Finder"))
                }
            case .file:
                if writable(s.location) {
                    add(.init(kind: .neutralize, target: s.location, note: "Les URL afp:// deviennent AFP_REMOVED"))
                } else {
                    add(.init(kind: .manual, target: s.location, note: "Non modifiable sans droits administrateur"))
                }
            case .timeMachine:
                add(.init(kind: .manual, target: s.address, note: "Destination Time Machine AFP : migrez vers SMB à la main"))
            case .crontab:
                add(.init(kind: .manual, target: s.location, note: "Éditez la crontab (crontab -e)"))
            case .bonjour, .nsmb:
                break
            }
        }
        return out
    }

    // MARK: Application

    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Applique le plan. Sauvegarde chaque fichier modifié dans le dossier retourné.
    static func apply(_ actions: [PurgeAction]) -> (backupDir: URL, log: [String]) {
        let stamp: String = {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f.string(from: Date())
        }()
        let backup = URL(fileURLWithPath: home + "/Desktop/backup_afp_\(stamp)")
        let fm = FileManager.default
        var log = ["=== PURGE AFP — \(Date().formatted()) ===", "Sauvegardes : \(backup.path)"]
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)

        func save(_ path: String) -> Bool {
            let dest = backup.appendingPathComponent(path)   // arborescence miroir : pas de collision
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(atPath: path, toPath: dest.path)
                return true
            } catch {
                log.append("ÉCHEC sauvegarde \(path) : \(error.localizedDescription) — fichier non modifié")
                return false
            }
        }

        var touchedPrefs = false
        var restartFinder = false
        let uid = getuid()

        for a in actions {
            switch a.kind {
            case .launchAgent:
                guard save(a.target) else { continue }
                if let d = fm.contents(atPath: a.target),
                   let dict = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                   let label = dict["Label"] as? String {
                    let r = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                    log.append("bootout \(label) : code \(r.status)")
                }
                do { try fm.removeItem(atPath: a.target); log.append("SUPPRIMÉ : \(a.target)") }
                catch { log.append("ÉCHEC suppression \(a.target) : \(error.localizedDescription)") }

            case .neutralize:
                guard save(a.target) else { continue }
                log.append(neutralize(path: a.target))
                if a.target.hasPrefix(home + "/Library/Preferences/") { touchedPrefs = true }

            case .finderRecents:
                guard save(a.target) else { continue }
                let r = run("/usr/bin/defaults", ["delete", "com.apple.finder", "FXRecentServers"])
                log.append("FXRecentServers supprimé : code \(r.status)")
                restartFinder = true

            case .unmount:
                let r = run("/usr/sbin/diskutil", ["unmount", a.target])
                log.append("Démontage \(a.target) : \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")

            case .manual:
                log.append("À FAIRE À LA MAIN : \(a.target) — \(a.note)")
            }
        }
        if touchedPrefs { _ = run("/usr/bin/killall", ["cfprefsd"]) }
        if restartFinder { _ = run("/usr/bin/killall", ["Finder"]) }
        log.append("=== TERMINÉ ===")
        try? log.joined(separator: "\n").write(to: backup.appendingPathComponent("rapport_purge.txt"),
                                               atomically: true, encoding: .utf8)
        return (backup, log)
    }

    // MARK: Neutralisation

    static func neutralize(path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "ÉCHEC lecture : \(path)" }
        // plist (XML ou binaire) : on remplace dans les chaînes, le format est conservé
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) {
            let cleaned = replaceStrings(in: obj)
            do {
                let d = try PropertyListSerialization.data(fromPropertyList: cleaned, format: format, options: 0)
                try d.write(to: URL(fileURLWithPath: path), options: .atomic)
                return "Neutralisé (plist) : \(path)"
            } catch { return "ÉCHEC écriture \(path) : \(error.localizedDescription)" }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return "IGNORÉ (format binaire non texte) : \(path)"
        }
        let new = replaceAFP(text)
        do { try new.write(toFile: path, atomically: true, encoding: .utf8); return "Neutralisé : \(path)" }
        catch { return "ÉCHEC écriture \(path) : \(error.localizedDescription)" }
    }

    static func replaceAFP(_ s: String) -> String {
        afpURL.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                        withTemplate: "AFP_REMOVED")
    }

    static func replaceStrings(in obj: Any) -> Any {
        switch obj {
        case let s as String: return replaceAFP(s)
        case let a as [Any]: return a.map { replaceStrings(in: $0) }
        case let d as [String: Any]: return d.mapValues { replaceStrings(in: $0) }
        default: return obj
        }
    }
}
