import Foundation

struct PureLocalSnapshot: Codable, Equatable, Sendable {
    enum Intent: String, Codable { case enabled, exiting }
    struct Peer: Codable, Equatable, Sendable {
        var command: PureLocalCommand?
        var lastStatus: PureLocalStatus?
        var locallyOverridden = false
    }
    var version = 1
    var priorMode: String
    var priorCloud: Bool
    var intent: Intent = .enabled
    var peers: [String: Peer] = [:]
}

enum PureLocalModePolicy {
    struct State: Equatable, Sendable {
        var snapshot: PureLocalSnapshot?
        var corrupt = false
        var boundAgentID: String?
        var localDrained = false
        var freshPeerStatus: PureLocalStatus?
        var blocksRelay: Bool { corrupt || snapshot != nil }
        var currentPeer: PureLocalSnapshot.Peer? { boundAgentID.flatMap { snapshot?.peers[$0] } }
        var peerExited: Bool { currentPeer?.locallyOverridden == true }
        var maySynchronize: Bool { snapshot != nil && !corrupt && !peerExited }
        var isConfirmed: Bool {
            guard localDrained, snapshot?.intent == .enabled, !peerExited, let status = freshPeerStatus,
                  status.agentID == boundAgentID, status.enabled, status.drained, !status.avfRequired || status.avfConfirmed,
                  let command = currentPeer?.command else { return false }
            return status.lastOperationID == command.operationID && status.ownerFingerprint == command.ownerFingerprint && status.revision == command.expectedRevision + 1
        }
        var readyToRestore: Bool {
            guard snapshot?.intent == .exiting, !corrupt else { return false }
            if boundAgentID == nil { return snapshot?.peers.isEmpty == true }
            guard let status = freshPeerStatus, status.agentID == boundAgentID, !status.enabled, status.drained,
                  !status.avfRequired || status.avfConfirmed else { return false }
            if peerExited { return true }
            guard let command = currentPeer?.command, !command.enabled else { return false }
            return status.lastOperationID == command.operationID && status.ownerFingerprint == command.ownerFingerprint && status.revision == command.expectedRevision + 1
        }
    }
    enum Event {
        case enter(mode: String, cloud: Bool, callActive: Bool)
        case exit(callActive: Bool)
        case bind(String?)
        case drained
        case operation(PureLocalCommand)
        /// Only authenticated status (WLAN HMAC or authenticated BLE envelope) enters the reducer.
        case ack(PureLocalStatus)
        case disconnected
        case resynchronize
    }
    static func restore(_ data: Data?) -> State {
        guard let data else { return State() }
        guard let snapshot = try? JSONDecoder().decode(PureLocalSnapshot.self, from: data), snapshot.version == 1,
              ["automatic", "cloud", "vowlan", "bluetooth", "localDual"].contains(snapshot.priorMode),
              snapshot.peers.allSatisfy({ id, peer in
                  PureLocalCommand.validID(id) && (peer.command == nil || (try? peer.command?.verify(agentID: id)) != nil) &&
                  (peer.lastStatus == nil || (peer.lastStatus?.valid == true && peer.lastStatus?.agentID == id))
              }) else { return State(corrupt: true) }
        // A persisted ACK is historical, not proof of a live peer after restarting.
        return State(snapshot: snapshot)
    }
    static func reduce(state: State, event: Event) -> State {
        var next = state
        switch event {
        case let .enter(mode, cloud, active):
            guard !active, !state.blocksRelay else { return state }
            next.snapshot = PureLocalSnapshot(priorMode: mode, priorCloud: cloud)
        case let .exit(active):
            guard !active, !state.corrupt, state.snapshot != nil else { return state }
            next.snapshot?.intent = .exiting
            next.freshPeerStatus = nil
        case let .bind(agentID):
            if agentID != state.boundAgentID { next.boundAgentID = agentID; next.freshPeerStatus = nil }
        case .drained: next.localDrained = true
        case let .operation(command):
            guard state.maySynchronize, command.agentID == state.boundAgentID, (try? command.verify(agentID: command.agentID)) != nil,
                  command.enabled == (state.snapshot?.intent == .enabled) else { return state }
            var peer = state.currentPeer ?? PureLocalSnapshot.Peer()
            peer.command = command
            next.snapshot?.peers[command.agentID] = peer
            next.freshPeerStatus = nil
        case let .ack(status):
            guard status.valid, status.agentID == state.boundAgentID, var peer = state.currentPeer,
                  let command = peer.command, status.ownerFingerprint == command.ownerFingerprint,
                  status.revision >= (peer.lastStatus?.revision ?? 0) else { return state }
            if status.source == "android_local", !status.enabled, status.revision > command.expectedRevision {
                peer.locallyOverridden = true
            } else {
                guard !peer.locallyOverridden, status.lastOperationID == command.operationID,
                      status.enabled == command.enabled, status.revision == command.expectedRevision + 1 else { return state }
            }
            peer.lastStatus = status
            next.snapshot?.peers[status.agentID] = peer
            next.freshPeerStatus = status
        case .disconnected: next.freshPeerStatus = nil
        case .resynchronize:
            guard let id = state.boundAgentID, !state.corrupt else { return state }
            next.snapshot?.peers[id]?.locallyOverridden = false
            next.freshPeerStatus = nil
        }
        return next
    }
}
