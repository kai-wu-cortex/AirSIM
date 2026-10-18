package com.airsim.phonecontrol;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Strict RFC 6455 close parsing; never retain peer-supplied reason text. */
final class WebSocketPeerClose extends IOException {
    private final int code;
    private WebSocketPeerClose(int code) { super("WebSocket close " + code); this.code = code; }
    int code() { return code; }
    String category() {
        if (code == 4001) return "replaced";
        if (code == 1000 || code == 1001 || code == 1005) return "normal";
        if (code == 1002 || code == 1003 || code == 1007 || code == 1008 || code == 1009) return "protocol";
        return "remote_error";
    }
    static WebSocketPeerClose decode(byte[] payload) throws IOException {
        if (payload.length == 0) return new WebSocketPeerClose(1005);
        if (payload.length == 1 || payload.length > 125) throw new IOException("Invalid close length");
        int code = ((payload[0] & 255) << 8) | (payload[1] & 255);
        if (!((code >= 1000 && code <= 1014 && code != 1004 && code != 1005 && code != 1006)
                || (code >= 3000 && code <= 4999))) throw new IOException("Invalid close code");
        StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(payload, 2, payload.length - 2));
        return new WebSocketPeerClose(code);
    }
}
