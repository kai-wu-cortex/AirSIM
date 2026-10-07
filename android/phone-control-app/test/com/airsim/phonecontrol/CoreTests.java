package com.airsim.phonecontrol;

public final class CoreTests {
    public static void main(String[] args) throws Exception {
		java.net.Inet4Address loopback = (java.net.Inet4Address) java.net.InetAddress.getByName("127.0.0.1");
		try (java.net.ServerSocket occupied = new java.net.ServerSocket(0, 1, loopback);
				java.net.ServerSocket fallback = VoWLANPortBinder.bind(loopback, occupied.getLocalPort(), 2)) {
			assertTrue(fallback.getLocalPort() != occupied.getLocalPort());
			assertEquals(loopback, fallback.getInetAddress());
		}
		try (java.net.ServerSocket preferred = VoWLANPortBinder.bind(loopback, 0, 2)) {
			assertTrue(preferred.getLocalPort() >= 1024);
			assertEquals(loopback, preferred.getInetAddress());
		}
		assertEquals(AVFStartupPolicy.State.RUNNING,
				AVFStartupPolicy.assess(true, true, true, true));
		assertEquals(AVFStartupPolicy.State.READY_TO_START,
				AVFStartupPolicy.assess(true, true, true, false));
		assertEquals(AVFStartupPolicy.State.TERMINAL_DISABLED,
				AVFStartupPolicy.assess(true, true, false, false));
		assertEquals(AVFStartupPolicy.State.TERMINAL_MISSING,
				AVFStartupPolicy.assess(true, false, false, false));
		assertEquals(AVFStartupPolicy.State.AVF_UNSUPPORTED,
				AVFStartupPolicy.assess(false, false, false, false));
		assertTrue(AVFStartupPolicy.shouldPrompt(AVFStartupPolicy.State.RUNNING, false));
		assertTrue(!AVFStartupPolicy.shouldPrompt(AVFStartupPolicy.State.RUNNING, true));
		assertTrue(AVFStartupPolicy.shouldPrompt(AVFStartupPolicy.State.READY_TO_START, true));
		assertTrue(AVFStartupPolicy.isRestrictedChinaOEM("Xiaomi"));
		assertTrue(AVFStartupPolicy.isRestrictedChinaOEM("OPPO"));
		assertTrue(AVFStartupPolicy.isRestrictedChinaOEM("vivo"));
		assertTrue(AVFStartupPolicy.isRestrictedChinaOEM("HONOR"));
		assertTrue(!AVFStartupPolicy.isRestrictedChinaOEM("samsung"));
		assertEquals(
				"bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.5/install-avf.sh | sudo sh'",
				AVFStartupPolicy.installCommand());
		assertArrayEquals(new String[]{
				"android.permission.CALL_PHONE", "android.permission.POST_NOTIFICATIONS"},
				invokeMissingRuntimePermissions(36, false, false));
		assertArrayEquals(new String[]{"android.permission.CALL_PHONE"},
				invokeMissingRuntimePermissions(32, false, false));
		assertArrayEquals(new String[0], invokeMissingRuntimePermissions(36, true, true));

		java.util.Map<String, String> releaseAssets = new java.util.LinkedHashMap<>();
		releaseAssets.put("notes.txt", "https://example.test/notes.txt");
		releaseAssets.put("airsim-avf-agent_0.4.2-1_arm64.deb.sig", "https://example.test/agent.deb.sig");
		releaseAssets.put("airsim-avf-agent_0.4.2-1_arm64.deb", "https://example.test/agent.deb");
		ReleaseAssetSelector.Selection selection = ReleaseAssetSelector.select(releaseAssets);
		assertEquals("airsim-avf-agent_0.4.2-1_arm64.deb", selection.packageName());
		assertEquals("https://example.test/agent.deb", selection.packageURL());
		assertEquals("https://example.test/agent.deb.sig", selection.signatureURL());
		try {
			ReleaseAssetSelector.select(java.util.Map.of(
					"airsim-avf-agent_0.4.2-1_arm64.deb", "https://example.test/agent.deb"));
			throw new AssertionError("release without detached signature must fail");
		} catch (IllegalArgumentException expected) {
			assertContains(expected.getMessage(), "签名");
		}

		java.util.concurrent.atomic.AtomicReference<String> installerRequest = new java.util.concurrent.atomic.AtomicReference<>("");
		com.sun.net.httpserver.HttpServer installer = com.sun.net.httpserver.HttpServer.create(
				new java.net.InetSocketAddress("127.0.0.1", 0), 0);
		installer.createContext("/v1/status", exchange -> {
			installerRequest.set(exchange.getRequestMethod() + " " + exchange.getRequestHeaders().getFirst("Authorization"));
			byte[] payload = "{\"phase\":\"idle\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
			exchange.sendResponseHeaders(200, payload.length);
			try (java.io.OutputStream output = exchange.getResponseBody()) { output.write(payload); }
		});
		installer.createContext("/v1/packages/install", exchange -> {
			byte[] body = exchange.getRequestBody().readAllBytes();
			installerRequest.set(exchange.getRequestMethod() + " "
					+ exchange.getRequestHeaders().getFirst("Content-Type") + " "
					+ exchange.getRequestHeaders().getFirst("X-Airsim-Signature") + " "
					+ exchange.getRequestHeaders().getFirst("X-Airsim-Install-Mode") + " "
					+ new String(body, java.nio.charset.StandardCharsets.UTF_8));
			byte[] payload = "{\"phase\":\"completed\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
			exchange.sendResponseHeaders(200, payload.length);
			try (java.io.OutputStream output = exchange.getResponseBody()) { output.write(payload); }
		});
		installer.createContext("/v1/packages/rollback", exchange -> {
			installerRequest.set(exchange.getRequestMethod());
			exchange.sendResponseHeaders(204, -1);
			exchange.close();
		});
		installer.start();
		try {
			InstallerClient installerClient = new InstallerClient(
					"http://127.0.0.1:" + installer.getAddress().getPort(),
					"test-installer-token-1234567890");
			assertContains(installerClient.status(), "idle");
			assertEquals("GET Bearer test-installer-token-1234567890", installerRequest.get());
			assertContains(installerClient.install("deb-data".getBytes(java.nio.charset.StandardCharsets.UTF_8), "base64-signature"), "completed");
			assertEquals("POST application/vnd.debian.binary-package base64-signature normal deb-data", installerRequest.get());
			assertContains(installerClient.repair("deb-data".getBytes(java.nio.charset.StandardCharsets.UTF_8), "base64-signature"), "completed");
			assertEquals("POST application/vnd.debian.binary-package base64-signature repair deb-data", installerRequest.get());
			installerClient.rollback();
			assertEquals("POST", installerRequest.get());
		} finally {
			installer.stop(0);
		}

		com.sun.net.httpserver.HttpServer upstream = com.sun.net.httpserver.HttpServer.create(
				new java.net.InetSocketAddress("127.0.0.1", 0), 0);
		upstream.createContext("/api/calls/audio/host/warmup", exchange -> {
			byte[] payload = "{\"error\":\"当前没有进行中的通话\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
			exchange.sendResponseHeaders(409, payload.length);
			try (java.io.OutputStream output = exchange.getResponseBody()) { output.write(payload); }
		});
		upstream.createContext("/api/health", exchange -> {
			byte[] payload = "{\"ok\":true,\"product\":\"airsim\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
			exchange.sendResponseHeaders(200, payload.length);
			try (java.io.OutputStream output = exchange.getResponseBody()) { output.write(payload); }
		});
		upstream.start();
		try {
			AgentClient client = new AgentClient(
					"http://127.0.0.1:" + upstream.getAddress().getPort(), "test-token");
			assertContains(client.health(), "\"ok\":true");
			AgentClient.ForwardResponse response = client.forwardVoWLAN(
					"POST", "/api/calls/audio/host/warmup", "{}");
			assertEquals(409, response.status());
			assertContains(response.payload(), "当前没有进行中的通话");
		} finally {
			upstream.stop(0);
		}
		com.sun.net.httpserver.HttpServer otherProduct = com.sun.net.httpserver.HttpServer.create(
				new java.net.InetSocketAddress("127.0.0.1", 0), 0);
		otherProduct.createContext("/api/health", exchange -> {
			byte[] payload = "{\"ok\":true,\"version\":\"0.4.2\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
			exchange.sendResponseHeaders(200, payload.length);
			try (java.io.OutputStream output = exchange.getResponseBody()) { output.write(payload); }
		});
		otherProduct.start();
		try {
			AgentClient client = new AgentClient(
					"http://127.0.0.1:" + otherProduct.getAddress().getPort(), "test-token");
			try {
				client.health();
				throw new AssertionError("other product was mistaken for AirSIM");
			} catch (IllegalStateException expected) {
				assertContains(expected.getMessage(), "AirSIM Agent");
			}
		} finally {
			otherProduct.stop(0);
		}

		TrackingPeer failingPeer = new TrackingPeer();
		VoWLANPeerLifecycle.run(
				failingPeer,
				() -> { throw new IllegalStateException("forward failed"); },
				error -> failingPeer.writeErrorResponse());
		assertTrue(failingPeer.errorResponseWrittenWhileOpen);
		assertTrue(failingPeer.closed);

        assertEquals("dialing", TelecomStateMapper.toWireState(1));
        assertEquals("incoming", TelecomStateMapper.toWireState(2));
        assertEquals("held", TelecomStateMapper.toWireState(3));
        assertEquals("active", TelecomStateMapper.toWireState(4));
        assertEquals("ended", TelecomStateMapper.toWireState(7));
        assertEquals("unknown", TelecomStateMapper.toWireState(99));
		assertEquals("", invokeTelecomAction(() -> {}));
		assertContains(invokeTelecomAction(() -> {
			throw new SecurityException("CALL_PHONE permission required");
		}), "SecurityException: CALL_PHONE permission required");
		assertTrue(invokeSilencePolicy("remote_silent", "dialing"));
		assertTrue(invokeSilencePolicy("remote_silent", "incoming"));
		assertTrue(invokeSilencePolicy("remote_silent", "active"));
		assertTrue(invokeSilencePolicy("remote_silent", "held"));
		assertTrue(!invokeSilencePolicy("remote_silent", "ended"));
		assertTrue(!invokeSilencePolicy("local_and_push", "active"));
		assertArrayEquals(
				new String[]{"cmd", "audio", "adj-mute", "0"},
				PrivilegedBridgeProtocol.audioMuteCommand(true));
		assertArrayEquals(
				new String[]{"cmd", "audio", "adj-unmute", "0"},
				PrivilegedBridgeProtocol.audioMuteCommand(false));
		assertTrue(PrivilegedBridgeProtocol.isStreamMuted(
				"AudioManager.getStreamVolume(0) -> 0"));
		assertTrue(!PrivilegedBridgeProtocol.isStreamMuted(
				"AudioManager.getStreamVolume(0) -> 7"));
		assertTrue(PrivilegedBridgeProtocol.supportsUid(2000));
		assertTrue(PrivilegedBridgeProtocol.supportsUid(0));
		assertTrue(!PrivilegedBridgeProtocol.supportsUid(10123));
		java.util.List<String> privilegedCalls = new java.util.ArrayList<>();
		PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
		coordinator.setLocalOutputMuted(true);
		assertEquals(0, privilegedCalls.size());
		coordinator.connect(new PrivilegedBridgeCoordinator.Transport() {
			@Override public String startBridge() {
				privilegedCalls.add("start");
				return "bridge_running";
			}

			@Override public String setLocalOutputMuted(boolean muted) {
				privilegedCalls.add("mute=" + muted);
				return muted ? "muted" : "unmuted";
			}
		});
		assertEquals(java.util.List.of("start", "mute=true"), privilegedCalls);
		coordinator.setLocalOutputMuted(false);
		assertEquals(java.util.List.of("start", "mute=true", "mute=false"), privilegedCalls);
		coordinator.disconnect();
		coordinator.setLocalOutputMuted(true);
		assertEquals(3, privilegedCalls.size());

        String event = WireJson.callEvent("evt-1", "call-1", "incoming", "incoming", "+8613800138000", "remote_silent");
        assertContains(event, "\"event_id\":\"evt-1\"");
        assertContains(event, "\"number\":\"+8613800138000\"");
        assertEquals("[redacted]", DebugRedactor.safeNumber("+8613800138000"));
        assertEquals("call-1", DebugRedactor.safeIdentifier("call-1"));
        String redactedLog = DebugRedactor.sanitize(
                "Authorization: Bearer very-secret token=abc123456 number=+8613800138000 endpoint=10.177.99.25:7575");
        assertTrue(!redactedLog.contains("very-secret"));
        assertTrue(!redactedLog.contains("abc123456"));
        assertTrue(!redactedLog.contains("13800138000"));
        assertContains(redactedLog, "10.177.99.25:7575");

        AgentCommand command = AgentCommand.parse("{\"id\":\"cmd-7\",\"action\":\"answer\",\"call_id\":\"call-1\"}");
        assertEquals("cmd-7", command.id);
        assertEquals("answer", command.action);
        assertEquals("call-1", command.callId);
        assertTrue(command.isSupported());
        assertTrue(!AgentCommand.parse("{\"id\":\"x\",\"action\":\"wipe\"}").isSupported());
		AgentCommand smsCommand = AgentCommand.parse(
				"{\"id\":\"sms-7\",\"action\":\"send_sms\",\"number\":\"+8613800138000\",\"message\":\"你好\\n世界\"}");
		assertTrue(smsCommand.isSupported());
		assertEquals("+8613800138000", smsCommand.number);
		assertEquals("你好\n世界", smsCommand.message);
		assertTrue(SMSPayloadPolicy.validDestination("+86 13800138000"));
		assertTrue(!SMSPayloadPolicy.validDestination("tel:13800138000"));
		assertTrue(SMSPayloadPolicy.validBody("测试短信"));
		assertTrue(!SMSPayloadPolicy.validBody("   \n"));
		String smsEvent = WireJson.smsEvent(
				"event-7", "android-sms-7", "10010", "验证码 \"246810\"", "2026-09-23T10:20:30Z");
		assertContains(smsEvent, "\"delivery_id\":\"android-sms-7\"");
		assertContains(smsEvent, "\"content\":\"验证码 \\\"246810\\\"\"");

        assertEquals(1000L, RetryPolicy.delayMillis(0));
        assertEquals(8000L, RetryPolicy.delayMillis(3));
        assertEquals(15000L, RetryPolicy.delayMillis(20));
        assertTrue(!RecoveryPolicy.shouldAttempt(2, 0, 100_000));
        assertTrue(RecoveryPolicy.shouldAttempt(3, 0, 100_000));
        assertTrue(!RecoveryPolicy.shouldAttempt(8, 90_000, 100_000));
        assertTrue(RecoveryPolicy.shouldAttempt(8, 1_000, 400_000));
		assertEquals(1, RecoveryLaunchPolicy.backgroundActivityStartMode(35));
		assertEquals(3, RecoveryLaunchPolicy.backgroundActivityStartMode(36));
		CallEventDeduplicator deduplicator = new CallEventDeduplicator();
		assertTrue(deduplicator.shouldSend("call-1", "incoming", "incoming", "+86138"));
		assertTrue(!deduplicator.shouldSend("call-1", "incoming", "incoming", "+86138"));
		assertTrue(deduplicator.shouldSend("call-1", "incoming", "active", "+86138"));
		deduplicator.remove("call-1");
		assertTrue(deduplicator.shouldSend("call-1", "incoming", "incoming", "+86138"));

		byte[] alicePrivate = PairingCrypto.hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
		byte[] bobPublic = PairingCrypto.hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
		assertEquals("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
				PairingCrypto.hex(PairingCrypto.sharedSecret(alicePrivate, bobPublic)));
		byte[] key = PairingCrypto.deriveKey(
				PairingCrypto.hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
				"9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", "266145");
		assertEquals("a01f0098a807d3923ac6930169d7bd73ebaba0f9cb8a31381d88f576cfef7a8d", PairingCrypto.hex(key));
		byte[] sealed = PairingCrypto.hex("000102030405060708090a0b75c99492c4401dcfc20a6a6f866ccf092fef1cf95cdce42915b5d24efa51fd61134af0e9f488d4bb0bd3b1bcad3265595a84229eaa120de59e4076434505756dad54e1aa5f1ede1d30");
		assertEquals("{\"device_id\":\"device-test\",\"device_secret\":\"secret-test\"}",
				new String(PairingCrypto.open(sealed, key, "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145"), java.nio.charset.StandardCharsets.UTF_8));
		assertEquals("AAEC_v8", PairingCrypto.base64URL(PairingCrypto.hex("000102feff")));
		try {
			sealed[20] ^= 1;
			PairingCrypto.open(sealed, key, "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145");
			throw new AssertionError("altered ciphertext must fail");
		} catch (java.security.GeneralSecurityException expected) {
			// Expected authentication failure.
		}

		PairingSession session = PairingSession.create(1_000L);
		PairingCrypto.KeyMaterial client = PairingCrypto.generateKeyMaterial();
		byte[] sessionShared = PairingCrypto.sharedSecret(client.privateRaw, session.publicKey());
		byte[] sessionKey = PairingCrypto.deriveKey(sessionShared, session.id(), session.code());
		byte[] claim = PairingCrypto.seal("registration".getBytes(java.nio.charset.StandardCharsets.UTF_8), sessionKey, session.id());
		assertEquals("registration", new String(session.claim(client.publicRaw, claim, 2_000L), java.nio.charset.StandardCharsets.UTF_8));
		try {
			session.claim(client.publicRaw, claim, 2_001L);
			throw new AssertionError("pairing replay must fail");
		} catch (java.security.GeneralSecurityException expected) {
			assertContains(expected.getMessage(), "used");
		}
		PairingSession expired = PairingSession.create(1_000L);
		try {
			expired.claim(client.publicRaw, claim, 121_001L);
			throw new AssertionError("expired pairing must fail");
		} catch (java.security.GeneralSecurityException expected) {
			assertContains(expected.getMessage(), "expired");
		}
		assertTrue(session.code().matches("[0-9]{6}"));
		assertEquals(121_000L, session.expiresAtMillis());
		assertEquals("http://172.29.240.25:8575", AVFNetworkPolicy.agentEndpoint("172.29.240.24"));
		assertEquals("http://10.185.5.25:8575", AVFNetworkPolicy.agentEndpoint("10.185.5.63"));
		assertEquals("http://172.29.240.25:8576", AVFNetworkPolicy.installerEndpoint("172.29.240.24"));
		assertEquals("http://10.185.5.25:8576", AVFNetworkPolicy.installerEndpoint("10.185.5.63"));
		assertEquals("", AVFNetworkPolicy.agentEndpoint("192.168.2.86"));
		assertTrue(AVFNetworkPolicy.isAgentEndpoint("http://172.29.240.25:8575"));
		assertTrue(AVFNetworkPolicy.isInstallerEndpoint("http://172.29.240.25:8576"));
		assertEquals("http://172.29.240.25:8576",
				AVFNetworkPolicy.installerEndpointForAgent("http://172.29.240.25:8575"));
		assertEquals("", AVFNetworkPolicy.installerEndpointForAgent("http://192.168.2.86:8575"));
		assertTrue(!AVFNetworkPolicy.isInstallerEndpoint("http://172.29.240.25:8575"));
		assertTrue(AVFNetworkPolicy.isAgentEndpoint("http://10.185.5.25:8575"));
		assertTrue(!AVFNetworkPolicy.isAgentEndpoint("http://10.185.5.25:7575"));
		assertTrue(!AVFNetworkPolicy.isAgentEndpoint("http://192.168.2.86:8575"));
		assertTrue(!AVFNetworkPolicy.isAgentEndpoint("https://172.29.240.25:8575"));
		byte[] vowlanSecret = PairingCrypto.hex(
				"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
		String vowlanCanonical = VoWLANAuth.canonicalRequest(
				"GET", "/v1/health", new byte[0], 1789090000L, "nonce-1");
		assertEquals("GET\n/v1/health\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n1789090000\nnonce-1",
				vowlanCanonical);
		assertEquals("xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE",
				VoWLANAuth.sign(vowlanSecret, vowlanCanonical));
		assertTrue(VoWLANAuth.verify(vowlanSecret,
				"xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE",
				vowlanCanonical, 1789090000L, 1789090001L));
		assertTrue(!VoWLANAuth.verify(vowlanSecret,
				"xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE",
				vowlanCanonical, 1789090000L, 1789090040L));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/health"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/v1/health"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/calls/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/calls/events?after=1"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/answer"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/audio/host/register"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/push/register"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/push/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/sms"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/sms/status"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/sms/send"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/sms/ack"));
		assertTrue(!VoWLANControlPolicy.allowed("POST", "/api/at"));
		assertTrue(!VoWLANControlPolicy.allowed("POST", "/api/system/update"));
		VoWLANReplayCache replayCache = new VoWLANReplayCache(30);
		assertTrue(replayCache.accept("nonce-1", 1_000L));
		assertTrue(!replayCache.accept("nonce-1", 1_001L));
		assertTrue(replayCache.accept("nonce-1", 1_031L));
		VoWLANPCMProtocol.Preface pcmPreface = VoWLANPCMProtocol.parse(
				"AIRSIMVWL1 1789090000 nonce-1 xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE\n");
		assertEquals(1789090000L, pcmPreface.timestamp());
		assertEquals("nonce-1", pcmPreface.nonce());
		assertEquals("xyJYZyGVDVSARzo3dd9vM_luQBhKeneDd6vk2VWmIkE", pcmPreface.signature());
		assertEquals("PCM\n/v1/pcm\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n1789090000\nnonce-1",
				VoWLANPCMProtocol.canonical(pcmPreface));
		assertTrue(invokePCMReadyHandshake(new java.io.ByteArrayInputStream(
				"AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII))));
		assertTrue(!invokePCMReadyHandshake(new java.io.ByteArrayInputStream(
				"AIRSIMFAIL!".getBytes(java.nio.charset.StandardCharsets.US_ASCII))));
		VoWLANPCMProtocol.SessionGate pcmGate = new VoWLANPCMProtocol.SessionGate();
		assertTrue(pcmGate.tryAcquire("paired-peer"));
		assertTrue(!pcmGate.tryAcquire("second-peer"));
		pcmGate.release("second-peer");
		assertTrue(!pcmGate.tryAcquire("second-peer"));
		pcmGate.release("paired-peer");
		assertTrue(pcmGate.tryAcquire("second-peer"));
		assertTrue(VoWLANNetworkPolicy.isHotspotInterface("swlan0", "10.172.46.225"));
		assertTrue(VoWLANNetworkPolicy.isHotspotInterface("ap0", "192.168.43.1"));
		assertTrue(!VoWLANNetworkPolicy.isHotspotInterface("wlan0", "192.168.2.86"));
		assertTrue(!VoWLANNetworkPolicy.isHotspotInterface("swlan0", "8.8.8.8"));
		assertTrue(VoWLANNetworkPolicy.isVoWLANInterface("wlan0", "192.168.31.203"));
		assertTrue(VoWLANNetworkPolicy.isVoWLANInterface("swlan0", "10.172.46.225"));
		assertTrue(!VoWLANNetworkPolicy.isVoWLANInterface("avf_tap_fixed", "10.177.99.12"));
		assertTrue(!VoWLANNetworkPolicy.isVoWLANInterface("rmnet0", "10.20.30.40"));
		assertTrue(VoWLANNetworkPolicy.shouldAdvertise(true, true, true, true, true));
		assertTrue(!VoWLANNetworkPolicy.shouldAdvertise(true, true, false, true, true));
		assertTrue(!VoWLANNetworkPolicy.shouldAdvertise(true, true, true, true, false));
		assertTrue(TelecomRolePolicy.canExecuteCallCommand(true, "dial"));
		assertTrue(TelecomRolePolicy.canExecuteCallCommand(true, "end"));
		assertTrue(!TelecomRolePolicy.canExecuteCallCommand(false, "dial"));
		assertTrue(!TelecomRolePolicy.canExecuteCallCommand(false, "end"));
		assertTrue(TelecomRolePolicy.requiresDialerRole("dial"));
		assertTrue(TelecomRolePolicy.requiresDialerRole("end"));
		assertTrue(!TelecomRolePolicy.requiresDialerRole("send_sms"));
		assertEquals("266 145", MainScreenPresentation.formatPairingCode("266145"));
		assertEquals(
				"22:45 VoWLAN 健康检查通过\n22:43 VoWLAN 广播已发现",
				MainScreenPresentation.recentLogLines(
						"22:42 Agent 心跳正常\n22:43 VoWLAN 广播已发现\n22:44 PCM bridge ready\n22:45 VoWLAN 健康检查通过",
						"VoWLAN",
						2));
		assertEquals("Linux Agent 状态接口返回 HTTP 200",
				MainScreenPresentation.activitySummary(
						"2026-09-25T10:11:12Z http_request_finished method=GET path=/api/android/status status=200"));
		assertEquals("VoWLAN 配对完成",
				MainScreenPresentation.activitySummary("pairing_completed peer=iphone"));
		assertEquals("Shizuku PCM 桥已连接",
				MainScreenPresentation.activitySummary("shizuku_user_service_connected uid=2000"));
		assertEquals("Agent 守护服务已启动",
				MainScreenPresentation.activitySummary("watchdog_created"));
		assertEquals("VoWLAN 服务已启动",
				MainScreenPresentation.activitySummary("vowlan_service_created"));
		assertEquals("vowlan_state", MainScreenPresentation.activitySummary(
				"vowlan_state paired=true agent_ready=false pcm_ready=true"));
		assertEquals("unrecognized",
				MainScreenPresentation.activitySummary("unrecognized verbose internal entry"));
		String detailed = "2026-10-07T10:11:12Z ERROR [pool-1] "
				+ "http_request_failed method=GET path=/api/android/status duration_ms=3002 error=SocketTimeoutException";
		assertEquals("2026-10-07T10:11:12Z · ERROR · [pool-1]",
				MainScreenPresentation.logMetadata(detailed));
		assertEquals("http_request_failed method=GET path=/api/android/status duration_ms=3002 error=SocketTimeoutException",
				MainScreenPresentation.eventBody(detailed));
		assertTrue(MainScreenPresentation.isErrorLog(detailed));
		assertEquals("plain log entry", MainScreenPresentation.eventBody("plain log entry"));
		assertEquals("VoWLAN 模式", MainScreenPresentation.connectionModeTitle(
				true, true, true, ""));
		assertEquals("云端模式", MainScreenPresentation.connectionModeTitle(
				false, true, true, ""));
		assertEquals("云端链路异常", MainScreenPresentation.connectionModeTitle(
				false, true, true, "推送中继返回 HTTP 401"));
		assertEquals("云端 Relay 已配置，等待 Agent 心跳验证",
				MainScreenPresentation.connectionModeDetail(false, true, true, ""));
		assertEquals("vowlan_state paired=true pcm_ready=false",
				MainScreenPresentation.latestContaining(
						"push_status ok=true\nvowlan_state paired=true pcm_ready=false",
						"vowlan_state"));
		assertEquals("shizuku_binder_dead\npcm_probe_failed port=7580",
				MainScreenPresentation.recentMatchingLogLines(
						"push_status ok=true\npcm_probe_failed port=7580\nshizuku_binder_dead",
						3, "pcm", "shizuku"));
        System.out.println("phone-control core tests passed");
    }

    private static void assertContains(String value, String expected) {
        if (!value.contains(expected)) throw new AssertionError(value + " missing " + expected);
    }

    private static void assertEquals(Object expected, Object actual) {
        if (!expected.equals(actual)) throw new AssertionError("expected=" + expected + " actual=" + actual);
    }

    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }

	private static void assertArrayEquals(String[] expected, String[] actual) {
		if (!java.util.Arrays.equals(expected, actual)) {
			throw new AssertionError("expected=" + java.util.Arrays.toString(expected)
					+ " actual=" + java.util.Arrays.toString(actual));
		}
	}

	private static boolean invokeSilencePolicy(String mode, String state) throws Exception {
		try {
			return (boolean) TelecomStateMapper.class
					.getMethod("shouldSilenceLocalOutput", String.class, String.class)
					.invoke(null, mode, state);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("remote_silent local-output policy is missing", error);
		}
	}

	private static boolean invokePCMReadyHandshake(java.io.InputStream input) throws Exception {
		try {
			return (boolean) VoWLANPCMProtocol.class
					.getDeclaredMethod("acceptReady", java.io.InputStream.class)
					.invoke(null, input);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("PCM relay does not read the complete AIRSIMREADY frame", error);
		}
	}

	private static String[] invokeMissingRuntimePermissions(
			int sdk, boolean callPhoneGranted, boolean notificationsGranted) throws Exception {
		try {
			Class<?> policy = Class.forName("com.airsim.phonecontrol.RuntimePermissionPolicy");
			return (String[]) policy.getDeclaredMethod(
					"missingPermissions", int.class, boolean.class, boolean.class)
					.invoke(null, sdk, callPhoneGranted, notificationsGranted);
		} catch (ClassNotFoundException error) {
			throw new AssertionError("CALL_PHONE runtime permission policy is missing", error);
		}
	}

	private static String invokeTelecomAction(Runnable action) throws Exception {
		try {
			Class<?> invocation = Class.forName("com.airsim.phonecontrol.TelecomInvocation");
			java.util.concurrent.Executor direct = Runnable::run;
			return (String) invocation.getDeclaredMethod(
					"run", java.util.concurrent.Executor.class, Runnable.class, long.class)
					.invoke(null, direct, action, 1_000L);
		} catch (ClassNotFoundException error) {
			throw new AssertionError("Telecom runtime failures are not captured", error);
		}
	}

	private static final class TrackingPeer implements java.io.Closeable {
		boolean closed;
		boolean errorResponseWrittenWhileOpen;

		void writeErrorResponse() {
			errorResponseWrittenWhileOpen = !closed;
		}

		@Override public void close() {
			closed = true;
		}
	}
}
