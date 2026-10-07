import SwiftUI
#if os(iOS)
import SafariServices
#endif

/// v9.9 DeepSeek 账户页：余额查询 + 快速充值（SFSafariViewController 内嵌，不退出星台不杀会话）
/// 余额经服务端 /api/deepseek/balance（key 只留服务端）；key 未配置时优雅降级显示引导。
struct DeepSeekAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var showSafari = false
    @State private var lastFetch: Date = .distantPast

    enum LoadState {
        case loading
        case ok(total: Double, granted: Double, toppedUp: Double, currency: String)
        case notConfigured(String)
        case failed(String)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 余额主卡
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.32), Color(red: 0.09, green: 0.11, blue: 0.17)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    VStack(spacing: 8) {
                        Text("DeepSeek 余额").font(.caption).foregroundColor(.gray)
                        switch state {
                        case .loading:
                            ProgressView().tint(.white).padding(.top, 6)
                            Text("查询中…").font(.caption2).foregroundColor(.gray)
                        case .ok(let total, _, _, let cur):
                            Text(String(format: "¥%.2f", total)).font(.system(size: 40, weight: .bold)).foregroundColor(.white)
                            Text(cur.uppercased()).font(.caption2).foregroundColor(.gray)
                        case .notConfigured:
                            Text("未配置 API Key").font(.title2).bold().foregroundColor(.orange)
                            Text("服务端设 DEEPSEEK_API_KEY 后可用").font(.caption2).foregroundColor(.gray)
                        case .failed(let e):
                            Text("查询失败").font(.title2).bold().foregroundColor(.red)
                            Text(e).font(.caption2).foregroundColor(.gray).lineLimit(3).padding(.horizontal)
                        }
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 150).padding(.horizontal, 20).padding(.top, 16)

                // 到账构成
                if case .ok(let total, let granted, let toppedUp, _) = state {
                    VStack(spacing: 12) {
                        HStack { Text("到账构成").font(.caption).foregroundColor(.gray); Spacer() }
                        row("💰 总额", String(format: "¥%.2f", total))
                        row("🎁 赠送", String(format: "¥%.2f", granted))
                        row("💳 充值", String(format: "¥%.2f", toppedUp))
                    }
                    .padding(16).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20).padding(.top, 14)
                }

                Spacer()

                // 快速充值（SFSafariViewController：不退出星台，返回即继续）
                Button {
                    showSafari = true
                } label: {
                    Text("⚡ 快速充值")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.bottom, 10)
                #if os(iOS)
                .sheet(isPresented: $showSafari) {
                    SafariSheet(url: URL(string: "https://platform.deepseek.com")!)
                }
                #else
                // macOS 无 SFSafariViewController：用系统浏览器打开
                .onTapGesture { NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com")!) }
                #endif
                .onAppear { Task { await loadBalance(force: true) } }
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("DeepSeek 账户")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await loadBalance(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loadingLocked())
                }
            }
        }
        #if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.subheadline).foregroundColor(.white.opacity(0.9)); Spacer(); Text(v).font(.subheadline).monospacedDigit().foregroundColor(.white) }
    }

    private func loadingLocked() -> Bool {
        if case .loading = state { return true }
        return Date().timeIntervalSince(lastFetch) < 15
    }

    private func loadBalance(force: Bool) async {
        guard force || Date().timeIntervalSince(lastFetch) > 15 else { return }
        lastFetch = Date()
        state = .loading
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/deepseek/balance") else { state = .failed("URL 错误"); return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ok = obj["ok"] as? Bool, ok,
                   let total = (obj["total_balance"] as? NSNumber)?.doubleValue {
                    state = .ok(total: total,
                                granted: (obj["granted_balance"] as? NSNumber)?.doubleValue ?? 0,
                                toppedUp: (obj["topped_up_balance"] as? NSNumber)?.doubleValue ?? 0,
                                currency: (obj["currency"] as? String) ?? "CNY")
                } else if let err = obj["error"] as? String, err == "key-not-configured" {
                    state = .notConfigured("服务端未配置 DeepSeek key")
                } else {
                    state = .failed((obj["error"] as? String) ?? "未知错误")
                }
            } else {
                state = .failed("响应解析失败")
            }
        } catch {
            state = .failed("网络错误：\(error.localizedDescription)")
        }
    }
}

#if os(iOS)
/// SFSafariViewController 包装（充值跳转不退出星台）
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif
