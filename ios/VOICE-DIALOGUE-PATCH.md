# 星台 App · 端到端语音对话补丁（v9.16）

桥侧已上线（server.js `/api/voice-chat`，已实测：说一句 → 同一次 HTTP 拿回协调者回复）。
App 侧需三处改动（改完 Xcode 构建+签名即可，与 10-10 签名续期可同窗口做）。

## 1. 加入新文件（已写好）
`StarBridge/StarBridgeApp/VoiceChat.swift` —— 放进工程即可（Xcode: File → Add Files）。

## 2. ContentView.swift · 加一个开关状态
在 `@State private var voiceMode = false` 旁加：

```swift
@State private var voiceDialogue = false   // v9.16：语音对话模式（说完直接问星桥并朗读回复）
```

## 3. ContentView.swift · 按住说话 onEnded 分支
把现 onEnded 里 `if !trimmed.isEmpty { appendDraft(trimmed) }` 改为：

```swift
if !trimmed.isEmpty {
    if voiceDialogue {
        // v9.16：语音对话——直接问星桥，回复 TTS 朗读
        messages.append(ChatMessage(text: trimmed, isMe: true, ts: Date()))
        Task {
            if let reply = await VoiceChat.round(trimmed, session: activeSessionKey) {
                messages.append(ChatMessage(text: reply, isMe: false, ts: Date()))
                speech.speak(reply)
            }
        }
    } else {
        appendDraft(trimmed)   // 原行为：追加草稿（成稿模式不变）
    }
}
```

## 4. 开关按钮（可选，放在 voiceMode 切换按钮旁）
```swift
Button(action: { voiceDialogue.toggle() }) {
    Image(systemName: voiceDialogue ? "phone.fill" : "phone")
        .foregroundColor(voiceDialogue ? .green : .gray)
}
.accessibilityLabel(voiceDialogue ? "语音对话中：说完直接问星桥" : "成稿模式：说完攒草稿")
```

## 行为约定（星桥侧）
- 桥写收件箱时带 `type:voice-round` + `round:vr-<ms>`；
- 星桥回复写 `notes/mac-mini/mobile-reply/latest-main` 带 `reply_to:<round>`，桥按轮次匹配返回；
- 60s 未回 → 桥返回 `{ok:false, timeout:true, hint}`，App 朗读提示语。
