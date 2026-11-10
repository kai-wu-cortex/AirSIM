package com.airsim.phonecontrol;

import java.net.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Real authenticated HTTP ingress and receipt producer, with only external Agent I/O replaced. */
public final class OwnedDialGatewayTests {
    public static void main(String[] args) throws Exception {
        Throwable first = null;
        try { delayedPublicationStillReturnsOwnedReceipt(); }
        catch (Throwable failure) { first = failure; failure.printStackTrace(); }
        try { unpublishedCallNeverReturnsUnownedSuccess(); }
        catch (Throwable failure) { if (first == null) first = failure; failure.printStackTrace(); }
        if (first != null) throw new AssertionError("owned dial regressions failed", first);
        System.out.println("OwnedDialGatewayTests passed");
    }
    private static void unpublishedCallNeverReturnsUnownedSuccess() throws Exception {
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING,
                android.telecom.Call.Details.DIRECTION_OUTGOING, "5550100");
        int[] dials = {0};
        AgentClient.transport = (method, path, body) -> {
            if (path.equals("/api/calls/dial")) {
                dials[0]++;
                CallRepository.add(call);
                return new AgentClient.ForwardResponse(200, "{\"dialing\":true}");
            }
            return new AgentClient.ForwardResponse(200, "{\"active\":{\"android_id\":\"unrelated\",\"id\":\"other-backend\"}}");
        };
        try (var gateway = new VoWLANControlGateway(new android.content.Context())) {
            int port = gateway.start((Inet4Address) InetAddress.getByName("127.0.0.1"), 0);
            JSONObject result = request(port, "never-published", 504);
            check(result.optString("error").equals("owned_dial_receipt_unavailable"), "timeout must not masquerade as unsupported peer");
            check(dials[0] == 1, "an uncertain dial must never be repeated");
            check(call.getState() == android.telecom.Call.STATE_DISCONNECTED, "receipt timeout must retire only the exact created call");
            var replacement = new android.telecom.Call(android.telecom.Call.STATE_ACTIVE);
            String replacementID = CallRepository.add(replacement);
            try {
                var lease = DirectCallOwnership.begin("127.0.0.1");
                DirectCallOwnership.record("127.0.0.1", replacementID, lease);
                DirectCallOwnership.pcmReady(lease);
                check(RemoteCallAudioScope.SHARED.owns(java.util.List.of(replacementID)),
                        "receipt timeout must not poison the next call's PCM ownership");
            } finally { CallRepository.remove(replacement); }
        } finally {
            DirectCallOwnership.end(DirectCallOwnership.capture("127.0.0.1"), false);
            CallRepository.remove(call);
        }
    }
    private static void delayedPublicationStillReturnsOwnedReceipt() throws Exception {
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING,
                android.telecom.Call.Details.DIRECTION_OUTGOING, "5550100");
        String[] created = {""};
        int[] reads = {0}, dials = {0};
        AgentClient.transport = (method, path, body) -> {
            if (path.equals("/api/calls/dial")) {
                dials[0]++;
                created[0] = CallRepository.add(call);
                return new AgentClient.ForwardResponse(200, "{\"dialing\":true}");
            }
            if (path.equals("/api/calls/status")) {
                // Telecom exists immediately; the independent Agent queue has not
                // published it yet. An older active call is not this operation.
                reads[0]++;
                String id = reads[0] < 3 ? "previous-call" : created[0];
                return new AgentClient.ForwardResponse(200, new JSONObject().put("active",
                    new JSONObject().put("android_id", id).put("id", "backend-" + id)).toString());
            }
            throw new AssertionError("unexpected Agent path " + path);
        };
        try (var gateway = new VoWLANControlGateway(new android.content.Context())) {
            int port = gateway.start((Inet4Address) InetAddress.getByName("127.0.0.1"), 0);
            JSONObject receipt = request(port, "delayed-publication");
            check(receipt.optString("operation_id").equals("operation-A"), "successful dial returned no owned operation receipt");
            check(receipt.optString("android_id").equals(created[0]), "receipt must name the newly created Telecom call");
            check(receipt.optString("backend_id").equals("backend-" + created[0]), "receipt must wait for this call's backend mapping");
            String canonical = "AIRSIM-DIAL1\ndelayed-publication\noperation-A\n" + created[0] + "\nbackend-" + created[0];
            check(VoWLANAuth.sign(new byte[32], canonical).equals(receipt.optString("operation_proof")), "receipt signature must bind exact operation and identities");
            check(dials[0] == 1, "waiting for publication must never redial");
            check(gateway.ownsCall(), "authenticated live dial must retain gateway ownership");
            call.setStateForTest(android.telecom.Call.STATE_DISCONNECTED);
            check(!gateway.ownsCall(), "remote hangup must clear ownership without a local hangup request");
            var unrelated = new android.telecom.Call(android.telecom.Call.STATE_ACTIVE);
            CallRepository.add(unrelated);
            try { check(!gateway.ownsCall(), "an unrelated active call cannot revive the old owner"); }
            finally { CallRepository.remove(unrelated); }

        } finally {
            DirectCallOwnership.end(DirectCallOwnership.capture("127.0.0.1"), false);
            CallRepository.remove(call);
        }
    }
    private static JSONObject request(int port, String nonce) throws Exception {
        return request(port, nonce, 200);
    }
    private static JSONObject request(int port, String nonce, int expectedStatus) throws Exception {
        String body = "{\"number\":\"5550100\",\"operation_id\":\"operation-A\"}";
        byte[] payload = body.getBytes(StandardCharsets.UTF_8);
        long timestamp = System.currentTimeMillis() / 1000;
        String signature = VoWLANAuth.sign(new byte[32], VoWLANAuth.canonicalRequest(
                "POST", "/api/calls/dial", payload, timestamp, nonce));
        try (Socket peer = new Socket("127.0.0.1", port)) {
            peer.setSoTimeout(5000);
            String headers = "POST /api/calls/dial HTTP/1.1\r\nHost: localhost\r\nContent-Length: " + payload.length
                + "\r\nX-AirSIM-VoWLAN-Version: 1\r\nX-AirSIM-VoWLAN-Timestamp: " + timestamp
                + "\r\nX-AirSIM-VoWLAN-Nonce: " + nonce + "\r\nX-AirSIM-VoWLAN-Signature: " + signature + "\r\n\r\n";
            peer.getOutputStream().write(headers.getBytes(StandardCharsets.US_ASCII));
            peer.getOutputStream().write(payload); peer.getOutputStream().flush();
            String response = new String(peer.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            check(response.startsWith("HTTP/1.1 " + expectedStatus + " "), "unexpected HTTP result: " + response);
            return new JSONObject(response.substring(response.indexOf("\r\n\r\n") + 4));
        }
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
