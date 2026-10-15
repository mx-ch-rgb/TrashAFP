import Foundation

enum ShareProtocol: String, CaseIterable, Identifiable {
    case afp = "AFP"
    case smb = "SMB"
    case other = "Autre"
    var id: String { rawValue }
}

enum ShareSource: String, CaseIterable, Identifiable {
    case mount = "Montage actif"
    case bonjour = "Bonjour (réseau)"
    case timeMachine = "Time Machine"
    case finder = "Finder / Favoris"
    case launchd = "launchd"
    case crontab = "crontab"
    case nsmb = "nsmb.conf"
    case file = "Fichier / script"
    var id: String { rawValue }
}

struct Share: Identifiable, Hashable {
    let id = UUID()
    let proto: ShareProtocol
    let source: ShareSource
    let address: String
    let location: String

    var dedupeKey: String { "\(proto.rawValue)|\(source.rawValue)|\(address)|\(location)" }

    static func protocolFor(url: String) -> ShareProtocol {
        let l = url.lowercased()
        if l.hasPrefix("afp") || l.contains("mount_afp") { return .afp }
        if l.hasPrefix("smb") || l.hasPrefix("cifs") || l.contains("mount_smbfs") { return .smb }
        return .other
    }
}
