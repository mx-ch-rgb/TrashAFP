#if DEBUG
import AppKit

/// Mode démo (builds Debug uniquement) : données fictives et capture d'écran, pour illustrer l'app.
/// Arguments : --demo [--demo-purge] [--snapshot <fichier.png>]
enum Demo {
    static let args = CommandLine.arguments
    static var isOn: Bool { args.contains("--demo") }
    static var purge: Bool { args.contains("--demo-purge") }
    static var snapshotPath: String? {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var shares: [Share] {
        let h = NSHomeDirectory()
        return [
            Share(proto: .afp, source: .mount, address: "afp_0TQ5A7N1B2", location: "/Volumes/Archives"),
            Share(proto: .smb, source: .mount, address: "smb://marc@nas-bureau.local/Photos", location: "/Volumes/Photos"),
            Share(proto: .smb, source: .mount, address: "smb://marc@nas-bureau.local/Documents", location: "/Volumes/Documents"),
            Share(proto: .afp, source: .launchd, address: "commande mount_afp", location: h + "/Library/LaunchAgents/com.exemple.montage-afp.plist"),
            Share(proto: .afp, source: .launchd, address: "afp://nas-bureau.local/Archives", location: h + "/Library/LaunchAgents/com.exemple.montage-afp.plist"),
            Share(proto: .afp, source: .finder, address: "afp://nas-bureau.local/Archives", location: h + "/Library/Preferences/com.apple.finder.plist"),
            Share(proto: .afp, source: .file, address: "afp://serveur-compta.local/Compta", location: h + "/Documents/scripts/sauvegarde.sh"),
            Share(proto: .afp, source: .timeMachine, address: "afp://timecapsule.local/Backup", location: "tmutil destinationinfo"),
            Share(proto: .smb, source: .finder, address: "smb://nas-bureau.local/Photos", location: h + "/Library/Preferences/com.apple.finder.plist"),
            Share(proto: .smb, source: .bonjour, address: "smb://nas-bureau.local", location: "Bonjour local. — _smb._tcp"),
            Share(proto: .smb, source: .bonjour, address: "smb://mac-mini.local", location: "Bonjour local. — _smb._tcp"),
            Share(proto: .afp, source: .bonjour, address: "afp://nas-bureau.local", location: "Bonjour local. — _afpovertcp._tcp"),
            Share(proto: .smb, source: .nsmb, address: "configuration SMB présente", location: "/etc/nsmb.conf"),
        ]
    }

    @MainActor static func scheduleSnapshot() {
        guard let path = snapshotPath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let win = NSApp.windows.first { $0.isSheet } ?? NSApp.windows.first { $0.isVisible && !$0.isSheet }
            guard let frame = win?.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(1) }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
