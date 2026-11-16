import SwiftUI

struct WatchCallView: View {
    @EnvironmentObject private var session: WatchCallSession
    @State private var dialNumber = ""

    @State private var showConnectionStatus = false
    @State private var showingSMS = false
    @Environment(\.scenePhase) private var scenePhase

    private let dialRows = [
        ["1", "2", "3"], ["4", "5", "6"],
        ["7", "8", "9"], ["*", "0", "#"],
    ]

    var body: some View {
        NavigationStack {
        Group {
            if session.call.phase == .idle || session.call.phase == .ended {
                dialer
            } else {
                ScrollView {
                    currentCall
                        .padding(.horizontal, 8)
                }
            }
        }
        .task {
            session.requestLatestState()
            if session.isUIFixture, ProcessInfo.processInfo.arguments.contains("--watch-ui-sms") { showingSMS = true }
        }
        .toolbar {
            if session.call.phase == .idle || session.call.phase == .ended {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showConnectionStatus = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("查看连接状态")
                }
            }
        }
        }
        .sheet(isPresented: $showingSMS) { WatchSMSInboxView().environmentObject(session) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.requestLatestState() }
        }
        .onChange(of: session.call.phase) { _, phase in
            if phase == .incoming || phase == .connecting || phase == .active { showingSMS = false }
        }
    }

    private var dialer: some View {
        GeometryReader { geometry in
            let keyHeight = max(22, (geometry.size.height - 48) / 4)
            let keyWidth = max(32, (geometry.size.width - 20) / 4)
            VStack(spacing: 3) {
                numberDisplay
                    .frame(height: 36)
                HStack(spacing: 4) {
                    VStack(spacing: 3) {
                        ForEach(0..<4) { row in
                            HStack(spacing: 4) {
                                ForEach(0..<3) { column in
                                    digitButton(dialRows[row][column], width: keyWidth, height: keyHeight)
                                }
                            }
                        }
                    }
                    VStack(spacing: 3) {
                        deleteButton(width: keyWidth, height: 2 * keyHeight + 3)
                        callButton(width: keyWidth, height: 2 * keyHeight + 3)
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .alert("连接状态", isPresented: $showConnectionStatus) {
            Button("好", role: .cancel) {}
        } message: {
            Text("\(session.pushStatus)\n\(session.microphoneStatus)\n\(session.connectionTiming)\n\(session.hangupFeedback?.text ?? "无待处理挂断提示")\n拨号需要配对 iPhone 可通信，且 VoWLAN 或云端可用。安全直连接听需网关支持；不支持时由 iPhone 协作。通话音频在手表收发；连接蓝牙设备时，输出由 watchOS 选择。")
        }
        .alert("拨号失败", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var feedbackColor: Color {
        guard let feedback = session.hangupFeedback else { return .secondary }
        let complete = feedback.verifying ? feedback.confirmedAt != nil : feedback.acknowledgedAt != nil
        return complete ? .green : .orange
    }

    private var numberDisplay: some View {
        HStack(spacing: 5) {
            Button { append("+") } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(session.isDialing)
            .accessibilityLabel("输入加号")

            Text(dialNumber.isEmpty ? (session.hangupFeedback?.text ?? "输入号码") : dialNumber)
                .font(dialNumber.isEmpty && session.hangupFeedback != nil ? .caption2 : .system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(dialNumber.isEmpty ? (session.hangupFeedback == nil ? Color.secondary : feedbackColor) : Color.primary)
                .lineLimit(dialNumber.isEmpty && session.hangupFeedback != nil ? 2 : 1)
                .truncationMode(.head)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(dialNumber.isEmpty ? (session.hangupFeedback?.text ?? "尚未输入电话号码") : "电话号码，\(dialNumber)")

            Button { showingSMS = true } label: {
                Image(systemName: "message.fill")
                    .foregroundStyle(session.hangupFeedback == nil ? Color.secondary : feedbackColor)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看短信")
        }
    }

    private func append(_ character: String) {
        guard !session.isDialing, dialNumber.count < 82 else { return }
        dialNumber.append(character)
    }

    private func digitButton(_ digit: String, width: CGFloat, height: CGFloat) -> some View {
        Button { append(digit) } label: {
            Text(digit)
                .font(.system(size: min(25, height * 0.75), weight: .medium, design: .rounded))
                .frame(width: width, height: height)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(session.isDialing)
        .accessibilityLabel("数字 \(digit)")
    }

    private func deleteButton(width: CGFloat, height: CGFloat) -> some View {
        Button {
            if !dialNumber.isEmpty { dialNumber.removeLast() }
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 19, weight: .medium))
                .frame(width: width, height: height)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(session.isDialing || dialNumber.isEmpty)
        .accessibilityLabel("删除最后一位")
    }

    private func callButton(width: CGFloat, height: CGFloat) -> some View {
        Button {
            if session.isDialing { session.cancelDial() }
            else { session.dial(dialNumber) }
        } label: {
            Image(systemName: session.isDialing ? "xmark" : "phone.fill")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: width, height: height)
                .background(session.isDialing ? .red : .green, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!session.isDialing && dialNumber.isEmpty)
        .accessibilityLabel(session.isDialing ? "取消拨号" : "拨号")
    }

    private var currentCall: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: session.call.phase == .incoming ? "phone.arrow.down.left.fill" : "antenna.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(session.call.phase == .incoming ? .green : .blue)
                    .symbolEffect(.pulse, isActive: session.call.phase == .incoming)
                Text(session.displayName).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(session.secondaryText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            // Primary call actions must fit on 40 mm without scrolling.
            controls
            Text(session.companionReachable ? "iPhone 可通信" : "iPhone 当前不可通信")
                .font(.caption2).foregroundStyle(.secondary)
            if session.call.phase == .connecting {
                Text("等待安卓确认接通 · " + session.audioStatus)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = session.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else if session.call.phase == .active {
                Text(session.audioStatus).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var controls: some View {
        switch session.call.phase {
        case .incoming:
            HStack(spacing: 18) {
                actionButton("phone.down.fill", color: .red, action: session.reject)
                actionButton("phone.fill", color: .green, action: session.answer)
            }
        case .active, .connecting:
            actionButton("phone.down.fill", color: .red, action: session.end)
        case .ended, .idle: EmptyView()
        }
    }

    private func actionButton(_ symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 50, height: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .disabled(session.isSendingAction)
    }
}

private struct WatchSMSInboxView: View {
    @EnvironmentObject private var session: WatchCallSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
            if session.isUIFixture, ProcessInfo.processInfo.arguments.contains("--watch-ui-thread"),
               let page = session.smsPage, let conversation = WatchSMSConversationPolicy.groups(page.rows).first {
                WatchSMSConversationView(conversation: conversation).environmentObject(session)
            } else if session.isUIFixture, ProcessInfo.processInfo.arguments.contains("--watch-ui-detail"), let row = session.smsPage?.rows.first {
                WatchSMSDetailView(row: row).environmentObject(session)
            } else {
            List {
                if let page = session.smsPage {
                    if page.devices.count > 1 {
                        Picker("安卓设备", selection: Binding(get: { page.selectedAgentID ?? "" }, set: { value in
                            guard !value.isEmpty else { return }
                            Task { await session.refreshSMS(agentID: value) }
                        })) {
                            Text("选择设备").tag("")
                            ForEach(page.devices) { Text($0.name).tag($0.id) }
                        }.disabled(session.smsBusy)
                    }
                    if page.selectedAgentID == nil {
                        Text("请先选择一台已配对安卓")
                    } else if page.rows.isEmpty {
                        Text("iPhone 尚无此设备的已同步短信")
                    }
                    ForEach(WatchSMSConversationPolicy.groups(page.rows)) { conversation in
                        NavigationLink {
                            WatchSMSConversationView(conversation: conversation).environmentObject(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if conversation.rows.contains(where: { session.isSMSUnread($0) }) { Circle().fill(.blue).frame(width: 5, height: 5) }
                                    Text(conversation.latest.sender.isEmpty ? "未知联系人" : conversation.latest.sender).font(.headline).lineLimit(1)
                                }
                                Text((conversation.latest.outgoing ? "我：" : "") + conversation.latest.preview).font(.caption).lineLimit(2)
                                Text(conversation.latest.timestamp, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("来自 iPhone 已同步记录 · 显示最近 \(page.rows.count) 条，共 \(page.total) 条。刷新不会强制唤醒安卓。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let error = session.smsError { Text(error).font(.caption).foregroundStyle(.orange) }
                Button(session.smsBusy ? "正在读取…" : "刷新短信") {
                    Task { await session.refreshSMS(agentID: session.smsPage?.selectedAgentID) }
                }.disabled(session.smsBusy)
                if session.smsBusy { ProgressView() }
            }
            }
            }
            .navigationTitle("短信")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task(id: session.companionReachable) {
                await session.refreshSMS(agentID: session.smsPage?.selectedAgentID)
            }
        }
    }
}
private struct WatchSMSConversationView: View {
    @EnvironmentObject private var session: WatchCallSession
    let conversation: WatchSMSConversation
    @State private var page: WatchSMSPage?
    @State private var failure: String?
    @State private var refresh = 0
    @State private var replying = false
    @State private var draft = ""
    private var rows: [WatchSMSRow] {
        (page?.rows ?? conversation.rows).sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(rows) { row in
                    NavigationLink {
                        WatchSMSDetailView(row: row).environmentObject(session)
                    } label: {
                        VStack(alignment: row.outgoing ? .trailing : .leading, spacing: 5) {
                            Text(row.outgoing ? "我发送" : "收到").font(.caption2).foregroundStyle(.secondary)
                            Text(row.preview).font(.body).lineLimit(5)
                            Text("\(row.sim ?? "SIM 未知") · \(row.timestamp.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if session.isSMSUnread(row) { Text("未读").font(.caption2).foregroundStyle(.blue) }
                        }.frame(maxWidth: .infinity, alignment: row.outgoing ? .trailing : .leading)
                            .padding(5)
                            .background(row.outgoing ? Color.blue.opacity(0.18) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }.id(row.id)
                }
                if let failure { Text(failure).font(.caption2).foregroundStyle(.orange) }
                Button("刷新会话") { refresh += 1 }
            }
            .task(id: rows.last?.id) { if let id = rows.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .navigationTitle(conversation.latest.sender.isEmpty ? "短信会话" : conversation.latest.sender)
        .safeAreaInset(edge: .bottom) {
            if WatchSMSConversationPolicy.replyNumber(conversation.latest.sender) != nil {
                Button { replying = true } label: {
                    Label("回复", systemImage: "arrowshape.turn.up.left.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial)
            }
        }
        .sheet(isPresented: $replying) {
            WatchSMSReplyView(conversation: conversation, draft: $draft) { refresh += 1 }
                .environmentObject(session)
        }
        .task {
            if session.isUIFixture, ProcessInfo.processInfo.arguments.contains("--watch-ui-reply") {
                draft = "收到，我稍后回复。"
                replying = true
            }
        }
        .task(id: refresh) {
            guard !conversation.peer.isEmpty else { return }
            failure = nil
            do { page = try await session.loadConversation(conversation) }
            catch { if !Task.isCancelled { failure = "刷新未完成，显示已同步消息；\(error.localizedDescription)" } }
        }
    }
}

private struct WatchSMSReplyView: View {
    @EnvironmentObject private var session: WatchCallSession
    @Environment(\.dismiss) private var dismiss
    let conversation: WatchSMSConversation
    @Binding var draft: String
    let onSent: () -> Void

    @State private var options: WatchSMSReplyOptions?
    @State private var selectedID: String?
    @State private var loading = true
    @State private var sending = false
    @State private var uncertain = false
    @State private var confirm = false
    @State private var feedback: String?
    @State private var reload = 0

    private var slot: WatchSMSReplyOptions.Slot? {
        options?.slots.first { $0.id == selectedID }
    }
    private var bodyText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        slot != nil && !bodyText.isEmpty && bodyText.count <= 2_000 && bodyText.utf8.count <= 8_000
            && !sending && !uncertain
    }

    var body: some View {
        NavigationStack {
            List {
                if let options {
                    Section("收件人") {
                        Text(options.recipient).font(.system(.body, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Section("发送卡") {
                        if options.slots.isEmpty {
                            Text("暂无可用 SIM，请确认安卓已连接").foregroundStyle(.secondary)
                            Button("重新读取") { reload += 1 }
                        } else {
                            ForEach(options.slots) { option in
                                Button { selectedID = option.id } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "simcard")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.label)
                                            if let carrier = option.carrier, !carrier.isEmpty {
                                                Text(carrier).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if selectedID == option.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                        }
                                    }
                                }.accessibilityAddTraits(selectedID == option.id ? .isSelected : [])
                            }
                        }
                    }.disabled(sending)
                } else if loading {
                    ProgressView("读取发送卡…")
                } else {
                    Button("重试读取 SIM") { reload += 1 }
                }
                Section("短信内容") {
                    TextField("输入或听写", text: $draft).disabled(sending || uncertain)
                }
                if let feedback {
                    Text(feedback).font(.caption).foregroundStyle(.orange)
                }
                Button { confirm = true } label: {
                    if sending { ProgressView("正在发送…") }
                    else { Label("发送短信", systemImage: "paperplane.fill") }
                }.disabled(!canSend)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("回复短信")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(sending)
                }
            }
            .confirmationDialog("确认发送短信", isPresented: $confirm, titleVisibility: .visible) {
                Button("通过 \(slot?.label ?? "SIM") 发送") { Task { await send() } }
                Button("取消", role: .cancel) {}
            } message: { Text("发送给 \(options?.recipient ?? "")") }
            .task(id: reload) {
                loading = true
                feedback = nil
                do {
                    let result = try await session.replyOptions(for: conversation)
                    guard !Task.isCancelled else { return }
                    options = result
                    selectedID = result.slots.first { $0.id == result.selectedID }?.id ?? result.slots.first?.id
                } catch {
                    if !Task.isCancelled { feedback = error.localizedDescription }
                }
                loading = false
            }
        }
        .interactiveDismissDisabled(sending)
    }

    private func send() async {
        guard canSend, let slot else { return }
        sending = true
        defer { sending = false }
        switch await session.sendReply(to: conversation, text: bodyText, slotID: slot.id) {
        case .sent:
            draft = ""
            onSent()
            dismiss()
        case let .failed(error):
            feedback = error
        case .uncertain:
            uncertain = true
            feedback = "发送结果未确认。请先在 iPhone 查看记录，避免重复发送。"
        }
    }
}

private struct WatchSMSDetailView: View {
    @EnvironmentObject private var session: WatchCallSession
    let row: WatchSMSRow
    @State private var detail: WatchSMSDetail?
    @State private var error: String?
    @State private var attempt = 0
    @State private var readSyncFailed = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.sender).font(.headline)
                Text("\(row.outgoing ? "发出" : "收到") · \(row.sim ?? "SIM 未知")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(row.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                if let detail {
                    Text(detail.body).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    if detail.truncated { Text("短信过长，完整内容请在 iPhone 查看").font(.caption).foregroundStyle(.orange) }
                    if readSyncFailed { Text("已阅读，已读状态尚未确认同步").font(.caption2).foregroundStyle(.orange) }
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("重试") { attempt += 1 }
                } else { ProgressView("读取正文…") }
            }.padding(.horizontal, 4)
        }
        .navigationTitle("短信正文")
        .task(id: attempt) {
            error = nil
            do {
                let value = try await session.loadSMS(row)
                guard !Task.isCancelled else { return }
                detail = value
                readSyncFailed = !(await session.markSMSRead(row))
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
