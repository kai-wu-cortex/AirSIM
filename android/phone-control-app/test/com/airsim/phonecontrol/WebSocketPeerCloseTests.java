package com.airsim.phonecontrol;

public final class WebSocketPeerCloseTests {
    private static void check(boolean ok) { if (!ok) throw new AssertionError(); }
    private static void invalid(byte[] b) throws Exception {
        try { WebSocketPeerClose.decode(b); throw new AssertionError("invalid close accepted"); }
        catch (java.io.IOException expected) {}
    }
    public static void main(String[] args) throws Exception {
        check(WebSocketPeerClose.decode(new byte[0]).code()==1005);
        check(WebSocketPeerClose.decode(new byte[]{3,(byte)232}).category().equals("normal"));
        var replaced = WebSocketPeerClose.decode(new byte[]{15,(byte)161,'s','e','c','r','e','t'});
        check(replaced.code()==4001 && replaced.category().equals("replaced"));
        check(!replaced.toString().contains("secret"));
        invalid(new byte[]{3}); invalid(new byte[]{3,(byte)237});
        invalid(new byte[]{3,(byte)232,(byte)0xc0,(byte)0x80});
        invalid(new byte[]{0,1}); invalid(new byte[126]);
        System.out.println("WebSocket close tests passed");
    }
}
