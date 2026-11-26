import Foundation

var assertionCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !condition() { fatalError(message) }
}

let start = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

// Stages, copy and the name line: progress only, never a contact name.
do {
    var progress = CloudAnswerProgress(startedAt: start)
    check(progress.stage == .connectingCloud, "An accepted answer starts by connecting to the cloud")
    check(progress.nameLine(at: at(0)) == "连接云端 0 秒", "Name line shows only progress")
    check(progress.nameLine(at: at(3.4)) == "连接云端 3 秒", "Waited seconds round down")
    progress.apply(.control(status: "action_queued", role: nil), at: at(1))
    check(progress.stage == .waitingForAndroid, "Relay queued the answer for Android")
    check(progress.stage.title == "正在等待安卓端响应" && progress.stage.shortLabel == "等待安卓端", "Waiting copy")
    progress.apply(.control(status: "peer_connected", role: "iphone"), at: at(1.5))
    check(progress.stage == .waitingForAndroid, "Another iPhone joining is not Android")
    progress.apply(.control(status: "peer_connected", role: "agent"), at: at(2))
    check(progress.stage == .androidAnswering, "Android joined and receives the queued answer")
    progress.apply(.control(status: "answer_ok", role: nil), at: at(3))
    check(progress.stage == .connectingVoice, "Android answered the carrier call")
    progress.apply(.control(status: "action_queued", role: nil), at: at(3.5))
    check(progress.stage == .connectingVoice, "A late status never moves the stage back")
    check(progress.stageEnteredAt == at(3), "A late status keeps the stage clock")
    progress.apply(.downlinkAudio, at: at(4))
    check(progress.connectedAt == at(4) && progress.isFinished, "Downlink audio connects without ACTIVE")
    progress.tick(at: at(40))
    check(progress.failure == nil, "A connected call never times out")
}

do {
    var receipt = CloudAnswerProgress(startedAt: start)
    receipt.apply(.earlyReceipt(agentConnected: false), at: at(1))
    check(receipt.stage == .waitingForAndroid, "HTTP receipt without Android waits for Android")
    receipt.apply(.earlyReceipt(agentConnected: true), at: at(2))
    check(receipt.stage == .androidAnswering, "HTTP receipt with Android is answering")
    var forwarded = CloudAnswerProgress(startedAt: start)
    forwarded.apply(.control(status: "action_forwarded", role: nil), at: at(1))
    check(forwarded.stage == .androidAnswering, "Relay forwarded the answer")
    for status in ["active", "pcm_first_frame"] {
        var connected = CloudAnswerProgress(startedAt: start)
        connected.apply(.control(status: status, role: nil), at: at(2))
        check(connected.connectedAt == at(2), "\(status) connects")
    }
}

// Failures and what each one does to the carrier call.
do {
    func failure(after statuses: [String]) -> CloudAnswerFailure? {
        var progress = CloudAnswerProgress(startedAt: start)
        for (index, status) in statuses.enumerated() {
            progress.apply(.control(status: status, role: nil), at: at(Double(index + 1)))
        }
        return progress.failure
    }
    check(failure(after: ["answer_unavailable"]) == .androidNoAudio(callAnswered: false), "Android refused to answer")
    check(failure(after: ["answer_ok", "action_error"]) == .androidNoAudio(callAnswered: true), "Voice failed after answering")
    check(failure(after: ["action_forwarded", "action_error"]) == .androidAnswerFailed, "Android could not answer")
    check(failure(after: ["ownership_lost"]) == .answeredElsewhere, "Another device answered")
    // AVF answers every Relay event (peer_connected, owner_claimed) with an
    // identity-less action_error; it is not about this answer.
    var unattributed = CloudAnswerProgress(startedAt: start)
    unattributed.apply(.control(status: "action_error", role: nil, identified: false), at: at(1))
    unattributed.apply(.control(status: "answer_ok", role: nil), at: at(2))
    unattributed.apply(.control(status: "action_error", role: nil, identified: false), at: at(3))
    unattributed.apply(.control(status: "answer_unavailable", role: nil, identified: false), at: at(4))
    check(unattributed.failure == nil && unattributed.stage == .connectingVoice,
          "Errors without this call's identity never fail the answer")
    var relay = CloudAnswerProgress(startedAt: start)
    relay.apply(.relayUnavailable, at: at(1))
    check(relay.failure == .cloudUnavailable, "Relay capacity or server failure")
    check(relay.nameLine(at: at(1)) == "接听失败", "Failure name line")

    check(!CloudAnswerFailure.androidNoAudio(callAnswered: false).endsAndroidCall, "A refused call keeps ringing on Android")
    check(CloudAnswerFailure.androidNoAudio(callAnswered: true).endsAndroidCall, "A silent answered call is hung up")
    check(CloudAnswerFailure.androidOffline.endsAndroidCall && CloudAnswerFailure.androidUnresponsive.endsAndroidCall,
          "A queued answer must not pick up the call later")
    check(CloudAnswerFailure.cloudUnreachable.endsAndroidCall && CloudAnswerFailure.cloudUnavailable.endsAndroidCall,
          "Cloud failures end on a best-effort basis")
    check(!CloudAnswerFailure.androidAnswerFailed.endsAndroidCall, "An unanswered failure sends nothing")
    check(!CloudAnswerFailure.answeredElsewhere.endsAndroidCall, "Never hang up the device that answered")
    check(!CloudAnswerFailure.answeredElsewhere.notifies && CloudAnswerFailure.cloudUnavailable.notifies,
          "Only real failures notify")
}

// Progress is for cloud answers only, and a failure ends only its own call.
do {
    func shows(bluetooth: Bool = false, cloud: Bool = true, media: Bool = true, virtual: Bool = false) -> Bool {
        CloudAnswerProgressPolicy.shows(bluetoothMode: bluetooth, cloudEnabled: cloud,
                                        hasCloudMedia: media, isVirtual: virtual)
    }
    check(shows(), "A cloud answer shows progress")
    check(!shows(cloud: false), "Cloud switched off: the push still carries media but the answer goes local")
    check(!shows(bluetooth: true), "Bluetooth mode never answers through the cloud")
    check(!shows(media: false), "A push without cloud media cannot be answered through the cloud")
    check(!shows(virtual: true), "Virtual calls show no progress")

    let failed = UUID(), other = UUID()
    func mayEnd(system: UUID?, session: UUID?) -> Bool {
        CloudAnswerProgressPolicy.mayEnd(failed: failed, systemCall: system, sessionCall: session)
    }
    check(mayEnd(system: failed, session: failed), "The failed answer ends its own call")
    check(mayEnd(system: failed, session: nil), "A cloud answer that never started still ends its system call")
    check(!mayEnd(system: other, session: nil), "Never end the next call's system screen")
    check(!mayEnd(system: nil, session: failed), "The system call already ended")
    check(!mayEnd(system: failed, session: other), "Never stop another call's media")
}

// Stage time limits.
do {
    var cloud = CloudAnswerProgress(startedAt: start)
    cloud.tick(at: at(9.9))
    check(cloud.failure == nil, "Under ten seconds keeps connecting")
    cloud.tick(at: at(10))
    check(cloud.failure == .cloudUnreachable, "Ten seconds connecting to the cloud fails")
    var offline = CloudAnswerProgress(startedAt: start)
    offline.apply(.control(status: "action_queued", role: nil), at: at(2))
    offline.tick(at: at(11.9))
    check(offline.failure == nil, "Stage clocks restart on each stage")
    offline.tick(at: at(12))
    check(offline.failure == .androidOffline, "Ten seconds waiting for Android fails")
    var silent = CloudAnswerProgress(startedAt: start)
    silent.apply(.control(status: "action_forwarded", role: nil), at: at(1))
    silent.tick(at: at(11))
    check(silent.failure == .androidUnresponsive, "Ten seconds without Android's result fails")
    var voice = CloudAnswerProgress(startedAt: start)
    voice.apply(.control(status: "answer_ok", role: nil), at: at(1))
    voice.tick(at: at(15.9))
    check(voice.failure == nil, "Voice gets fifteen seconds")
    voice.tick(at: at(16))
    check(voice.failure == .androidNoAudio(callAnswered: true), "Fifteen seconds without voice fails")
}

// A finished answer ignores every late signal.
do {
    var failed = CloudAnswerProgress(startedAt: start)
    failed.apply(.control(status: "answer_unavailable", role: nil), at: at(1))
    failed.apply(.control(status: "answer_ok", role: nil), at: at(2))
    failed.apply(.control(status: "active", role: nil), at: at(3))
    failed.apply(.control(status: "action_error", role: nil), at: at(4))
    check(failed.failure == .androidNoAudio(callAnswered: false) && failed.connectedAt == nil, "Failure is final")
    var connected = CloudAnswerProgress(startedAt: start)
    connected.apply(.control(status: "active", role: nil), at: at(1))
    connected.apply(.control(status: "ownership_lost", role: nil), at: at(2))
    connected.apply(.relayUnavailable, at: at(3))
    check(connected.failure == nil && connected.connectedAt == at(1), "Connection is final")
}

// Exact copy confirmed by the user.
do {
    let stages: [(CloudAnswerStage, String, String, String)] = [
        (.connectingCloud, "正在连接云端", "iPhone 正在连上云端", "连接云端"),
        (.waitingForAndroid, "正在等待安卓端响应", "安卓端连上云端后会立即接听", "等待安卓端"),
        (.androidAnswering, "安卓端正在接听", "接听指令已发给安卓端", "安卓端接听中"),
        (.connectingVoice, "正在接通语音", "电话已接起，马上就能说话", "接通语音中"),
    ]
    for (stage, title, detail, label) in stages {
        check(stage.title == title && stage.detail == detail && stage.shortLabel == label, "Copy for \(stage)")
    }
    check(CloudAnswerStage.connectingVoice.timeout == 15 && CloudAnswerStage.androidAnswering.timeout == 10, "Stage limits")
    let failures: [(CloudAnswerFailure, String, String?)] = [
        (.cloudUnreachable, "无法连接云端", "检查 iPhone 的网络"),
        (.cloudUnavailable, "云端暂时不可用", "稍后回拨对方"),
        (.androidOffline, "安卓端未上线", "检查安卓端的网络，确认 AirSIM 在运行"),
        (.androidUnresponsive, "安卓端没有响应", "检查安卓端的网络，确认 AirSIM 在运行"),
        (.androidNoAudio(callAnswered: false), "安卓端无法传送语音", "在安卓端启动 Shizuku 后回拨"),
        (.androidNoAudio(callAnswered: true), "安卓端无法传送语音", "在安卓端启动 Shizuku 后回拨"),
        (.androidAnswerFailed, "安卓端未能接起电话", "对方可能已挂断"),
        (.answeredElsewhere, "已在其他设备接听", nil),
    ]
    for (failure, title, advice) in failures {
        check(failure.title == title && failure.advice == advice, "Copy for \(failure)")
    }
}

// Waited time, the average and the slow notice.
do {
    let progress = CloudAnswerProgress(startedAt: start)
    check(progress.waitedText(at: at(3), average: nil) == "已等待 3 秒", "Waited without history")
    check(progress.waitedText(at: at(3), average: 2) == "已等待 3 秒 · 平均约 2 秒", "Waited with the average")
    check(progress.detail(at: at(5), average: 2) == "比平均慢，可能是网络较差", "Twice the average and five seconds is slow")
    check(progress.detail(at: at(4), average: 1) == "iPhone 正在连上云端", "Under five seconds is never slow")
    check(progress.detail(at: at(5), average: 3) == "iPhone 正在连上云端", "Not yet twice the average")
    check(progress.detail(at: at(9), average: nil) == "iPhone 正在连上云端", "No history, no slow notice")
}

do {
    let suite = "cloud-answer-progress-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    CloudAnswerDurationHistory.record(1.4, defaults: defaults)
    CloudAnswerDurationHistory.record(2.6, defaults: defaults)
    check(CloudAnswerDurationHistory.average(defaults: defaults) == nil, "Fewer than three answers show no average")
    CloudAnswerDurationHistory.record(3.0, defaults: defaults)
    check(CloudAnswerDurationHistory.average(defaults: defaults) == 2, "Average rounds to whole seconds")
    for seconds in 1...12 { CloudAnswerDurationHistory.record(Double(seconds), defaults: defaults) }
    check((defaults.array(forKey: CloudAnswerDurationHistory.key) ?? []).count == CloudAnswerDurationHistory.limit,
          "Only the latest ten answers are kept")
    check(CloudAnswerDurationHistory.average(defaults: defaults) == 8, "Average of the latest ten (3...12)")
}

print("cloud answer progress checks passed: \(assertionCount) assertions")
