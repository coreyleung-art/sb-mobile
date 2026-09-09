import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let isMe: Bool
    let ts: Date
    /// v9.6 图片：本机待上传(本地路径) / 远端已存图(/uploads/xxx.jpg，拼接 baseURL 加载)
    var imageUrl: String?
    init(id: UUID = UUID(), text: String, isMe: Bool, ts: Date = Date(), imageUrl: String? = nil) {
        self.id = id; self.text = text; self.isMe = isMe; self.ts = ts; self.imageUrl = imageUrl
    }
}
