import SwiftUI

struct PurgeView: View {
    let actions: [PurgeAction]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var log: [String] = []
    @State private var backupDir: URL?

    private var applicable: Int { actions.filter { $0.kind != .manual }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(log.isEmpty ? "Purge AFP — simulation" : "Purge AFP — terminée").font(.title2.bold())
            if log.isEmpty {
                Text("Rien n'est modifié tant que vous n'avez pas cliqué sur « Appliquer ». Chaque fichier modifié est d'abord copié dans un dossier de sauvegarde sur le Bureau.")
                    .foregroundStyle(.secondary)
                if actions.isEmpty {
                    ContentUnavailableView("Aucune référence AFP", systemImage: "checkmark.seal")
                } else {
                    List(actions) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.kind.rawValue).bold()
                            Text(a.target).font(.callout).textSelection(.enabled)
                            Text(a.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ScrollView { Text(log.joined(separator: "\n")).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack {
                if let backupDir {
                    Button("Afficher la sauvegarde") { NSWorkspace.shared.activateFileViewerSelecting([backupDir]) }
                }
                Spacer()
                Button(log.isEmpty ? "Annuler" : "Fermer") { dismiss() }
                if log.isEmpty {
                    Button("Appliquer…", role: .destructive) { confirming = true }
                        .disabled(applicable == 0)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
        .confirmationDialog("Appliquer la purge AFP ?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Appliquer (\(applicable) action(s))", role: .destructive) {
                let acts = actions
                Task {
                    let r = await Task.detached { Purger.apply(acts) }.value
                    log = r.log; backupDir = r.backupDir
                    onDone()
                }
            }
        } message: {
            Text("Les fichiers seront sauvegardés avant modification. Les LaunchAgents AFP seront supprimés et les volumes AFP démontés.")
        }
    }
}
