#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-voble-recovery.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root/'AirSIM/VoBLECallCoordinator.swift').read_text()
s = s.replace('extension VoBLECentralController: VoBLECallControlling {}', '')
(out/'Coordinator.swift').write_text(s)
models = (root/'AirSIM/VoBLECentralController.swift').read_text()
models = models[models.index('struct VoBLEControlResponse:'):models.index('struct VoBLEAndroidSMS:')]
lifecycle = (root/'AirSIM/CallLifecycleStore.swift').read_text()
models += lifecycle[lifecycle.index('enum CallLifecycleState:'):lifecycle.index('enum CallLifecycleSource:')]
registry = (root/'AirSIM/DeviceCallRegistry.swift').read_text()
models += registry[registry.index('struct DeviceCallEvent:'):registry.index('enum DeviceCallEffect:')]
policy = (root/'AirSIM/DeviceCallActionRouter.swift').read_text()
models += policy[policy.index('enum BluetoothIncomingCallPolicy {'):]
(out/'Models.swift').write_text('import Foundation\n' + models)
PY
# Production coordinator + identity policy; Bluetooth/audio/diagnostics are fakes.
# This does not exercise a real radio, microphone, CallKit, or carrier call.
xcrun swiftc -parse-as-library -module-cache-path "$OUT/cache" "$OUT/Models.swift" "$OUT/Coordinator.swift" \
  "$ROOT/VoBLERecoverySmoke/Fixtures.swift" "$ROOT/VoBLERecoverySmoke/Checks.swift" -o "$OUT/checks"
"$OUT/checks"
