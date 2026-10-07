import SwiftUI
import UserNotifications

/// R2 ☀️ 晨报：昨夜订单/差评/agent 动态/待办 聚合 + 08:00 本地通知订阅
struct MorningBriefView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var brief: [String: Any] = [:]
    @State private var loading = true
    @State private var notified = false

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView("整理晨报…").tint(.gray)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("\(dateStr()) 早").font(.caption).foregroundColor(.gray)
                            let sections = (brief["sections"] as? [String: Any]) ?? [:]
                            ForEach(Array(sections.keys.sorted()), id: \.self) { k in
                                if let s = sections[k] as? [String: Any] { sectionCard(key: k, s: s) }
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("☀️ 晨报")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } }
            }
            .onAppear { Task { await load(); await scheduleMorning() } }
            .overlay(alignment: .bottom) {
                if notified {
                    Text("✅ 已订阅每日 08:00 晨报通知")
                        .font(.caption2).foregroundColor(.green)
                        .padding(8).background(Color.green.opacity(0.12)).clipShape(Capsule())
                        .padding(.bottom, 20)
                } else if loading == false {
                    Text("通知未授权，晨报仅站内查看")
                        .font(.caption2).foregroundColor(.orange)
                        .padding(8).background(Color.orange.opacity(0.12)).clipShape(Capsule())
                        .padding(.bottom, 20)
                }
            }
        }
        #if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
    }

    private func sectionCard(key: String, s: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sectionTitle(key)).font(.subheadline).bold().foregroundColor(.white)
            if let note = s["note"] as? String, !note.isEmpty {
                Text(note).font(.caption).foregroundColor(.gray)
            }
            if let count = s["count"] as? Int {
                Text("\(count) 项").font(.caption2).foregroundColor(count > 0 ? .orange : .green)
            }
            if let last = s["last_alert"] as? String, !last.isEmpty {
                Text("最近告警: \(last)").font(.caption2).foregroundColor(.gray).lineLimit(1)
            }
            if let alerts = s["alerts_24h"] as? Int {
                Text("今日告警: \(alerts)").font(.caption2).foregroundColor(alerts > 0 ? .orange : .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ k: String) -> String {
        ["pending": "📮 待你决定", "health": "🩺 系统健康", "voice_engine": "🎙️ 语音引擎"].first(where: { $0.key == k })?.value ?? k
    }

    private func dateStr() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M 月 d 日"
        return f.string(from: Date())
    }

    private func load() async {
        loading = true
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/morning-brief") else { loading = false; return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                brief = obj
            }
        } catch { }
        loading = false
    }

    private func scheduleMorning() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { notified = false; return }
        // 每日 08:00 本地通知
        let content = UNMutableNotificationContent()
        content.title = "☀️ 星台晨报"
        content.body = "昨夜经营/系统动态已备好，点开查看"
        content.sound = .default
        var comps = DateComponents(); comps.hour = 8; comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: "sb.morning-brief", content: content, trigger: trigger))
        notified = true
    }
}
