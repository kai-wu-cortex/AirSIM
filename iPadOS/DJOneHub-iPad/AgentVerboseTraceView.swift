import SwiftUI
import UIKit

private enum AgentVerboseTraceFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case failures = "错误"
    case calls = "通话"
    case relay = "Relay"
    case at = "AT"
    case usb = "USB"

    var id: String { rawValue }
}

private struct AgentVerboseTimelineItem: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let source: String
    let category: String
    let traceID: String?
    let title: String
    let detail: String
    let isFailure: Bool

    var systemImage: String {
        if isFailure { return "exclamationmark.triangle.fill" }
        switch category.lowercased() {
        case "at": return "terminal.fill"
        case "usb": return "cable.connector"
        case "http": return "arrow.left.arrow.right"
        case "voice", "cloud-call", "cloud-call-control": return "waveform"
        case "relay": return "network"
        default: return source == "APP" ? "iphone" : "cpu"
        }
    }

    var tint: Color {
        if isFailure { return .red }
        switch category.lowercased() {
        case "at": return .green
        case "usb": return .cyan
        case "voice", "cloud-call", "cloud-call-control": return .purple
        case "relay": return .indigo
        case "http": return .blue
        default: return .secondary
        }
    }
}

@MainActor
private final class AgentVerboseTraceViewModel: ObservableObject {
    @Published var enabled = false
    @Published var localEntries: [AgentVerboseTraceEntry] = []
    @Published var agentEvents: [ModuleDebugEvent] = []
    @Published var agentState = "未连接"
    @Published var errorMessage: String?
    @Published var exportText = "DJOneHub Agent Verbose Trace\n"

    private let api: DJOneHubAPI
    private var lastSequence: UInt64 = 0

    init(api: DJOneHubAPI) { self.api = api }

    func run() async {
        enabled = await AgentVerboseTraceRecorder.shared.isEnabled()
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(enabled ? 1 : 2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        Task {
            await AgentVerboseTraceRecorder.shared.setEnabled(value)
            await refresh()
        }
    }

    func refresh() async {
        localEntries = await AgentVerboseTraceRecorder.shared.snapshot()
        if enabled {
            do {
                let snapshot = try await api.moduleDebug(after: lastSequence, limit: 600)
                merge(snapshot.events)
                lastSequence = max(lastSequence, snapshot.debug.latestSequence)
                agentState = "Agent \(snapshot.agent.version) · seq \(snapshot.debug.latestSequence)"
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                agentState = "Agent 不可达"
                errorMessage = error.localizedDescription
            }
        }
        await rebuildExport()
    }

    func clear() async {
        await AgentVerboseTraceRecorder.shared.clear()
        localEntries = []
        agentEvents = []
        lastSequence = 0
        do {
            try await api.clearModuleDebug()
            agentState = "Agent 日志已清除"
            errorMessage = nil
        } catch {
            errorMessage = "本机日志已清除；Agent 日志清除失败：\(error.localizedDescription)"
        }
        await refresh()
    }

    var timeline: [AgentVerboseTimelineItem] {
        let local = localEntries.map { entry in
            let fields = (entry.fields ?? [:])
                .filter { $0.key != "trace_id" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " · ")
            let detail = [fields, entry.detail]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return AgentVerboseTimelineItem(
                id: "app-\(entry.id.uuidString)",
                timestamp: entry.timestamp,
                source: entry.source ?? "APP",
                category: entry.category ?? (entry.stage == .route ? "usb" : "http"),
                traceID: entry.traceID == "--------" ? nil : entry.traceID,
                title: "\(entry.method) \(entry.path)",
                detail: entry.elapsedMilliseconds.map { "\(detail) · \($0) ms" } ?? detail,
                isFailure: entry.stage == .failure
            )
        }
        let remote = agentEvents.compactMap { event -> AgentVerboseTimelineItem? in
            if event.category == "http", event.summary.hasPrefix("GET /api/debug") { return nil }
            let fields = event.fields ?? [:]
            let fieldText = fields
                .filter { $0.key != "trace_id" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " · ")
            let parts = [event.direction, fieldText, event.payload]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
            let statusFailure = Int(fields["status"] ?? "").map { $0 >= 400 } ?? false
            return AgentVerboseTimelineItem(
                id: "agent-\(event.sequence)",
                timestamp: Self.parse(event.timestamp),
                source: "AGENT",
                category: event.category,
                traceID: fields["trace_id"],
                title: event.summary,
                detail: parts.joined(separator: "\n"),
                isFailure: event.direction == "error" || statusFailure
            )
        }
        return (local + remote).sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp < $1.timestamp
        }
    }

    private func merge(_ newEvents: [ModuleDebugEvent]) {
        let known = Set(agentEvents.map(\.sequence))
        agentEvents.append(contentsOf: newEvents.filter { !known.contains($0.sequence) })
        if agentEvents.count > 2_000 { agentEvents.removeFirst(agentEvents.count - 2_000) }
    }

    private func rebuildExport() async {
        let remote = agentEvents.map {
            AgentVerboseRemoteEvent(
                sequence: $0.sequence,
                timestamp: $0.timestamp,
                category: $0.category,
                direction: $0.direction ?? "",
                summary: $0.summary,
                payload: $0.payload ?? "",
                fields: $0.fields ?? [:]
            )
        }
        exportText = await AgentVerboseTraceRecorder.shared.exportText(agentEvents: remote)
    }

    private static func parse(_ value: String) -> Date {
        if let date = fractionalFormatter.date(from: value) { return date }
        return wholeFormatter.date(from: value) ?? .distantPast
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct AgentVerboseTraceView: View {
    @StateObject private var model: AgentVerboseTraceViewModel
    @State private var filter: AgentVerboseTraceFilter = .all
    @State private var selectedItem: AgentVerboseTimelineItem?
    @State private var showingClearConfirmation = false

    init(api: DJOneHubAPI) {
        _model = StateObject(wrappedValue: AgentVerboseTraceViewModel(api: api))
    }

    var body: some View {
        List {
                Section {
                    Toggle(isOn: Binding(get: { model.enabled }, set: model.setEnabled)) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Verbose 链路模式")
                                Text(model.enabled ? "正在采集 App、USB、HTTP、AT 与 Agent 事件" : "关闭时不记录新的 App 请求")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(model.enabled ? .orange : .secondary)
                        }
                    }

                    LabeledContent("Agent 通道", value: model.agentState)
                    LabeledContent("本机链路", value: "\(model.localEntries.count) 条")
                    LabeledContent("Agent 事件", value: "\(model.agentEvents.count) 条")
                } header: {
                    Text("链式调试")
                } footer: {
                    Text("日志可能包含电话号码、短信正文、AT 响应和设备标识。排查结束后请关闭 Verbose，并在分享前检查内容。")
                }

                Section {
                    Picker("筛选", selection: $filter) {
                        ForEach(AgentVerboseTraceFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("实时命令链路") {
                    if filteredTimeline.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("暂无链路事件").font(.headline)
                            Text(model.enabled ? "执行拨号、短信、设置或 AT 操作后会实时显示。" : "请先开启 Verbose 链路模式。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(filteredTimeline) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                timelineRow(item)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .contextMenu {
                                Button("复制本条", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = "\(item.title)\n\(item.detail)"
                                }
                            }
                        }
                    }
                }
        }
        .navigationTitle("Agent Verbose")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: model.exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button(role: .destructive) { showingClearConfirmation = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task { await model.run() }
        .refreshable { await model.refresh() }
        .sheet(item: $selectedItem) { item in
            AgentVerboseTraceDetailView(item: item)
        }
        .confirmationDialog("清除 App 与 Agent 调试日志？", isPresented: $showingClearConfirmation) {
            Button("全部清除", role: .destructive) { Task { await model.clear() } }
            Button("取消", role: .cancel) {}
        }
    }

    private var filteredTimeline: [AgentVerboseTimelineItem] {
        model.timeline.filter { item in
            switch filter {
            case .all: return true
            case .failures: return item.isFailure
            case .calls:
                return ["voice", "cloud-call", "cloud-call-control"].contains(item.category.lowercased())
            case .relay: return item.source == "RELAY" || item.category.lowercased() == "relay"
            case .at: return item.category.lowercased() == "at"
            case .usb: return item.category.lowercased() == "usb"
            }
        }
    }

    private func timelineRow(_ item: AgentVerboseTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(item.tint)
                .frame(width: 28, height: 28)
                .background(item.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.source)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(item.source == "APP" ? .blue : .purple)
                    Text(Self.timeFormatter.string(from: item.timestamp))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let traceID = item.traceID {
                        Text("#\(traceID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.isFailure ? .red : .primary)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct AgentVerboseTraceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: AgentVerboseTimelineItem

    var body: some View {
        NavigationStack {
            List {
                Section("事件") {
                    LabeledContent("来源", value: item.source)
                    LabeledContent("分类", value: item.category)
                    if let traceID = item.traceID { LabeledContent("Trace ID", value: traceID) }
                    LabeledContent("时间", value: item.timestamp.formatted(.iso8601))
                }
                Section("命令") {
                    Text(item.title).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if !item.detail.isEmpty {
                    Section("完整内容") {
                        Text(item.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("链路详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = "\(item.title)\n\(item.detail)"
                    }
                }
            }
        }
    }
}
