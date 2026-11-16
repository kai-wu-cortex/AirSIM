package com.airsim.phonecontrol;
import java.util.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;
import android.telecom.Call;

/** Production auth, grant issuance and native identity; only Agent/Android boundaries replaced. */
public final class WatchDirectGatewayTests {
    static int checks;
    static final android.content.Context context = new android.content.Context();
    static final byte[] root = new byte[32], key = WatchMediaGrant.controlKey(root);
    static String agent;
    static void check(boolean result, String message) { checks++; if (!result) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        JSONObject vector = new JSONObject(java.nio.file.Files.readString(java.nio.file.Path.of(args[0])));
        byte[] fixtureRoot = java.util.HexFormat.of().parseHex(vector.getString("root_hex"));
        byte[] fixtureControl = WatchMediaGrant.controlKey(fixtureRoot);
        check(java.util.HexFormat.of().formatHex(fixtureControl).equals(vector.getString("control_hex")), "control vector");
        byte[] media = WatchMediaGrant.mediaKey(fixtureControl, vector.getString("grant"));
        check(java.util.HexFormat.of().formatHex(media).equals(vector.getString("media_hex")), "media vector");
        check(VoWLANAuth.sign(media, vector.getString("pcm_canonical")).equals(vector.getString("pcm_signature")), "PCM vector");
        check(VoWLANAuth.sign(fixtureControl, WatchMediaGrant.responseCanonical("fixture-nonce",200,vector.getString("response_payload")))
                .equals(vector.getString("response_signature")), "response vector");
        agent = AndroidAgentIdentity.agentID(context);
        Call call = new Call(Call.STATE_RINGING, Call.Details.DIRECTION_INCOMING, "5550100");
        String nativeID = CallRepository.add(call);
        JSONObject tuple = new JSONObject().put("agent_id",agent).put("call_id","call-A")
                .put("call_uuid","11111111-1111-4111-8111-111111111111").put("generation",7);
        AgentClient.transport = (method,path,body) -> {
            JSONObject input = new JSONObject(body);
            boolean matches = input.optString("call_id").equals("call-A") && input.optLong("generation")==7
                && input.optString("call_uuid").equals(tuple.optString("call_uuid"));
            return new AgentClient.ForwardResponse(matches?200:409, new JSONObject().put("active",
                new JSONObject().put("android_id",nativeID).put("id","backend-A").put("direction","incoming")).toString());
        };
        try {
            check(request("status",tuple, key, "2",200).getString("state").equals("incoming"), "ringing status");
            request("status",tuple, root,"2",401);
            request("status",tuple,key,"1",401);
            request("dial",tuple,key,"2",404);
            for (String field : new String[]{"agent_id","call_id","call_uuid","generation"}) {
                JSONObject changed = new JSONObject(tuple.toString()); changed.put(field, field.equals("generation")?8:"wrong");
                request("answer",changed,key,"2",409);
            }
            JSONObject stringGeneration = new JSONObject(tuple.toString()).put("generation","7");
            request("answer",stringGeneration,key,"2",409);
            check(call.getState()==Call.STATE_RINGING,"bad identities cannot answer");
            JSONObject answer = request("answer",tuple,key,"2",200);
            String grant = answer.getString("grant");
            check(call.getState()==Call.STATE_ACTIVE,"exact incoming answered");
            check(grant.equals(request("answer",tuple,key,"2",200).getString("grant")),"retry reuses grant");
            long now = System.currentTimeMillis()/1000L;
            WatchMediaGrant issued = WatchMediaSessions.media(context,grant,now,true);
            check(issued!=null,"issued active grant attaches");
            check(WatchMediaSessions.media(context,grant+"x",now,true)==null,"tampering rejected");
            check(WatchMediaSessions.media(context,grant,issued.expiresAt,true)==null,"expired attach rejected");
            check(WatchMediaSessions.media(context,grant,issued.expiresAt,false)!=null,"attached call survives attach expiry");
            for (int index=0;index<6;index++) {
                check(!issued.permits(index==0?"other":issued.owner,index==1?"other":issued.agent,index==2?"other":issued.call,
                    index==3?"other":issued.uuid,index==4?8:issued.generation,index==5?"other":issued.instance,now,true),"grant binds every identity field");
            }
            StandaloneCloudMediaManager.identityCurrent=false;
            request("status",tuple,key,"2",409);
            request("hangup",tuple,key,"2",409);
            check(call.getState()==Call.STATE_ACTIVE,"changed live tuple cannot control native call");
            StandaloneCloudMediaManager.identityCurrent=true;
            VoWLANPairingStore.paired=false;
            check(WatchMediaSessions.media(context,grant,now,false)==null,"unpair revokes active media");
            request("status",tuple,key,"2",401);
            VoWLANPairingStore.paired=true;
            check(WatchMediaSessions.media(context,grant,now,true)==null,"readding parent cannot resurrect revoked grant");
            request("hangup",tuple,key,"2",200);
            check(call.getState()==Call.STATE_DISCONNECTED,"exact hangup");
            Call newer = new Call(Call.STATE_ACTIVE); CallRepository.add(newer);
            try {
                check(request("status",tuple,key,"2",200).getString("state").equals("ended"),"old terminal remains exact");
                request("hangup",tuple,key,"2",200);
                check(newer.getState()==Call.STATE_ACTIVE,"late hangup cannot end new call");
                check(WatchMediaSessions.media(context,grant,now,true)==null,"terminal grant never attaches to next call");
            } finally { CallRepository.remove(newer); }
        } finally { VoWLANPairingStore.paired=true; CallRepository.remove(call); }
        System.out.println("WatchDirectGatewayTests: " + checks + " checks passed");
    }
    static JSONObject request(String action, JSONObject input, byte[] signingKey,String version,int expected) throws Exception {
        String path="/api/watch/"+action, nonce=UUID.randomUUID().toString(); long now=System.currentTimeMillis()/1000L;
        byte[] body=input.toString().getBytes(StandardCharsets.UTF_8);
        Map<String,String> headers=new HashMap<>(); headers.put("x-airsim-watch-control",version);
        headers.put("x-airsim-vowlan-version","1"); headers.put("x-airsim-vowlan-timestamp",String.valueOf(now)); headers.put("x-airsim-vowlan-nonce",nonce);
        headers.put("x-airsim-vowlan-signature",VoWLANAuth.sign(signingKey,VoWLANAuth.canonicalRequest("POST",path,body,now,nonce)));
        var reply=WatchDirectGateway.handle(context,"POST",path,headers,body);
        check(reply.status()==expected,"unexpected status for "+action+": "+reply.status()+" expected "+expected);
        if(expected==401 || expected==404) return new JSONObject();
        JSONObject envelope=new JSONObject(reply.body()); String payload=envelope.getString("payload");
        check(envelope.getString("proof").equals(VoWLANAuth.sign(key,WatchMediaGrant.responseCanonical(nonce,reply.status(),payload))),"response authenticated");
        check(WatchDirectGateway.handle(context,"POST",path,headers,body).status()==401,"replay rejected");
        return new JSONObject(new String(WatchMediaGrant.decode(payload),StandardCharsets.UTF_8));
    }
}
