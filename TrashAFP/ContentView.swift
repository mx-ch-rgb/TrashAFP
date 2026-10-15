import SwiftUI
import AppKit

struct ContentView: View {
    @State private var shares: [Share] = []
    @State private var scanning = false
    @State private var status = "Prêt."
    @State private var extended = true
    @State private var search = ""
    @State private var protoFilter: ShareProtocol? = nil
    @State private var purgeActions: [PurgeAction] = []
    @State private var showPurge = false
    @State private var sortOrder = [KeyPathComparator(\Share.addressSort)]

    private var filtered: [Share] {
        shares.filter { s in
            (protoFilter == nil || s.proto == protoFilter)
            && (search.isEmpty
                || s.address.localizedCaseInsensitiveContains(search)
                || s.location.localizedCaseInsensitiveContains(search))
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(filtered, sortOrder: $sortOrder) {
                TableColumn("Protocole", value: \.protoSort) { Text($0.proto.rawValue).bold() }
                    .width(80)
                TableColumn("Source", value: \.sourceSort) { Text($0.source.rawValue) }
                    .width(min: 110, ideal: 140)
                TableColumn("Adresse / URL", value: \.addressSort) {
                    Text($0.address).textSelection(.enabled)
                }
                TableColumn("Emplacement", value: \.location) {
                    Text($0.location).foregroundStyle(.secondary).textSelection(.enabled)
                        .truncationMode(.middle)
                }
            }
            Divider()
            HStack {
                if scanning { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(filtered.count) résultat(s) — AFP : \(count(.afp)) · SMB : \(count(.smb))")
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .searchable(text: $search, prompt: "Filtrer")
        .toolbar {
            ToolbarItemGroup {
                Picker("Protocole", selection: $protoFilter) {
                    Text("Tous").tag(ShareProtocol?.none)
                    Text("AFP").tag(ShareProtocol?.some(.afp))
                    Text("SMB").tag(ShareProtocol?.some(.smb))
                }
                .pickerStyle(.segmented)
                Toggle("Recherche étendue", isOn: $extended)
                    .help("Inclut Documents, Bureau, Téléchargements et /Library")
                Button { Task { await runScan() } } label: {
                    Label("Analyser", systemImage: "magnifyingglass")
                }
                .disabled(scanning)
                Button { export() } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                .disabled(shares.isEmpty)
                Button {
                    purgeActions = Purger.plan(from: shares)
                    showPurge = true
                } label: { Label("Purger AFP…", systemImage: "trash") }
                .disabled(scanning || !shares.contains { $0.proto == .afp })
            }
        }
        .sheet(isPresented: $showPurge) {
            PurgeView(actions: purgeActions) { Task { await runScan() } }
        }
        .task { await runScan() }
    }

    private func count(_ p: ShareProtocol) -> Int { filtered.filter { $0.proto == p }.count }

    private func runScan() async {
        scanning = true
        let opts = ScanOptions(extended: extended)
        let result = await ShareScanner.scan(options: opts) { msg in
            Task { @MainActor in status = msg }
        }
        shares = result
        scanning = false
        status = "Analyse terminée : \(result.count) entrée(s)."
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "inventaire_afp_smb.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["=== INVENTAIRE AFP / SMB — \(Date().formatted()) ==="]
        for s in filtered {
            lines.append("\(s.proto.rawValue)\t\(s.source.rawValue)\t\(s.address)\t\(s.location)")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension Share {
    var protoSort: String { proto.rawValue }
    var sourceSort: String { source.rawValue }
    var addressSort: String { address }
}
