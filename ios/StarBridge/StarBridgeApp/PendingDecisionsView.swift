import SwiftUI

/// R1 📮 待你决定收件箱：聚合审批/会签/求救/低余额，手机上决定即回
struct PendingDecisionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [[String: Any]] = []
    @State private var loading = true
    @State private var errorMsg: String? = nil

    var body: some View {
        NavigationView {
            Group {
                if loading { ProgressView("加载中…").tint(.gray) }
                else if items.isEmpty {
                    VStack(spacing: 10) {
                        Text("✅ 无待你决定").font(.headline).foregroundColor(.green)
                        Text("审批/会签/求救/低余额都没有积压").font(.caption).foregroundColor(.gray)
                    }
                } else {
                    List {
                        ForEach(0..<items.count, id: \.self) { i in
                            decisionRow(items[i])
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("📮 待你决定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } }
            }
            .onAppear { Task { await load() } }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private func decisionRow(_ d: [String: Any]) -> some View {
        let id = d["id"] as? String ?? "?"
        let title = d["title"] as? String ?? ""
        let kind = d["kind"] as? String ?? "?"
        let detail = d["detail"] as? String ?? ""
        let decisionable = d["decisionable"] as? Bool ?? false
        let icon = kind == "approval" ? "🖋️" : kind == "signoff" ? "✍️" : kind == "balance" ? "💰" : "📌"
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("\(icon) \(title)").font(.subheadline).bold().foregroundColor(.white); Spacer() }
            if !detail.isEmpty { Text(detail).font(.caption).foregroundColor(.gray).lineLimit(3) }
            Text(kind).font(.caption2).foregroundColor(.orange)
            if decisionable {
                HStack(spacing: 12) {
                    Button("✅ 批准") { Task { await decide(id: id, verdict: "approved") } }
                        .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                    Button("❌ 拒绝") { Task { await decide(id: id, verdict: "rejected") } }
                        .buttonStyle(.bordered).tint(.red).controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.white.opacity(0.04))
    }

    private func load() async {
        loading = true
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/pending-decisions") else { loading = false; return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                items = (obj["items"] as? [[String: Any]]) ?? []
            }
        } catch { errorMsg = error.localizedDescription }
        loading = false
    }

    private func decide(id: String, verdict: String) async {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/decision") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "verdict": verdict, "note": "星台决定"])
        _ = try? await URLSession.shared.data(for: req)
        await load()
    }
}
