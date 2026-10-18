import SwiftUI

struct VoBLEPairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingUnpairConfirmation = false
    @State private var unpairing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: stateSymbol)
                        .font(.title2)
                        .foregroundStyle(stateColor)
                        .frame(width: 42, height: 42)
                        .background(stateColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stateTitle).font(.headline)
                        Text(stateDetail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                if let identity = model.voble.authenticatedIdentity {
                    LabeledContent("已认证 Agent", value: identity)
                }
                if let message = model.voble.errorMessage, !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("蓝牙连接")
            } footer: {
                Text("蓝牙模式独立于 VoWLAN 和云端 Relay；认证完成前不会开放拨号控制或通话音频。")
            }

            if let sas = model.voble.pendingSAS {
                Section("核对安全码") {
                    Text(sas)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("蓝牙配对安全码 \(sas)")
                    Text("确认此六位数字与 Android AirSIM 显示的一致。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("数字一致，完成配对", systemImage: "checkmark.shield.fill") {
                        model.voble.confirmPairing()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("取消本次配对", role: .cancel) {
                        model.voble.cancelPairing()
                    }
                }
            }

            if !model.voble.discoveredPeers.isEmpty {
                Section("发现的 Android Agent") {
                    ForEach(model.voble.discoveredPeers) { peer in
                        Button {
                            model.voble.connect(peer)
                        } label: {
                            HStack {
                                Label(peer.name, systemImage: "smartphone")
                                Spacer()
                                Text("\(peer.signal) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("重新扫描", systemImage: "arrow.clockwise") {
                    model.voble.stop()
                    model.voble.start()
                }
                if model.voble.authenticatedIdentity != nil {
                    Button("取消 VoBLE 配对", systemImage: "trash", role: .destructive) {
                        showingUnpairConfirmation = true
                    }
                    .disabled(unpairing)
                } else if model.voble.recoverableIdentity != nil,
                          case .failed = model.voble.state {
                    Button("清除本机旧凭据并重新扫描", systemImage: "arrow.counterclockwise") {
                        model.voble.clearLocalCredentialAndRetry()
                    }
                }
            }
        }
        .navigationTitle("蓝牙 Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.voble.start() }
        .confirmationDialog(
            "同时删除 iPhone 与 Android 上的 VoBLE 凭据？",
            isPresented: $showingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("取消配对", role: .destructive) {
                unpairing = true
                Task {
                    defer { unpairing = false }
                    try? await model.voble.unpairCurrentPeer()
                }
            }
            Button("保留配对", role: .cancel) {}
        } message: {
            Text("取消后需要重新核对六位安全码。VoWLAN 与云端配置不会受到影响。")
        }
    }

    private var stateTitle: String {
        switch model.voble.state {
        case .stopped: "尚未启动"
        case .bluetoothUnavailable: "蓝牙不可用"
        case .scanning: "正在查找 Android Agent"
        case .connecting: "正在连接"
        case .connected: "已连接，正在发现服务"
        case .authenticating: "正在进行应用层认证"
        case .ready: "蓝牙通话已就绪"
        case .failed: "连接失败"
        }
    }

    private var stateDetail: String {
        switch model.voble.state {
        case .ready: "控制通道已认证；音频通道将在通话时启动"
        case .failed(let message): message
        case .bluetoothUnavailable: "请在系统设置中打开蓝牙并允许 AirSIM 访问"
        default: "请让 Android AirSIM 保持运行并开启蓝牙模式"
        }
    }

    private var stateSymbol: String {
        switch model.voble.state {
        case .ready: "checkmark.circle.fill"
        case .failed, .bluetoothUnavailable: "exclamationmark.triangle.fill"
        case .stopped: "wave.3.right.circle"
        default: "wave.3.right"
        }
    }

    private var stateColor: Color {
        switch model.voble.state {
        case .ready: .green
        case .failed, .bluetoothUnavailable: .orange
        case .stopped: .secondary
        default: .blue
        }
    }
}
