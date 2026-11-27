#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-sms-feedback.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PYCODE'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'AirSIM/SMSConversationPresentation.swift').read_text()
(out/'Feedback.swift').write_text('import Foundation\n'+s[s.index('struct SMSSubmissionFeedback:'):])
PYCODE
cat > "$OUT/main.swift" <<'SWIFT'
import Foundation
let start = Date(timeIntervalSince1970: 1_000)
let unknown = SMSSubmissionFeedback.make(detail: "SMS submission not confirmed; check recipient before retrying; no automatic resend", recipient: "10010", startedAt: start, now: start.addingTimeInterval(70))
precondition(unknown.kind == .uncertain && unknown.remainingSeconds(at: start.addingTimeInterval(70)) == 50)
precondition(unknown.isVisible(for: "10086", at: start.addingTimeInterval(70)))
let blocked = SMSSubmissionFeedback.make(detail: "previous SMS outcome unknown; check recipient before retrying after two minutes", recipient: "10010", startedAt: start.addingTimeInterval(80), now: start.addingTimeInterval(81), previous: unknown)
precondition(blocked.retryAfter == unknown.retryAfter, "Repeated errors must not extend a known deadline")
precondition(unknown.remainingSeconds(at: start.addingTimeInterval(121)) == 0)
precondition(unknown.kind == .uncertain && unknown.isVisible(for: "10010", at: start.addingTimeInterval(121)))
precondition(!unknown.isVisible(for: "10086", at: start.addingTimeInterval(121)))
let android = SMSSubmissionFeedback.make(detail: "短信发送结果尚未确认", recipient: "10010", startedAt: start, now: start)
precondition(android.kind == .uncertain && android.retryAfter == nil)
let legacy = SMSSubmissionFeedback.make(detail: "previous SMS outcome unknown; check recipient before retrying after two minutes", recipient: "10010", startedAt: start, now: start)
precondition(legacy.remainingSeconds(at: start) == 120 && legacy.message.contains("不会自动重发"))
let error = SMSSubmissionFeedback.make(detail: "unexpected transport error", recipient: "10010", startedAt: start, now: start)
precondition(error.message.contains("草稿已保留") && !error.message.contains("transport") && error.retryAfter == nil)
print("PASS: SMS protection deadlines, Android compatibility, Chinese feedback")
SWIFT
xcrun swiftc "$OUT/Feedback.swift" "$OUT/main.swift" -o "$OUT/tests"
"$OUT/tests"
