import SwiftUI
import SafariServices
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
    @AppStorage("autoSpeakReplies") private var autoSpeakReplies = true  // v9.11 收到回复自动朗读开关（用户 2026-10-03 询问）
    @State private var showWargame = false                  // v9.10 推演工作台
    @State private var showDrafts = false                   // v9.14 成稿草稿列表（CLD 能力一致性）
    @State private var showPending = false                   // R1 待你决定
    @State private var showBrief = false                     // R2 晨报
    @State private var pendingBadge = 0                      // R1 徽标计数

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
                // R2 ☀️ 晨报入口
                Button {
                    showBrief = true
                } label: {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 13)).foregroundColor(.yellow)
                        .frame(width: 28, height: 28)
                        .background(Color.yellow.opacity(0.15)).clipShape(Circle())
                }
                .buttonStyle(.plain)
                // R1 📮 待你决定(带徽标)
                Button {
                    showPending = true
                    Task { await refreshPendingBadge() }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 14)).foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08)).clipShape(Circle())
                        if pendingBadge > 0 {
                            Text("\(pendingBadge)")
                                .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                .padding(3).background(Color.red).clipShape(Circle())
                                .offset(x: 5, y: -5)
                        }
                    }
                }
                .buttonStyle(.plain)
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
                // v9.12（2026-10-03 用户要求）：cldvoice 成稿入口 —— 当前会话 → 8902 成稿引擎
                Button {
                    model.openDraftFlow()
                } label: {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 14)).foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(red: 0.20, green: 0.82, blue: 0.86).opacity(0.25)).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.showDraftFlow)
                .help("语音讨论成稿 · cldvoice")
                // v9.10 商业沙盘推演工作台入口（SFSafari 内嵌 /sb/wargame）
                Button {
                    showWargame = true
                } label: {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 14)).foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.orange.opacity(0.25)).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("商业沙盘 · 推演工作台")
                if model.queueCount > 0 && model.currentTarget == "mac-mini" {
                    QueueBadge(count: model.queueCount)
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
            // v9.11：自动朗读可关（autoSpeakReplies）；默认开=收到对方新消息即朗读
            if autoSpeakReplies, let last = model.messages.last, !last.isMe {
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
        .sheet(isPresented: $model.showDraftFlow) {
            DraftFlowView(model: model, speech: speech)
        }
        .sheet(isPresented: $showDrafts) {
            DraftsListView(model: model)
        }
        .sheet(isPresented: $showAccount) {
            DeepSeekAccountView()
        }

        // v9.10 商业沙盘推演工作台（内嵌打开, 不退出星台）
        .sheet(isPresented: $showWargame) {
            #if os(iOS)
            SafariSheet(url: URL(string: "\(BridgeConfig.baseURL)/wargame")!)
            #else
            ExternalLinkView(url: URL(string: "\(BridgeConfig.baseURL)/wargame")!)
            #endif
        }
        // R1 待你决定收件箱
        .sheet(isPresented: $showPending) {
            PendingDecisionsView()
        }
        // R2 晨报
        .sheet(isPresented: $showBrief) {
            MorningBriefView()
        }
        // R1 徽标轮询(30s)
        .task {
            while !Task.isCancelled {
                await refreshPendingBadge()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func refreshPendingBadge() async {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/pending-decisions") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pendingBadge = (obj["count"] as? Int) ?? 0
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

            // v9.11：自动朗读开关（用户 2026-10-03 询问「为什么读出来」）
            Toggle(isOn: $autoSpeakReplies) {
                Text("自动朗读回复").font(.subheadline).foregroundColor(.white.opacity(0.85))
            }
            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.20, green: 0.82, blue: 0.86)))
            .padding(.horizontal, 16).padding(.vertical, 6)

            Divider().overlay(Color.white.opacity(0.1))

            // v9.14：成稿草稿入口（CLD 能力一致性——草稿可查可复投）
            Button {
                showDrafts = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14)).foregroundColor(.white.opacity(0.9))
                    Text("成稿草稿").font(.subheadline).foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain)

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


// MARK: - v9.13 成稿弹层（状态球生成中 → 草稿可编辑 → 插入发送）
struct DraftFlowView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var speech: SpeechManager
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case generating, review }
    @State private var phase: Phase = .generating
    @State private var statusText = "正在整理最近对话…"
    @State private var title = "语音需求"
    @State private var fullText = ""
    @State private var shown = 0
    @State private var editable = ""
    @State private var errorText: String? = nil
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(phase == .generating ? "cldvoice 成稿" : "草稿确认 · \(title)")
                    .font(.headline).foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20)).foregroundColor(.white.opacity(0.55))
                }.buttonStyle(.plain)
            }
            if phase == .generating {
                Spacer()
                statusBall
                Text(errorText ?? statusText)
                    .font(.subheadline)
                    .foregroundColor(errorText == nil ? .white.opacity(0.8) : .red)
                    .multilineTextAlignment(.center)
                ScrollView {
                    Text(String(fullText.prefix(shown)))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 300)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
                if errorText != nil {
                    HStack(spacing: 12) {
                        Button("重试") { restart() }.buttonStyle(.bordered).tint(.teal)
                        Button("取消") { dismiss() }.buttonStyle(.bordered).tint(.gray)
                    }
                }
                Spacer()
            } else {
                TextEditor(text: $editable)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(10)
                    .frame(maxHeight: .infinity)
                // v9.13.1：语音补充——按住说话，实时识别文字浮层，松开追加到草稿
                if speech.isListening {
                    Text(speech.partialText.isEmpty ? "正在听…" : speech.partialText)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.20, green: 0.82, blue: 0.86).opacity(0.18))
                        .cornerRadius(8)
                }
                Button {
                    // 按住说话（DragGesture 按住触发；松开结束）
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color(red: 0.20, green: 0.82, blue: 0.86).opacity(0.25)).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !speech.isListening { speech.onResult = { final in
                                if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    editable = editable.isEmpty ? final : editable + "\n" + final
                                }
                                speech.onResult = nil
                            }
                            speech.startListening() } }
                        .onEnded { _ in if speech.isListening { speech.stopListening(finish: true) } }
                )
                .help("按住说话，补充草稿内容")
                HStack(spacing: 10) {
                    Button("重新生成") { restart() }.buttonStyle(.bordered).tint(.gray)
                    Button("纠错") { Task { await correctDraft() } }.buttonStyle(.bordered).tint(.orange)
                    Spacer()
                    Button("仅插入") {
                        model.insertLocalMessage("📝 成稿 · \(title)\n\n\(editable)")
                        dismiss()
                    }.buttonStyle(.bordered).tint(.teal)
                    Button("发送") {
                        model.send(text: editable)
                        dismiss()
                    }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.08, green: 0.10, blue: 0.16).ignoresSafeArea())
        .onAppear { start() }
    }

    private var statusBall: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [
                Color(red: 0.30, green: 0.90, blue: 0.95),
                Color(red: 0.12, green: 0.45, blue: 0.60).opacity(0.45),
                .clear
            ], center: .center, startRadius: 6, endRadius: 62))
            .frame(width: 116, height: 116)
            Circle().stroke(Color(red: 0.30, green: 0.90, blue: 0.95).opacity(0.7), lineWidth: 2)
                .frame(width: 116, height: 116)
                .scaleEffect(pulse ? 1.16 : 0.85)
            Image(systemName: "waveform")
                .font(.system(size: 32)).foregroundColor(.white)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func start() {
        phase = .generating
        errorText = nil
        fullText = ""; shown = 0; pulse = false
        let pool = model.buildDraftPool()
        statusText = pool.isEmpty ? "没有可成稿的对话，先聊几句吧" : "已取最近 \(pool.count) 条对话，正在成稿…"
        guard !pool.isEmpty else { errorText = "无可成稿内容"; return }
        Task {
            do {
                let (t, c) = try await model.requestDraft(discussion: pool)
                title = t; fullText = c; editable = c
                // 逐字实时呈现（真实内容按节奏展开）
                let step = 14
                var i = 0
                while i < fullText.count {
                    shown = i
                    try? await Task.sleep(nanoseconds: 26_000_000)
                    i += step
                }
                shown = fullText.count
                phase = .review
            } catch {
                errorText = "成稿失败：\(error.localizedDescription)"
            }
        }
    }

    // v9.15：纠错——草稿全文送桥 /api/correct（ollama 纠错），结果回填编辑框
    private func correctDraft() async {
        guard !editable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/correct") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": editable])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let corrected = obj["corrected"] as? String, !corrected.isEmpty {
                editable = corrected
            }
        } catch { /* 纠错失败保留原文 */ }
    }

    private func restart() {
        fullText = ""; shown = 0; editable = ""; title = "语音需求"
        start()
    }
}


// MARK: - v9.14 成稿草稿列表（CLD 能力一致性：查/读/复投）
struct DraftsListView: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var loaded = false
    @State private var errorText: String? = nil
    @State private var selected: (name: String, content: String)? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("成稿草稿").font(.headline).foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundColor(.white.opacity(0.55))
                }.buttonStyle(.plain)
            }
            if let sel = selected {
                TextEditor(text: Binding(get: { sel.content }, set: { selected = (sel.name, $0) }))
                    .font(.system(size: 13)).foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(6).background(Color.white.opacity(0.06)).cornerRadius(8)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    Button("返回列表") { selected = nil }.buttonStyle(.bordered).tint(.gray)
                    Button("插入 CLD") { Task { await insertToCld(sel.name) } }.buttonStyle(.bordered).tint(.orange)
                    Spacer()
                    Button("仅插入") {
                        model.insertLocalMessage("📝 成稿 · \(sel.name)\n\n\(sel.content)")
                        dismiss()
                    }.buttonStyle(.bordered).tint(.teal)
                    Button("发送") {
                        model.send(text: sel.content)
                        dismiss()
                    }.buttonStyle(.borderedProminent).tint(.teal)
                }
            } else {
                if !loaded {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorText {
                    Text(err).font(.subheadline).foregroundColor(.red)
                } else if names.isEmpty {
                    Text("暂无草稿").font(.subheadline).foregroundColor(.white.opacity(0.6))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(names, id: \.self) { n in
                                Button {
                                    Task { await open(n) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(n.replacingOccurrences(of: ".md", with: ""))
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.9))
                                            Text(draftTime(n)).font(.caption).foregroundColor(.white.opacity(0.45))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                Divider().overlay(Color.white.opacity(0.05))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.08, green: 0.10, blue: 0.16).ignoresSafeArea())
        .onAppear { Task { await loadList() } }
    }

    private func draftTime(_ name: String) -> String {
        // 形如 20261003-182233.md / cldvoice-20261002101329.md → 可读时间
        let digits = name.filter { $0.isNumber }
        guard digits.count >= 8 else { return name }
        let y = digits.prefix(4), mo = digits.dropFirst(4).prefix(2), d = digits.dropFirst(6).prefix(2)
        var s = "\(y)-\(mo)-\(d)"
        if digits.count >= 12 {
            let hh = digits.dropFirst(8).prefix(2), mm = digits.dropFirst(10).prefix(2)
            s += " \(hh):\(mm)"
        }
        return s
    }

    private func loadList() async {
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/drafts") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["drafts"] as? [String] {
                names = arr.sorted(by: >)
            } else { errorText = "草稿列表解析失败" }
        } catch { errorText = "获取草稿失败：\(error.localizedDescription)" }
        loaded = true
    }

    // v9.15：插入 CLD 上下文——草稿 id（去 .md）→ 桥 → 8902 写黑板 notes/collab/cld-voice-draft-<id>
    private func insertToCld(_ name: String) async {
        let id = name.replacingOccurrences(of: ".md", with: "")
        guard let url = URL(string: "\(BridgeConfig.baseURL)/api/draft/insert") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "title": id])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["ok"] as? Bool == true {
                let key = obj["key"] as? String ?? ""
                model.insertLocalMessage("📥 已插入 CLD 上下文：\(key)")
                dismiss()
            }
        } catch { errorText = "插入失败：\(error.localizedDescription)" }
    }

    private func open(_ name: String) async {
        var comps = URLComponents(string: "\(BridgeConfig.baseURL)/api/draft/file")!
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(BridgeConfig.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = obj["content"] as? String {
                selected = (name, content)
            }
        } catch { errorText = "读取失败：\(error.localizedDescription)" }
    }
}

/// 排队徽标（拆出小视图，避免 macOS 端大表达式 type-check 超时）
private struct QueueBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass").font(.system(size: 10))
            Text("\(count) 条排队").font(.caption)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.orange.opacity(0.2)).cornerRadius(10)
    }
}

#if os(macOS)
/// macOS 无 SFSafariViewController：浏览器打开兜底
struct ExternalLinkView: View {
    let url: URL
    var body: some View {
        VStack(spacing: 12) {
            Text("该功能在 Mac 版以浏览器打开").font(.caption).foregroundColor(.secondary)
            Button("打开") { NSWorkspace.shared.open(url) }
        }
        .padding(20)
    }
}
#endif
