import SwiftUI

struct WatchCallView: View {
    var body: some View { WatchSMSInboxView() }
}

private struct WatchSMSInboxView: View {
    @EnvironmentObject private var session: WatchCallSession
    @Environment(\.scenePhase) private var scenePhase
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
                        Text("此设备暂无可显示的短信")
                    }
                    ForEach(WatchSMSConversationPolicy.groups(page.rows)) { conversation in
                        NavigationLink {
                            WatchSMSConversationView(conversation: conversation).environmentObject(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if conversation.rows.contains(where: { session.isSMSUnread($0) }) { Circle().fill(.blue).frame(width: 5, height: 5) }
                                    if let brand = SMSCarrierBrand.match(conversation.latest.sender) {
                                        Image(brand.rawValue).resizable().scaledToFit().padding(4)
                                            .frame(width: 26, height: 26).background(.white, in: Circle())
                                    }
                                    Text(conversation.latest.sender.isEmpty ? "未知联系人" : conversation.latest.sender).font(.headline).lineLimit(1)
                                }
                                Text((conversation.latest.outgoing ? "我：" : "") + conversation.latest.preview).font(.caption).lineLimit(2)
                                Text(conversation.latest.timestamp, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let source = session.smsUsingDirect
                        ? (session.smsShowingCompanionHistory ? "安卓直连 · iPhone 历史" : "安卓直连")
                        : (session.smsShowingCachedHistory ? "上次同步" : "iPhone 已同步")
                    Text("\(source) · 最近 \(page.rows.count) 条")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("最后同步：\(page.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let error = session.smsError { Text(error).font(.caption).foregroundStyle(.orange) }
                if session.smsBusy { ProgressView() }
            }
            }
            }
            .navigationTitle("短信")
            .task(id: [scenePhase == .active, session.companionReachable]) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await session.refreshSMS()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                }
            }
        }
    }
}
private struct WatchSMSConversationView: View {
    @EnvironmentObject private var session: WatchCallSession
    @Environment(\.scenePhase) private var scenePhase
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
        .task(id: scenePhase == .active ? refresh : nil) {
            guard scenePhase == .active, !conversation.peer.isEmpty else { return }
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
    @State private var checking = false
    @State private var dismissPending = false
    @Environment(\.scenePhase) private var scenePhase
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
                if uncertain {
                    Button("查询发送结果") { Task { await checkResult() } }.disabled(checking)
                    Button("结束查询", role: .destructive) { dismissPending = true }.disabled(checking)
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
            .confirmationDialog("结束查询？", isPresented: $dismissPending, titleVisibility: .visible) {
                Button("已核对，结束查询", role: .destructive) {
                    session.dismissPendingReply(for: conversation)
                    uncertain = false
                    draft = ""
                    feedback = nil
                }
            } message: { Text("安卓仍可能已发出上一条短信。请核对后再发送。") }
            .onAppear { uncertain = session.hasPendingReply(for: conversation) }
            .task(id: uncertain && scenePhase == .active) {
                guard uncertain, scenePhase == .active else { return }
                while !Task.isCancelled, uncertain {
                    await checkResult()
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                }
            }
            .task(id: reload) {
                loading = true
                if !session.hasPendingReply(for: conversation) { feedback = nil }
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

    private func checkResult() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        switch await session.checkReply(for: conversation) {
        case .sent:
            draft = ""
            onSent()
            dismiss()
        case let .failed(error):
            uncertain = false
            feedback = error
        case .uncertain:
            feedback = "发送结果待确认。重新连接后可以再次查询。"
        }
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
            feedback = "发送结果待确认，可查询原发送记录。"
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
                    if detail.truncated { Text("当前仅显示部分内容").font(.caption).foregroundStyle(.orange) }
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
