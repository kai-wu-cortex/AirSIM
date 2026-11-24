#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import json,sys
r,o=map(Path,sys.argv[1:]);cases=json.loads((r/'tests/caller-number-cases.json').read_text())
source = (r/'iOS/AirSIM/APIModels.swift').read_text()
(o/'Models.swift').write_text('import Foundation\n'+source[source.index('struct CallRecord:'):source.index('struct CallStatus:')])
(o/'main.swift').write_text('''import Foundation
let cases = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for pair in cases {
    precondition(CallerNumber.display(pair[0]) == pair[1], "caller projection failed: \\(pair[0])")
    precondition(CallerNumber.display(CallerNumber.display(pair[0])) == pair[1], "not idempotent")
}
let original = CallRecord(id: "call-a", index: 3, direction: "incoming", state: "incoming",
    number: "sip:%2B8613800138000@ims.example;user=phone", startedAt: Date(), updatedAt: Date(),
    endedAt: nil, missed: false, androidID: "android-a", sourceAgentID: "agent-a", sourceCallID: "source-a", slotIndex: 1)
let decoded = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(original))
precondition(decoded.number == "+8613800138000")
precondition(decoded.id == original.id && decoded.androidID == original.androidID && decoded.sourceAgentID == original.sourceAgentID && decoded.sourceCallID == original.sourceCallID && decoded.slotIndex == 1 && decoded.state == original.state)
let roundtrip = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(decoded))
precondition(roundtrip == decoded)
precondition(CallerNumber.matching("sip:alice123@ims460.example").isEmpty)
print("Swift caller-number cases passed: \\(cases.count)")
''')
rows='\n'.join('check('+json.dumps(a)+','+json.dumps(b)+');' for a,b in cases)
(o/'CallerNumberTest.java').write_text('''import com.airsim.phonecontrol.CallerNumber;
public class CallerNumberTest {
 static void check(String a,String b) {if(!CallerNumber.display(a).equals(b) || !CallerNumber.display(CallerNumber.display(a)).equals(b)) throw new AssertionError(a);}
 public static void main(String[] args) {'''+rows+'''System.out.println("Java caller-number cases passed");}}
''')
PY
xcrun swiftc "$ROOT/iOS/Shared/CallerNumber.swift" "$OUT/Models.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check" "$ROOT/tests/caller-number-cases.json"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
"$TASK_JAVA_HOME/bin/javac" -d "$OUT" "$ROOT/android/phone-control-app/src/com/airsim/phonecontrol/CallerNumber.java" "$OUT/CallerNumberTest.java"
"$TASK_JAVA_HOME/bin/java" -cp "$OUT" CallerNumberTest
