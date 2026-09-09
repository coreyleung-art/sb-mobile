import SwiftUI
import AVFoundation
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var model: ChatModel
    @StateObject private var speech = SpeechManager()
    @State private var input = ""
    @State private var isPressing = false
    @State private var voiceMode = false          // v9.5：true=语音输入模式（微信式切换）
    @State private var voicePreview = ""          // 按住期间实时识别预览（不覆盖草稿）
    @FocusState private var inputFocused: Bool
    @State private var pickerItem: PhotosPickerItem? = nil   // v9.6 相册选图
    @State private var sendingImage = false
    @State private var showDrawer = false                    // v9.7 会话抽屉（左滑/按钮开关）
    @State private var nameFixPrompt: (alias: String, target: String)? = nil  // v9.7.1 疑似智能体名候选
    @State private var showAccount = false                   // v9.9 DeepSeek 账户页

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
            // 标题栏：设备切换 + 状态
            HStack {
                #if os(macOS)
                // v9.7：macOS 无触屏左滑 → 用标题栏按钮开关同一会话抽屉
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showDrawer.toggle() }
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("会话清单（选择对话对象）")
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text("⭐ 星台").font(.headline).foregroundColor(.white)
                    // 当前对话目标（v9.3 多设备）
                    Menu {
                        ForEach(model.targets.isEmpty ? fallbackTargets : model.targets) { t in
                            Button {
                                Task { await model.switchTarget(to: t.node) }
                            } label: {
                                if t.node == model.currentTarget {
                                    Label("\(t.role) · 当前", systemImage: "checkmark")
                                } else {
                                    Text(t.role)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(model.currentTarget == "mac-mini" ? Color.green : Color.blue)
                                .frame(width: 6, height: 6)
                            Text(model.currentRoleName).font(.caption2).foregroundColor(.gray)
                            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundColor(.gray)
                        }
                    }
                    // v9.8.2：当前对话对象（选中 agent 时显示 role 主名；nil=总线默认不显示）
                    if let ag = model.currentAgentInfo {
                        Text("🎯 \(roleDisplayName(ag.role))")
                            .font(.caption2).foregroundColor(.orange).lineLimit(1)
                    }
                }
                Spacer()
                // v9.9 DeepSeek 账户入口（余额 + 充值）
                Button {
                    showAccount = true
                } label: {
                    Image(systemName: "wallet.bifold")
                        .font(.system(size: 15)).foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08)).clipShape(Circle())
                }
                .buttonStyle(.plain)
                if model.queueCount > 0 && model.currentTarget == "mac-mini" {
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass").font(.system(size: 10))
                        Text("\(model.queueCount) 条排队").font(.caption)
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.2)).cornerRadius(10)
                }
                Circle().fill(model.isConnecting ? .red : .green).frame(width: 8, height: 8)
            }
            .padding(.horizontal).padding(.vertical, 12)
            .background(Color(red: 0.1, green: 0.12, blue: 0.18))

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.messages) { msg in
                            MessageBubble(msg: msg)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { inputFocused = false }  // 点消息区收起键盘
                    .scrollDismissesKeyboard(.interactively)
                }
                .onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // 输入区（v9.5 微信式：点麦克风切换 文本⇄语音 模式；语音识别追加不覆盖）
            VStack(spacing: 8) {
                // 语音模式：实时识别预览行（仅语音模式显示）
                if voiceMode && isPressing && !voicePreview.isEmpty {
                    HStack {
                        Text(voicePreview).font(.body).foregroundColor(.gray)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.15)).cornerRadius(10)
                    .transition(.opacity)
                }
                HStack(spacing: 10) {
#if os(iOS)
                    // 相册（v9.6）
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Image(systemName: sendingImage ? "arrow.triangle.2.circlepath" : "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundColor(sendingImage ? .orange : .gray)
                            .frame(width: 36, height: 36)
                    }
                    .disabled(sendingImage)
                    .onChange(of: pickerItem) { _ in
                        guard let item = pickerItem else { return }
                        Task {
                            sendingImage = true
                            defer { sendingImage = false; pickerItem = nil }
                            if let data = try? await item.loadTransferable(type: Data.self) {
                                // 压缩到 ~1280px 内、JPEG 0.7，限制 5MB
                                let img = UIImage(data: data)
                                let maxSide: CGFloat = 1280
                                var jpeg: Data?
                                if let img {
                                    let scale = min(1, maxSide / max(img.size.width, img.size.height))
                                    let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                                    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                                    img.draw(in: CGRect(origin: .zero, size: newSize))
                                    jpeg = UIGraphicsGetImageFromCurrentImageContext()?.jpegData(compressionQuality: 0.7)
                                    UIGraphicsEndImageContext()
                                }
                                let payload = jpeg ?? data
                                guard payload.count <= 5 * 1024 * 1024 else {
                                    model.messages.append(ChatMessage(text: "⚠️ 图片过大（>5MB）", isMe: true, ts: Date())); model.saveHistoryPublic()
                                    return
                                }
                                // v9.6.1：先落本地文件 → 气泡显示真实图（用户能看到自己发的）
                                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                    .appendingPathComponent("sent-imgs", isDirectory: true)
                                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                                let localFile = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
                                try? payload.write(to: localFile)
                                model.messages.append(ChatMessage(text: "", isMe: true, ts: Date(), imageUrl: localFile.path))
                                model.saveHistoryPublic()
                                await model.sendImage(jpegData: payload)
                            }
                        }
                    }
                    // 模式切换钮：点麦克风进语音模式 / 点键盘回文本模式（微信式）
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            voiceMode.toggle()
                            if voiceMode {
                                inputFocused = false      // 语音模式收起键盘
                                speech.requestPermission()
                            }
                        }
                    } label: {
                        Image(systemName: voiceMode ? "keyboard" : "mic.fill")
                            .font(.system(size: 20))
                            .foregroundColor(voiceMode ? .blue : .gray)
                            .frame(width: 36, height: 36)
                            .background(voiceMode ? Color.blue.opacity(0.15) : Color.clear)
                            .cornerRadius(8)
                    }
                    .accessibilityLabel(voiceMode ? "切换到文本输入" : "切换到语音输入")

                    if voiceMode {
                        // 语音输入模式：整条按住说话（微信式）
                        Text(isPressing ? "松开结束这句…" : "按住 说话")
                            .font(.headline)
                            .foregroundColor(isPressing ? .white : .gray)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(isPressing ? Color.red.opacity(0.8) : Color.chatSystemGray5)
                            .cornerRadius(12)
                            .overlay(
                                Group {
                                    if isPressing {
                                        Text("\(voicePreview.isEmpty ? "正在听…" : voicePreview)").font(.caption).foregroundColor(.white.opacity(0.9))
                                            .lineLimit(1).padding(.horizontal, 12)
                                    }
                                }, alignment: .bottom
                            )
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if !isPressing {
                                            isPressing = true
                                            speech.requestPermission()
                                            speech.onPartial = { text in voicePreview = text }  // 只写预览，不覆盖草稿
                                            speech.startListening()
                                        }
                                    }
                                    .onEnded { _ in
                                        isPressing = false
                                        let recognized = speech.partialText.isEmpty ? voicePreview : speech.partialText
                                        speech.stopListening(finish: false)
                                        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                                        speech.partialText = ""
                                        voicePreview = ""
                                        if !trimmed.isEmpty {
                                            appendDraft(trimmed)   // 追加到草稿（不覆盖已有文字）
                                        }
                                    }
                            )
                            .accessibilityLabel("按住说话，松开追加文字")
                    } else {
                        TextField("点麦克风语音输入，或直接打字…", text: $input)
                            .textFieldStyle(.roundedBorder)
                            .focused($inputFocused)
                            .onSubmit { sendText() }
                    }
#endif
                    if !input.isEmpty || !voicePreview.isEmpty {
                        Button(action: { sendText() }) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                        }
                    }
                }
            }
            .padding()
            .background(Color.chatSystemBackground)
            }

            // v9.7 会话抽屉叠加层（放在 VStack 之后 → 盖在主内容上；macOS 同样可用）
            if showDrawer {
                // 半透明遮罩：点任意处关闭
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                agentDrawer
                    .transition(.move(edge: .leading))
            }
        }
        .simultaneousGesture(edgeDrag)   // iOS 左缘右滑开抽屉；macOS=永不触发的占位（用标题栏按钮）
        .onAppear {
            model.isConnecting = false
            speech.requestPermission()
            model.startPolling()
            Task { await model.fetchDevices() }   // 拉设备列表（v9.3）
        }
        .onChange(of: model.messages.count) { _ in
            if let last = model.messages.last, !last.isMe {
                speech.speak(last.text)
            }
        }
        .onChange(of: model.currentTarget) { _ in
            closeDrawer()                         // 切设备同时收起抽屉（agent 已在模型层重置为 nil）
        }
        .alert("检测到疑似智能体名「\(nameFixPrompt?.alias ?? "")」",
               isPresented: Binding(get: { nameFixPrompt != nil }, set: { if !$0 { nameFixPrompt = nil } }),
               presenting: nameFixPrompt) { fix in
            Button("改成「\(fix.target)」") { applyNameFix(fix.target) }
            Button("保留原样", role: .cancel) { nameFixPrompt = nil }
        } message: { fix in
            Text("是语音识别把「\(fix.target)」听成了「\(fix.alias)」吗？点替换，或保留原样后手动改。")
        }
        // v9.9 DeepSeek 账户页（余额 + 充值跳转）
        .sheet(isPresented: $showAccount) {
            DeepSeekAccountView()
        }
    }

    // MARK: - v9.7 会话抽屉（左缘右滑 / macOS 按钮 / 遮罩点关）

    private func openDrawer()  { withAnimation(.easeOut(duration: 0.25)) { showDrawer = true } }
    private func closeDrawer() { withAnimation(.easeOut(duration: 0.20)) { showDrawer = false } }

    /// iOS：起始于左缘(<26pt) 且横向位移为主的右滑 → 开抽屉（macOS 分支=永不触发的占位）
    /// 用 simultaneousGesture 挂整层：不抢占 ScrollView/按住说话的子手势，
    /// 纵向滚动 translation 以高度为主 → 门控不触发；仅横向右滑才开抽屉
    private var edgeDrag: some Gesture {
        #if os(iOS)
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onEnded { value in
                guard !showDrawer else { return }
                let t = value.translation
                if value.startLocation.x < 26, t.width > 70, abs(t.width) > abs(t.height) * 1.5 {
                    openDrawer()
                }
            }
        #else
        DragGesture(minimumDistance: .infinity)
        #endif
    }

    private var drawerWidth: CGFloat {
        #if os(iOS)
        min(330, UIScreen.main.bounds.width * 0.85)
        #else
        320
        #endif
    }

    /// 抽屉主体：顶部「总线(默认)」+ 当前设备主角色清单（v9.8.2 角色管理）
    private var agentDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：标题 + 会话数 + 关闭
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("🎯 角色管理").font(.headline).foregroundColor(.white)
                    Text("\(model.currentRoleName) · \(model.agents.count) 个主角色")
                        .font(.caption2).foregroundColor(.gray)
                }
                Spacer()
                Button { closeDrawer() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundColor(.gray)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08)).clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Divider().overlay(Color.white.opacity(0.1))

            // 顶部「总线（默认）」：nil = 直达设备总线/协调者
            drawerRow(title: "总线（默认）",
                      subtitle: "消息直达 \(model.currentRoleName)",
                      selected: model.currentAgent == nil) {
                model.selectAgent(nil)
                closeDrawer()
            }

            Divider().overlay(Color.white.opacity(0.1))

            // 当前设备主角色清单（v9.8.2：中文角色名 + 状态圆点）
            if model.agents.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().tint(.gray)
                    Text("角色清单加载中…").font(.caption).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity).padding(.top, 48)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.agents) { ag in
                            drawerRow(title: roleDisplayName(ag.role),
                                      subtitle: roleDisplayDesc(ag.role),
                                      statusOn: ag.online,
                                      selected: model.currentAgent == ag.id) {
                                model.selectAgent(ag.id)
                                closeDrawer()
                            }
                            Divider().overlay(Color.white.opacity(0.05)).padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(width: drawerWidth)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.10, green: 0.12, blue: 0.18))   // 与标题栏同色
        .shadow(color: .black.opacity(0.5), radius: 10, x: 4, y: 0)
    }

    /// v9.8.2：role 形如「星桥 · 总线协调者」→ 拆「·」前为主名
    private func roleDisplayName(_ role: String) -> String {
        let seg = role.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
        return seg.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? role
    }

    /// v9.8.2：取「·」后的描述段
    private func roleDisplayDesc(_ role: String) -> String? {
        let seg = role.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
        return seg.count > 1 ? String(seg[1]).trimmingCharacters(in: .whitespaces) : nil
    }

    /// 抽屉行：标题 + 状态圆点 + 副标题 + 选中 ✓
    private func drawerRow(title: String, subtitle: String? = nil, statusOn: Bool? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // v9.8.2 状态圆点：nil=不显示（总线行）；绿=在线 灰=静默
                if let on = statusOn {
                    Circle().fill(on ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundColor(.white).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundColor(.gray).lineLimit(1)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(selected ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fallbackTargets: [DeviceTarget] {
        [DeviceTarget(node: "mac-mini", role: "星桥(本机)", online: true, current: true)]
    }

    private func sendText() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.send(text: t)
        input = ""
    }

    /// v9.7.1：智能体常见语音误识别名表（识别不准时弹候选替换）
    private static let agentAliases: [(alias: String, target: String)] = [
        ("新桥", "星桥"), ("心桥", "星桥"), ("星瞧", "星桥"), ("星翘", "星桥"),
        ("老灯", "老登"), ("烙灯", "老登"), ("捞登", "老登"), ("老等", "老登"),
        ("驿史", "驿使"), ("义史", "驿使"), ("益使", "驿使"), ("一史", "驿使"),
        ("明见", "明鉴"), ("鸣剑", "明鉴"), ("明剑", "明鉴"),
        ("守灯台", "守灯塔"), ("守灯", "守灯塔"), ("司库", "司库"), ("思库", "司库"),
        ("拾光", "拾光"), ("十光", "拾光"), ("知了", "知了"), ("智了", "知了"),
        ("文汇", "文汇"), ("闻汇", "文汇"), ("守链", "守链"), ("手链", "守链"),
        ("验金石", "验金石"), ("言金石", "验金石"), ("守望", "守望"), ("四望", "守望"),
        ("灯塔", "守灯塔"), ("老等", "老登"),
    ]

    /// 语音松开/纠错后扫描草稿，发现疑似误识智能体名 → 弹候选
    private func checkAgentNameAliases(in text: String) {
        guard nameFixPrompt == nil else { return }
        for item in Self.agentAliases {
            if text.contains(item.alias) {
                nameFixPrompt = (item.alias, item.target)
                return
            }
        }
    }

    /// 用户确认替换：把草稿中最后一次出现的别名换成正确名
    private func applyNameFix(_ target: String) {
        guard let fix = nameFixPrompt else { return }
        if let range = input.range(of: fix.alias, options: .backwards) {
            input.replaceSubrange(range, with: target)
        }
        nameFixPrompt = nil
    }

    /// v9.5：语音识别句追加到草稿（不覆盖已有文字），自动 LLM 纠错仅作用于新句
    private func appendDraft(_ segment: String) {
        // 句间连接：已有草稿非空且不以标点结尾 → 补逗号
        var joined = segment
        if !input.isEmpty {
            let last = String(input.suffix(1))
            let puncts = ["，", "。", "！", "？", "；", ",", ".", "!", "?", "\n"]
            if !puncts.contains(last) { joined = "，" + segment }
        }
        let base = input + joined
        input = base
        checkAgentNameAliases(in: segment)      // v9.7.1：先弹智能体名候选（若有）
        Task {
            let corrected = await model.correct(segment)   // 只纠错新句
            if corrected != segment {
                // 替换尾部新句部分（防草稿里用户已手动改的内容被误动）
                if input.hasSuffix(joined) {
                    input = String(input.dropLast(joined.count)) + (joined.hasPrefix("，") ? "，" : "") + corrected
                }
                checkAgentNameAliases(in: corrected)  // 纠错后再查一遍（纠错可能引入别名）
            }
        }
    }
}

struct MessageBubble: View {
    let msg: ChatMessage
    var body: some View {
        HStack {
            if msg.isMe { Spacer() }
            VStack(alignment: msg.isMe ? .trailing : .leading, spacing: 4) {
                if let img = msg.imageUrl, !img.isEmpty {
                    // v9.6.1 修复：区分 远端(/uploads/...) vs 本地绝对路径(/Users/...)
                    if img.hasPrefix("http") {
                        AsyncImage(url: URL(string: img)) { phase in
                            if let image = phase.image { image.resizable().scaledToFit().frame(maxWidth: 220).cornerRadius(10) }
                            else { placeholderBox }
                        }
                    } else if img.hasPrefix("/uploads/") {
                        AsyncImage(url: URL(string: "\(BridgeConfig.baseURL)\(img)")) { phase in
                            if let image = phase.image { image.resizable().scaledToFit().frame(maxWidth: 220).cornerRadius(10) }
                            else { placeholderBox }
                        }
                    } else if img.hasPrefix("/") {
                        // 本地绝对路径（Documents/sent-imgs/ 等）——直接读文件，不走网络
                        #if os(iOS)
                        if let ui = UIImage(contentsOfFile: img) {
                            Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: 220).cornerRadius(10)
                        } else { placeholderBox }
                        #else
                        placeholderBox
                        #endif
                    } else {
                        #if os(iOS)
                        if let ui = UIImage(contentsOfFile: img) {
                            Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: 220).cornerRadius(10)
                        }
                        #endif
                    }
                }
                if !msg.text.isEmpty {
                    Text(msg.text)
                        .padding(10)
                        .background(msg.isMe ? Color.blue.opacity(0.85) : Color.chatSystemGray5)
                        .foregroundColor(msg.isMe ? .white : .primary)
                        .cornerRadius(14)
                }
            }
            .frame(maxWidth: 280, alignment: msg.isMe ? .trailing : .leading)
            if !msg.isMe { Spacer() }
        }
    }
    private var placeholderBox: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.25))
            .frame(width: 120, height: 90).overlay(ProgressView())
    }
}
