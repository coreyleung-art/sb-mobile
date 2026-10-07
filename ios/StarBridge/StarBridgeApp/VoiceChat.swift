import Foundation

/// v9.16（2026-10-04 星桥）端到端语音对话：
/// 说一句 → 桥 /api/voice-chat（服务端 60s 长轮询）→ 同一次 HTTP 带回协调者回复 → 调用方 TTS 朗读。
/// 与既有 send() 的区别：不回成稿、不做异步轮询，单请求单响应（电话式一问一答）。
enum VoiceChat {
    static func round(_ text: String, session: String) async -> String? {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/voice-chat") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 75   // 桥侧 60s 长轮询 + 网络余量
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "session": session])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if (obj["ok"] as? Bool) == true, let reply = obj["reply"] as? String, !reply.isEmpty {
                return reply
            }
            if let hint = obj["hint"] as? String { return "（\(hint)）" }
            return nil
        } catch {
            return "（语音连接失败：\(error.localizedDescription)）"
        }
    }
}
