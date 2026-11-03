#!/usr/bin/env python3
"""Run production Foundation/CryptoKit call policies without an iOS test host.
Only declaration slices are selected; their implementations are not rewritten.
UIKit audio, CallKit and the live backend still require separate integration tests.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[3]
def source(name): return (root / 'iOS/AirSIM' / name).read_text()
def between(text, start, end): return text[text.index(start):text.index(end, text.index(start))]
models = source('APIModels.swift'); app = source('AppModel.swift'); auth = source('VoWLANAuth.swift')
parts = ['import Foundation\nimport CryptoKit\nimport Security\n',
 between(models, 'struct CallRecord:', '/// Agent 的统一事件快照'),
 models[models.index('struct EarlyMediaGrant:'):],
 between(models, 'struct SMSStatus:', 'struct SMSSendResult:'),
 source('CallLifecycleStore.swift'),
 between(auth, 'struct VoWLANCredential:', 'enum VoWLANCredentialStore'),
 between(auth, 'enum VoWLANHealthProof', '/// Client-side pairing list.'),
 auth[auth.index('private extension Data'):],
 between(app, 'protocol LegacyAgentPolling:', 'extension AirSIMAPI: LegacyAgentPolling'),
 between(app, 'struct LegacyAgentPollResult:', 'enum AgentEventCursor'),
 between(app, 'protocol OutgoingCallServicing:', 'extension AirSIMAPI: OutgoingCallServicing'),
 '@MainActor\n' + between(app, 'enum OutgoingCallCoordinator', 'enum AgentPollingRouteSelector'),
 'enum CloudCommandError: Error { case cloudModeDisabled }\n']
if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix='airsim-r18-tests-') as tmp:
        production = Path(tmp)/'Production.swift'; production.write_text('\n'.join(parts))
        binary = Path(tmp)/'tests'
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(production),str(Path(__file__).with_name('Tests.swift')),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
