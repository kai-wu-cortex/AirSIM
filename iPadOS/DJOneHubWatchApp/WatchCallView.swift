import SwiftUI

struct WatchCallView: View {
    @EnvironmentObject private var session: WatchCallSession
    @State private var dialNumber = ""

    @State private var showConnectionStatus = false

    private let dialRows = [
        ["1", "2", "3"], ["4", "5", "6"],
        ["7", "8", "9"], ["*", "0", "#"],
    ]

    var body: some View {
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
        .onAppear { session.requestLatestState() }
    }

    private var dialer: some View {
        GeometryReader { geometry in
            let keyHeight = max(32, (geometry.size.height - 48) / 4)
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
            Text("\(session.pushStatus)\n\(session.microphoneStatus)\n拨号需要配对 iPhone 可达，且 VoWLAN 或云端可用。通话音频在手表收发；连接蓝牙设备时，输出由 watchOS 选择。")
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

            Text(dialNumber.isEmpty ? "输入号码" : dialNumber)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(dialNumber.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(dialNumber.isEmpty ? "尚未输入电话号码" : "电话号码，\(dialNumber)")

            Button { showConnectionStatus = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看连接状态")
        }
    }

    private func append(_ character: String) {
        guard !session.isDialing, dialNumber.count < 82 else { return }
        dialNumber.append(character)
    }

    private func digitButton(_ digit: String, width: CGFloat, height: CGFloat) -> some View {
        Button { append(digit) } label: {
            Text(digit)
                .font(.system(size: min(25, height * 0.57), weight: .medium, design: .rounded))
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
        VStack(spacing: 10) {
            Image(systemName: session.call.phase == .incoming ? "phone.arrow.down.left.fill" : "antenna.radiowaves.left.and.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(session.call.phase == .incoming ? .green : .blue)
                .symbolEffect(.pulse, isActive: session.call.phase == .incoming)

            Text(session.displayName)
                .font(.headline)
                .lineLimit(1)
            Text(session.secondaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            controls

            if let error = session.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if session.call.phase == .active {
                Text("Apple Watch 网络语音已连接")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
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
