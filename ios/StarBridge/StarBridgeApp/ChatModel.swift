import Foundation
import Combine

struct DeviceTarget: Identifiable, Equatable {
    var id: String { node }       // 'mac-mini' / 'mbp' / 'i9'
    let node: String
    var role: String              // 显示名：星桥(本机) / MBP总线 / i9协调
    var online: Bool
    var current: Bool
}

/// v9.8.2：设备内的对话对象（主角色）——/api/devices 每设备返回 agents（主角色白名单）
struct DeviceAgent: Identifiable, Equatable {
    let id: String                // 稳定会话 key（如 session-abc）
    let sessionId: String         // 真实会话 id（消息走它路由/读回复）
    let role: String              // 中文角色名（空则退化为会话 key 显示）
    var online: Bool              // v9.8.2 在线状态（绿=活跃/灰=静默）
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isConnecting = false
    @Published var isRecording = false
    @Published var queueCount: Int = 0
    @Published var targets: [DeviceTarget] = []          // 可切换设备（/api/devices）
    @Published var currentTarget = "mac-mini"            // 当前对话目标（node）
    @Published var devicesLoading = false
    // v9.7：当前设备内的对话对象（会话）
    @Published var currentAgent: String? = nil           // DeviceAgent.id；nil=总线(默认)/协调者
    @Published var agents: [DeviceAgent] = []            // 当前设备的会话清单

    /// 每 target 独立会话历史（重装后从磁盘恢复）
    private var historyByTarget: [String: [ChatMessage]] = [:]
    /// 每会话已读回复游标（key=session，见 activeSessionKey；防重复读）
    private var lastReplyTsBySession: [String: Int] = [:]

    init() {
        loadHistory()
        currentTarget = UserDefaults.standard.string(forKey: "sb.target") ?? "mac-mini"
        currentAgent = UserDefaults.standard.string(forKey: "sb.agent")   // v9.7 恢复上次对话对象
    }

    // MARK: - 持久化（Documents/chat-history.json：{target: [ChatMessage]}）

    private var historyURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("chat-history.json")
    }()

    /// v9.9.1 历史键：选中角色 → 该角色独立会话；nil(总线) → 节点会话（切角色不再串历史）
    private var historyKey: String {
        if let aid = currentAgent { return "agent:" + aid }
        return currentTarget
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data) {
            historyByTarget = saved
        }
        messages = historyByTarget[historyKey] ?? []
    }

    func saveHistoryPublic() { saveHistory() }
    private func saveHistory() {
        historyByTarget[historyKey] = messages
        if let data = try? JSONEncoder().encode(historyByTarget) {
            try? data.write(to: historyURL)
        }
    }

    // MARK: - 设备切换（v9.3）

    var currentRoleName: String {
        targets.first(where: { $0.node == currentTarget })?.role
            ?? (currentTarget == "mac-mini" ? "星桥(本机)" : currentTarget.uppercased())
    }

    func switchTarget(to node: String) async {
        guard node != currentTarget else { return }
        saveHistory()                                   // 存旧 target 会话
        currentTarget = node
        UserDefaults.standard.set(node, forKey: "sb.target")
        // v9.7：切设备重置对话对象（agent 是设备内的会话，随设备走）
        currentAgent = nil
        agents = []
        UserDefaults.standard.removeObject(forKey: "sb.agent")
        messages = historyByTarget[node] ?? []
        lastReplyTsBySession[activeSessionKey] = Int(Date().timeIntervalSince1970 * 1000)  // 新会话只读新回复
        restartPolling()
        await fetchDevices()
        _ = await pollReplyOnce()                        // 立即试读一次新 target 回复
    }

    func fetchDevices() async {
        devicesLoading = true
        defer { devicesLoading = false }
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/devices") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["devices"] as? [[String: Any]] {
                var seen = Set<String>()
                var ts: [DeviceTarget] = []
                var currentAgentsRaw: [[String: Any]]? = nil
                for d in list {
                    guard let node = d["node"] as? String, !seen.contains(node) else { continue }
                    seen.insert(node)
                    ts.append(DeviceTarget(
                        node: node,
                        role: (d["role"] as? String) ?? node.uppercased(),
                        online: (d["online"] as? Bool) ?? false,
                        current: node == currentTarget))
                    if node == currentTarget {
                        currentAgentsRaw = d["agents"] as? [[String: Any]]
                    }
                }
                if !ts.isEmpty {
                    targets = ts
                    // v9.7：同步解析当前设备的会话清单（供抽屉选择对话对象）
                    if let raw = currentAgentsRaw {
                        agents = Self.parseAgents(raw)
                    }
                }
            }
        } catch { print("[ChatModel] fetchDevices error: ", error) }
    }

    /// 解析 /api/devices 的 agents 数组 → [DeviceAgent]（id 缺失的行丢弃）
    private static func parseAgents(_ raw: [[String: Any]]) -> [DeviceAgent] {
        raw.compactMap { a in
            guard let id = a["id"] as? String, !id.isEmpty else { return nil }
            return DeviceAgent(id: id,
                               sessionId: (a["sessionId"] as? String) ?? id,
                               role: (a["role"] as? String) ?? "",
                               online: (a["online"] as? Bool) ?? false)
        }
    }

    // MARK: - 对话对象（v9.7：设备内 agent 会话）

    /// 当前选中的对话对象信息（nil=总线默认/协调者）
    var currentAgentInfo: DeviceAgent? {
        guard let id = currentAgent else { return nil }
        return agents.first { $0.id == id }
    }

    /// 当前活跃消息 session：选中 agent → 其真实 sessionId；mac-mini 默认 main；跨设备=目标节点
    /// （发送写 inbox 与轮询读 /api/reply 都走同一 key，回复才能闭环）
    private var activeSessionKey: String {
        if let sid = currentAgentInfo?.sessionId { return sid }
        return currentTarget == "mac-mini" ? "main" : currentTarget
    }

    /// 选择对话对象（nil=总线默认）并持久化；随后立即试读一次该会话的回复通道
    func selectAgent(_ id: String?) {
        saveHistory()                                   // v9.9.1: 存当前(旧角色/总线)会话
        currentAgent = id
        if let id {
            UserDefaults.standard.set(id, forKey: "sb.agent")
        } else {
            UserDefaults.standard.removeObject(forKey: "sb.agent")
        }
        // v9.9.1: 切角色 → 加载该角色独立历史（无则空会话），不再停留上一个会话
        messages = historyByTarget[historyKey] ?? []
        lastReplyTsBySession[activeSessionKey] = Int(Date().timeIntervalSince1970 * 1000)
        restartPolling()
        Task { _ = await pollReplyOnce() }
    }

    // MARK: - 发送 / 轮询

    /// 语音识别文字智能纠错（后端 LLM；返回纠错后文本，供填入输入框仍可编辑）
    func correct(_ text: String) async -> String {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/correct") else { return text }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(["text": text])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let corrected = obj["corrected"] as? String,
               !corrected.isEmpty {
                return corrected
            }
        } catch { print("[ChatModel] correct error: ", error) }
        return text  // 失败保底：原识别文本
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(text: trimmed, isMe: true, ts: Date()))
        saveHistory()
        Task { await postChat(trimmed) }
    }

    /// v9.6：发送图片（App 端已压缩好 → base64 → /api/upload → 黑板卡带 image → 星桥视觉读图）
    func sendImage(jpegData: Data, caption: String = "") async {
        let b64 = jpegData.base64EncodedString()
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/upload") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["text": caption, "session": activeSessionKey,
                                   "image": ["mime": "image/jpeg", "b64": b64]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ts = obj["ts"] as? Int {
                // 消息已入队，等待星桥回复（图片预览消息已由调用方加入）
                restartPolling()
            }
        } catch { appendLocal("⚠️ 图片发送失败：\(error.localizedDescription)"); print("[ChatModel] sendImage error: ", error) }
    }

    private func postChat(_ text: String) async {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/chat") else { return }
        var body: [String: String] = ["text": text, "session": activeSessionKey]
        // mac-mini(星桥本机) 走原 inbox 通道；其它设备 target 路由
        if currentTarget != "mac-mini" {
            body["target"] = currentTarget
        } else if let aid = currentAgent {
            // v9.9 角色直聊: 选中非星桥 mac 角色 → target=角色名(server bus-envelope 直达其会话)
            // 星桥(协调者, fa1f9150)仍走 inbox(本会话即星桥)
            if !aid.hasPrefix("session-fa1f9150"), let info = currentAgentInfo {
                let role = (info.role.split(separator: "·").first.map(String.init) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if !role.isEmpty { body["target"] = role }
                else { body["agent"] = aid }
            } else {
                body["agent"] = aid
            }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(body)
        do {
            _ = try await URLSession.shared.data(for: req)
            restartPolling()
        } catch { appendLocal("⚠️ 发送失败：\(error.localizedDescription)"); print("[ChatModel] postChat error: ", error) }
    }

    private var pollTask: Task<Void, Never>?
    private var lastDevicesFetch: Date = .distantPast

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                _ = await self.pollReplyOnce()
                if Int.random(in: 0...2) == 0 { await self.pollQueue() }
                if Date().timeIntervalSince(self.lastDevicesFetch) > 20 {
                    self.lastDevicesFetch = Date()
                    await self.fetchDevices()
                }
                try? await Task.sleep(nanoseconds: UInt64(BridgeConfig.pollInterval * 1_000_000_000))
            }
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil
        startPolling()
    }

    private func pollQueue() async {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/queue") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let q = obj["queued"] as? Int {
            queueCount = q
        }
    }

    private func pollReplyOnce() async -> Bool {
        // 读当前活跃会话的回复（与发送同一 key：agent sessionId / main / 跨设备 target）
        let session = activeSessionKey
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/reply?session=\(session)") else { return false }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let replies = obj["replies"] as? [[String: Any]],
               let r = replies.last,
               let ts = r["ts"] as? Int,
               let reply = r["reply"] as? [String: Any],
               ts > (lastReplyTsBySession[session] ?? 0) {
                lastReplyTsBySession[session] = ts
                let text = (reply["text"] as? String) ?? ""
                let img = (reply["image"] as? String) ?? (reply["imageUrl"] as? String)
                messages.append(ChatMessage(text: text, isMe: false, ts: Date(), imageUrl: img))
                saveHistory()
                return true
            }
        } catch {}
        return false
    }

    private func appendLocal(_ text: String) {
        messages.append(ChatMessage(text: text, isMe: false, ts: Date()))
        saveHistory()
    }
}
