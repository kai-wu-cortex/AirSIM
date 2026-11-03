package com.airsim.phonecontrol;

public final class CoreTests {
    public static void main(String[] args) throws Exception {
        byte[] routeSecret = new byte[32];
        for (int index = 0; index < routeSecret.length; index++) routeSecret[index] = (byte) index;
        assertEquals("hQLACWxrSaTjg3tib03xCffgi2LQfdBAV_HLMPmj3hI",
                DirectGatewayRoutes.proof(routeSecret, "session-1", "client-key", "agent-1", 7592, 7593));
        DirectGatewayRoutes routes = new DirectGatewayRoutes();
        routes.put("127.0.0.1", 7592, 7593);
        assertEquals(7593, routes.forHost("127.0.0.1").pcmPort());
        assertTrue(routes.forHost("192.168.1.2") == null);
        routes.remove("127.0.0.1");
        assertTrue(routes.forHost("127.0.0.1") == null);
        assertTrue(VoWLANNetworkPolicy.isOverlayInterface("tun0", "100.64.1.2"));
        assertTrue(!VoWLANNetworkPolicy.isOverlayInterface("rmnet0", "100.64.1.2"));
        assertTrue(!VoWLANNetworkPolicy.isOverlayInterface("tun0", "100.128.1.2"));
        assertTrue(!VoWLANNetworkPolicy.isOverlayInterface("tun0", "8.8.8.8"));
        assertTrue(VoWLANNetworkPolicy.permitsPeer("127.0.0.1", "127.0.0.1"));
        assertTrue(VoWLANNetworkPolicy.permitsPeer("100.64.1.3", "100.100.1.2"));
        assertTrue(VoWLANNetworkPolicy.permitsPeer("192.168.1.3", "192.168.1.2"));
        assertTrue(VoWLANNetworkPolicy.permitsPeer("100.64.1.3", "192.168.1.2"));
        assertTrue(!VoWLANNetworkPolicy.permitsPeer("8.8.8.8", "127.0.0.1"));
        assertTrue(!VoWLANNetworkPolicy.permitsPeer("100.64.1.3", "8.8.8.8"));
        assertTrue(!VoWLANNetworkPolicy.permitsPeer("192.168.1..3", "192.168.1.2"));
        assertTrue(!VoWLANNetworkPolicy.permitsPeer("010.0.0.1", "192.168.1.2"));
        assertTrue(!VoWLANNetworkPolicy.permitsPairingPeer("100.64.1.3", "100.64.1.2", "rmnet0"));
        assertTrue(VoWLANNetworkPolicy.permitsPairingPeer("100.64.1.3", "100.64.1.2", "tun0"));
        assertTrue(VoWLANNetworkPolicy.permitsPairingPeer("127.0.0.1", "127.0.0.1", "lo"));
        android.content.Context versionContext = new android.content.Context();
        android.content.pm.PackageInfo versionInfo = new android.content.pm.PackageInfo();
        versionInfo.versionName = "1.2.3";
        versionInfo.versionCode = 456;
        versionContext.getPackageManager().info = versionInfo;
        assertEquals("1.2.3 (456)", AppInformation.version(versionContext));
        assertEquals(456, AppInformation.privilegedServiceVersion(versionContext));
        versionInfo.versionCode = 457;
        assertEquals(457, AppInformation.privilegedServiceVersion(versionContext));
        versionInfo.versionCode = 0;
        assertTrue(AppInformation.privilegedServiceVersion(versionContext) > 9);
        versionInfo.versionCode = 456;
        versionInfo.versionName = null;
        assertEquals("未知版本 (456)", AppInformation.version(versionContext));
        versionContext.getPackageManager().info = null;
        assertTrue(AppInformation.privilegedServiceVersion(versionContext) > 9);
        assertEquals("未知版本", AppInformation.version(versionContext));
        assertEquals("https://github.com/kai-wu-cortex/AirSIM/releases", AppInformation.RELEASES_URL);
		assertCrashReportIsSanitizedBoundedAndPersisted();
		assertCrashSharePayloadRequiresAReportAndSanitizesRecentLogs();
		assertVoBLEAudioVectorAndBounds();
		assertVoBLEPairingAndReplay();
		assertVoBLEControlOwnershipAndCallDeduplication();
		assertVoBLEHangupAfterTerminalEventIsIdempotentAndCannotEndNextCall();
		assertVoBLERevocationClosesOnlyOwnedTransport();
		assertVoBLEPCMResolutionHandshakeAndMediaCrypto();
		assertTransientMuteFailureRetriesAndRestorationCancelsStaleRetry();
		assertMutedCallRecoversAfterThreeTransientAudioFailures();
		assertLiveStatusPollerUpdatesWithoutRebuildingPage();
		assertLiveStatusPollerRecoversAfterOneFailedRead();
		assertLiveStatusPollerRetriesFailedRender();
		assertPCMBridgeRunningUsesPrivilegedProcessStatus();
		assertPrivilegedBridgeStatusRefreshTracksProcessExit();
		assertMuteResultDoesNotHideRunningPCMBridge();
		assertVoWLANFailedRejectPreservesCallOwnership();
		assertVoWLANClosedSocketStopsAcceptLoop();
		assertVoWLANIOExceptionStopsAcceptLoop();
		assertTrue(invokeIsStaleAudioBridge(
				11_414, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
						"--listen-port", "7580", "")));
		assertTrue(!invokeIsStaleAudioBridge(
				27_671, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
						"--listen-port", "7580", "")));
		assertTrue(!invokeIsStaleAudioBridge(
				11_415, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.example.UnrelatedService", "--listen-host", "127.0.0.1",
						"--listen-port", "7580", "")));
		assertTrue(!invokeIsStaleAudioBridge(
				11_416, 27_671,
				String.join("\0", "/system/bin/app_process", "/system/bin",
						"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
						"--listen-port", "7581", "")));
		String bridgeCommand = String.join("\0", "/system/bin/app_process", "/system/bin",
				"com.airsim.bridge.PhoneAudioBridge", "--listen-host", "127.0.0.1",
				"--listen-port", "7580", "");
		assertTrue(!invokeIsStaleAudioBridgeForPackage(11_417, 27_671, bridgeCommand,
				"CLASSPATH=/data/app/~~x/com.airsim.phonecontrol-y/base.apk\0",
				"com.airsim.phonecontrol.standalone"));
		assertTrue(invokeIsStaleAudioBridgeForPackage(11_418, 27_671, bridgeCommand,
				"CLASSPATH=/data/app/~~x/com.airsim.phonecontrol.standalone-y/base.apk\0",
				"com.airsim.phonecontrol.standalone"));
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
				"bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'",
				AVFStartupPolicy.installCommand());
		assertArrayEquals(new String[]{
				"android.permission.CALL_PHONE", "android.permission.SEND_SMS", "android.permission.RECEIVE_SMS",
				"android.permission.POST_NOTIFICATIONS"},
				invokeMissingRuntimePermissions(36, false, false, false));
		assertArrayEquals(new String[]{"android.permission.CALL_PHONE", "android.permission.SEND_SMS", "android.permission.RECEIVE_SMS"},
				invokeMissingRuntimePermissions(32, false, false, false));
		assertArrayEquals(new String[]{"android.permission.SEND_SMS", "android.permission.RECEIVE_SMS"},
				invokeMissingRuntimePermissions(36, true, false, true));
		assertArrayEquals(new String[0], invokeMissingRuntimePermissions(36, true, true, true));
		assertArrayEquals(new String[]{"android.permission.RECEIVE_SMS"},
				RuntimePermissionPolicy.missingPermissions(36, true, true, false, true, true, true));
		assertArrayEquals(new String[]{"android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH_ADVERTISE"},
				RuntimePermissionPolicy.missingPermissions(
						36, true, true, true, true, true, true, false, false));
		assertArrayEquals(new String[0], RuntimePermissionPolicy.missingPermissions(
				30, true, true, true, true, true, true, false, false));
		assertArrayEquals(new String[]{"android.permission.READ_SMS"},
				invokeOptionalInboxPermissions(false, false));
		assertArrayEquals(new String[0], invokeOptionalInboxPermissions(true, false));
		assertArrayEquals(new String[0], invokeOptionalInboxPermissions(false, true));
		String expectedSMSID = "android-sms-56ade2bc830c126252281aee319d5eda590b56518ebcbec623697999554c5b00";
		assertEquals(expectedSMSID, invokeSMSIdentity("+8613800000000", "验证码 123456", 1_000L));
		assertTrue(!expectedSMSID.equals(invokeSMSIdentity("+8613800000000", "验证码 123456", 2_000L)));
		assertEquals(1_000L, invokeProviderTimestamp(1_000L, 1_100L));
		assertEquals(1_100L, invokeProviderTimestamp(0L, 1_100L));
		assertRecentSMSIDsRetainBoundedDeliveryHistory();
		assertInboxCursorBaselinesExistingMessagesAndRetriesFailures();

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

			@Override public String status() {
				return "pcm=running";
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
		java.util.concurrent.atomic.AtomicInteger telecomRuns = new java.util.concurrent.atomic.AtomicInteger();
		java.util.concurrent.atomic.AtomicInteger smsRuns = new java.util.concurrent.atomic.AtomicInteger();
		AgentCommandDispatcher.Result smsResult = AgentCommandDispatcher.execute(
				smsCommand, false,
				ignored -> {
					telecomRuns.incrementAndGet();
					return AgentCommandDispatcher.Result.success(0);
				},
				ignored -> {
					smsRuns.incrementAndGet();
					return AgentCommandDispatcher.Result.success(2);
				});
		assertTrue(smsResult.success());
		assertEquals(2, smsResult.segments());
		assertEquals(0, telecomRuns.get());
		assertEquals(1, smsRuns.get());
		assertTrue(SMSPayloadPolicy.validDestination("+86 13800138000"));
		assertTrue(!SMSPayloadPolicy.validDestination("tel:13800138000"));
		assertTrue(SMSPayloadPolicy.validBody("测试短信"));
		assertTrue(!SMSPayloadPolicy.validBody("   \n"));
		SMSConfirmation confirmation = new SMSConfirmation(2);
		confirmation.record(0, -1);
		confirmation.record(0, -1);
		SMSConfirmation.Outcome partialSMS = confirmation.await(1);
		assertTrue(!partialSMS.complete());
		assertEquals(1, invokeConfirmedSMSSegments(partialSMS));
		confirmation.record(1, -1);
		assertTrue(confirmation.await(1).success());
		assertEquals(2, invokeConfirmedSMSSegments(confirmation.await(1)));
		SMSConfirmation failedConfirmation = new SMSConfirmation(1);
		failedConfirmation.record(0, 2);
		assertEquals(2, failedConfirmation.await(1).errorCode());
		SMSConfirmation failedMultipart = new SMSConfirmation(2);
		failedMultipart.record(0, 2);
		SMSConfirmation.Outcome failedEarly = failedMultipart.await(1);
		assertTrue(failedEarly.complete());
		assertTrue(!failedEarly.success());
		assertEquals(2, failedEarly.errorCode());
		SMSConfirmation cancelledConfirmation = new SMSConfirmation(1);
		cancelledConfirmation.record(0, 0);
		assertTrue(!cancelledConfirmation.await(1).success());
		String smsEvent = WireJson.smsEvent(
				"event-7", "android-sms-7", "10010", "验证码 \"246810\"", "2026-09-23T10:20:30Z");
		assertContains(smsEvent, "\"delivery_id\":\"android-sms-7\"");
		assertContains(smsEvent, "\"content\":\"验证码 \\\"246810\\\"\"");
		assertContains(WireJson.smsEvent("event-8", "android-sms-8", "  ",
				"运营商提醒", "2026-10-12T06:00:00Z"), "\"sender\":\"未知号码\"");

        assertEquals(1000L, RetryPolicy.delayMillis(0));
        assertEquals(8000L, RetryPolicy.delayMillis(3));
        assertEquals(15000L, RetryPolicy.delayMillis(20));
		assertRelayServerFailuresBackOffWithoutDelayingTransportRecovery();
        assertTrue(CommandPollingPolicy.shouldPoll(false, 0, 1_000));
        assertTrue(!CommandPollingPolicy.shouldPoll(false, 1_000, 10_000));
        assertTrue(CommandPollingPolicy.shouldPoll(false, 1_000, 16_000));
        assertTrue(!CommandPollingPolicy.shouldPoll(true, 1_000, 16_000));
        assertTrue(CommandPollingPolicy.shouldPoll(false, 16_000, 1_000));
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
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/debug?after=0&limit=600"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/calls/events?after=1"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/answer"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/calls/audio/host/register"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/push/register"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/push/mode"));
		assertTrue(!VoWLANControlPolicy.allowed("GET", "/api/push/mode"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/push/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/sms"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/sms/status"));
		assertTrue(VoWLANControlPolicy.allowed("GET", "/api/local-mode"));
		assertTrue(VoWLANControlPolicy.allowed("POST", "/api/local-mode"));
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
		StandaloneLongPoll.Request eventWait = StandaloneLongPoll.parse(
				"/api/events?after=7&timeout_ms=15000", 15_000);
		assertEquals(7L, eventWait.after());
		assertEquals(15_000, eventWait.timeoutMillis());
		assertEquals(0L, StandaloneLongPoll.parse("/api/events", 15_000).after());
		assertEquals(25_000, StandaloneLongPoll.parse(
				"/api/calls/events?after=0", 25_000).timeoutMillis());
		try {
			StandaloneLongPoll.parse("/api/events?after=0&timeout_ms=99", 15_000);
			throw new AssertionError("too-short event timeout must fail");
		} catch (IllegalArgumentException expected) {
			assertContains(expected.getMessage(), "timeout_ms");
		}
		StandaloneLongPoll cursor = new StandaloneLongPoll();
		java.util.concurrent.ExecutorService eventExecutor = java.util.concurrent.Executors.newSingleThreadExecutor();
		try {
			java.util.concurrent.Future<Long> waiting = eventExecutor.submit(() -> cursor.awaitChange(0, 2_000));
			long waitDeadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(1);
			while (!waiting.isDone() && cursor.waiterCount() == 0 && System.nanoTime() < waitDeadline) {
				Thread.onSpinWait();
			}
			assertEquals(1, cursor.waiterCount());
			assertEquals(1L, cursor.advance());
			assertEquals(1L, waiting.get(1, java.util.concurrent.TimeUnit.SECONDS));
		} finally {
			eventExecutor.shutdownNow();
		}
		assertTrue(TelecomRolePolicy.canExecuteCallCommand(true, "dial"));
		assertTrue(TelecomRolePolicy.canExecuteCallCommand(true, "end"));
		assertTrue(!TelecomRolePolicy.canExecuteCallCommand(false, "dial"));
		assertTrue(!TelecomRolePolicy.canExecuteCallCommand(false, "end"));
		assertTrue(TelecomRolePolicy.requiresDialerRole("dial"));
		assertTrue(TelecomRolePolicy.requiresDialerRole("end"));
		assertTrue(!TelecomRolePolicy.requiresDialerRole("send_sms"));
		assertEquals(DialerRoleSetupPolicy.Action.COMPLETE,
				DialerRoleSetupPolicy.initial(true, false));
		assertEquals(DialerRoleSetupPolicy.Action.SHIZUKU,
				DialerRoleSetupPolicy.initial(false, true));
		assertEquals(DialerRoleSetupPolicy.Action.SYSTEM_ROLE,
				DialerRoleSetupPolicy.initial(false, false));
		assertEquals(DialerRoleSetupPolicy.Action.COMPLETE,
				DialerRoleSetupPolicy.afterSystemRequest(true, false));
		assertEquals(DialerRoleSetupPolicy.Action.SHIZUKU,
				DialerRoleSetupPolicy.afterSystemRequest(false, true));
		assertEquals(DialerRoleSetupPolicy.Action.SETTINGS,
				DialerRoleSetupPolicy.afterSystemRequest(false, false));
		assertEquals(DialerRoleSetupPolicy.Action.COMPLETE,
				DialerRoleSetupPolicy.afterPrivilegedAttempt(true));
		assertEquals(DialerRoleSetupPolicy.Action.SETTINGS,
				DialerRoleSetupPolicy.afterPrivilegedAttempt(false));
		assertArrayEquals(new String[]{"cmd", "role", "add-role-holder",
				"android.app.role.DIALER", "com.airsim.phonecontrol.standalone"},
				PrivilegedBridgeProtocol.dialerRoleGrantCommand(
						"com.airsim.phonecontrol.standalone"));
		assertArrayEquals(new String[]{"cmd", "role", "get-role-holders",
				"android.app.role.DIALER"}, PrivilegedBridgeProtocol.dialerRoleQueryCommand());
		assertTrue(PrivilegedBridgeProtocol.isDialerRoleHolder(
				"com.android.contacts\ncom.airsim.phonecontrol.standalone\n",
				"com.airsim.phonecontrol.standalone"));
		assertTrue(!PrivilegedBridgeProtocol.isDialerRoleHolder(
				"com.airsim.phonecontrol.standalone.debug\n",
				"com.airsim.phonecontrol.standalone"));
		try {
			PrivilegedBridgeProtocol.dialerRoleGrantCommand("com.airsim;id");
			throw new AssertionError("unsafe package name must fail");
		} catch (IllegalArgumentException expected) {
			assertContains(expected.getMessage(), "package");
		}
		assertEquals("266 145", MainScreenPresentation.formatPairingCode("266145"));
		assertEquals("等待 iPhone 发起首次配对",
				MainScreenPresentation.voBLEAuthenticationStatus(false, false, ""));
		assertEquals("请在两端核对安全码",
				MainScreenPresentation.voBLEAuthenticationStatus(false, false, "266145"));
		assertEquals("已认证并连接",
				MainScreenPresentation.voBLEAuthenticationStatus(true, true, ""));
		assertEquals("266 145", MainScreenPresentation.voBLEPairingCode("266145"));
		assertEquals("等待 iPhone 发起配对", MainScreenPresentation.voBLEPairingCode(""));
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

	private static void assertRelayServerFailuresBackOffWithoutDelayingTransportRecovery() throws Exception {
		Throwable serverFailure = new RelayHTTPException(500, "relay internal error");
		assertEquals(500, RelayHTTPException.fromHandshakeStatusLine(
				"HTTP/1.1 500 Internal Server Error").statusCode());
		assertEquals(15_000L, RelayRetryPolicy.delayMillis(1, serverFailure));
		assertEquals(30_000L, RelayRetryPolicy.delayMillis(2, serverFailure));
		assertEquals(60_000L, RelayRetryPolicy.delayMillis(3, serverFailure));
		assertEquals(300_000L, RelayRetryPolicy.delayMillis(7, serverFailure));
		assertEquals(300_000L, RelayRetryPolicy.delayMillis(100, serverFailure));
		assertEquals(30_000L, RelayRetryPolicy.delayMillis(2,
				new RelayHTTPException(429, "rate limited")));
		assertEquals(2_000L, RelayRetryPolicy.delayMillis(2,
				new java.io.IOException("temporary network failure")));
	}

	private static void assertVoBLEAudioVectorAndBounds() {
		byte[] tag = new byte[16];
		java.util.Arrays.fill(tag, (byte) 0xa5);
		com.airsim.phonecontrol.voble.VoBLEProtocol.AudioPacket packet =
				new com.airsim.phonecontrol.voble.VoBLEProtocol.AudioPacket(
						0, com.airsim.phonecontrol.voble.VoBLEProtocol.CODEC_G711_MULAW, 7,
						0x01020304L, 0x05060708L,
						new byte[]{0x00, 0x7f, (byte) 0x80, (byte) 0xff}, tag);
		for (int maximumPacketLength : new int[]{23, 185, 247}) {
			java.util.List<byte[]> fragments =
					com.airsim.phonecontrol.voble.VoBLEProtocol.encodeAudioFragments(
							packet, maximumPacketLength);
			assertTrue(fragments.stream().allMatch(value -> value.length <= maximumPacketLength));
			byte[] first = fragments.get(0);
			assertTrue(java.util.Arrays.equals(
					new byte[]{1, 2, 3, 4}, java.util.Arrays.copyOfRange(first, 7, 11)));
			assertTrue(java.util.Arrays.equals(
					new byte[]{5, 6, 7, 8}, java.util.Arrays.copyOfRange(first, 11, 15)));
			com.airsim.phonecontrol.voble.VoBLEProtocol.AudioReassembler reassembler =
					new com.airsim.phonecontrol.voble.VoBLEProtocol.AudioReassembler();
			com.airsim.phonecontrol.voble.VoBLEProtocol.AudioPacket decoded = null;
			for (byte[] fragment : fragments) {
				com.airsim.phonecontrol.voble.VoBLEProtocol.AudioPacket next =
						reassembler.append(fragment, 10_000L);
				if (next != null) decoded = next;
			}
			assertEquals(packet, decoded);
		}
		byte[] expectedVector = new byte[]{
				(byte) 0xa5, 0x5a, 0x01, 0x01, 0x00, 0x01, 0x07,
				0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
				0x00, 0x01, 0x14, 0x00, 0x7f, (byte) 0x80, (byte) 0xff,
				(byte) 0xa5, (byte) 0xa5, (byte) 0xa5, (byte) 0xa5,
				(byte) 0xa5, (byte) 0xa5, (byte) 0xa5, (byte) 0xa5,
				(byte) 0xa5, (byte) 0xa5, (byte) 0xa5, (byte) 0xa5,
				(byte) 0xa5, (byte) 0xa5, (byte) 0xa5, (byte) 0xa5};
		assertTrue(java.util.Arrays.equals(expectedVector,
				com.airsim.phonecontrol.voble.VoBLEProtocol
						.encodeAudioFragments(packet, 247).get(0)));

		com.airsim.phonecontrol.voble.VoBLEAudioQueue queue =
				new com.airsim.phonecontrol.voble.VoBLEAudioQueue(8);
		for (int sequence = 1; sequence <= 9; sequence++) {
			queue.offer(sequence, new byte[]{(byte) sequence});
		}
		assertEquals(8, queue.size());
		assertEquals(2L, queue.poll().sequence());
		assertEquals(1L, queue.droppedFrames());
		assertTrue(queue.consumeDiscontinuity());
		assertTrue(!queue.consumeDiscontinuity());

		com.airsim.phonecontrol.voble.VoBLEProtocol.ControlEnvelope control =
				new com.airsim.phonecontrol.voble.VoBLEProtocol.ControlEnvelope(
						"answer", "call-7", 0x0102030405060708L,
						new byte[]{1, 2, 3, 4}, new byte[12], new byte[]{6, 7, 8}, new byte[16]);
		byte[] encodedControl = com.airsim.phonecontrol.voble.VoBLEProtocol.encodeControl(control);
		assertTrue(java.util.Arrays.equals(
				new byte[]{1, 2, 3, 4, 5, 6, 7, 8},
				java.util.Arrays.copyOfRange(encodedControl, 4, 12)));
		assertEquals(control, com.airsim.phonecontrol.voble.VoBLEProtocol.decodeControl(encodedControl));
		for (int maximumPacketLength : new int[]{23, 185, 247}) {
			var fragments = com.airsim.phonecontrol.voble.VoBLEProtocol.encodeMessageFragments(
					encodedControl, maximumPacketLength,
					com.airsim.phonecontrol.voble.VoBLEProtocol.MESSAGE_CONTROL, 0x1234);
			assertTrue(fragments.stream().allMatch(value -> value.length <= maximumPacketLength));
			var reassembler = new com.airsim.phonecontrol.voble.VoBLEProtocol.MessageReassembler();
			com.airsim.phonecontrol.voble.VoBLEProtocol.Message decoded = null;
			for (byte[] fragment : fragments) {
				var next = reassembler.append(fragment, 10_000L);
				if (next != null) decoded = next;
			}
			assertEquals(0x1234, decoded.messageId());
			assertTrue(java.util.Arrays.equals(encodedControl, decoded.payload()));
		}
	}

	private static void assertVoBLEPairingAndReplay() throws Exception {
		byte[] androidPrivate = new byte[32];
		byte[] iphonePrivate = new byte[32];
		for (int index = 0; index < 32; index++) {
			androidPrivate[index] = (byte) (index + 1);
			iphonePrivate[index] = (byte) (index + 33);
		}
		byte[] androidPublic = com.airsim.phonecontrol.voble.VoBLEPairingManager
				.publicKey(androidPrivate);
		byte[] iphonePublic = com.airsim.phonecontrol.voble.VoBLEPairingManager
				.publicKey(iphonePrivate);
		com.airsim.phonecontrol.voble.VoBLEPairingManager.Transcript transcript =
				new com.airsim.phonecontrol.voble.VoBLEPairingManager.Transcript(
						"samsung-test", androidPublic, iphonePublic,
						filledBytes(32, 0x11), filledBytes(32, 0x22));
		com.airsim.phonecontrol.voble.VoBLEPairingManager.PairingMaterial android =
				com.airsim.phonecontrol.voble.VoBLEPairingManager.derivePairing(
						androidPrivate, iphonePublic, transcript);
		com.airsim.phonecontrol.voble.VoBLEPairingManager.PairingMaterial iphone =
				com.airsim.phonecontrol.voble.VoBLEPairingManager.derivePairing(
						iphonePrivate, androidPublic, transcript);
		assertTrue(java.util.Arrays.equals(android.pairingKey(), iphone.pairingKey()));
		assertEquals("41cef6294f3575441997664149bd8a014c8db026ad3a5312410be90f7d76c48a",
				PairingCrypto.hex(android.pairingKey()));
		assertEquals("922247", android.sas());
		assertEquals("a09d46e2afc3444bffc9013831d265c7", PairingCrypto.hex(
				com.airsim.phonecontrol.voble.VoBLEPairingManager.reconnectTag(
						android.pairingKey(), transcript)));
		assertEquals(16, com.airsim.phonecontrol.voble.VoBLEPairingManager.confirmationTag(
				android.pairingKey(), "challenge-1").length);
		com.airsim.phonecontrol.voble.VoBLEPairingManager.Transcript modified =
				new com.airsim.phonecontrol.voble.VoBLEPairingManager.Transcript(
						"samsung-modified", androidPublic, iphonePublic,
						filledBytes(32, 0x11), filledBytes(32, 0x22));
		assertTrue(!java.util.Arrays.equals(android.pairingKey(),
				com.airsim.phonecontrol.voble.VoBLEPairingManager.derivePairing(
						androidPrivate, iphonePublic, modified).pairingKey()));

		com.airsim.phonecontrol.voble.VoBLEPairingManager.SessionKeys first =
				com.airsim.phonecontrol.voble.VoBLEPairingManager.deriveSessionKeys(
						android.pairingKey(), filledBytes(16, 3), "call-1", 1);
		com.airsim.phonecontrol.voble.VoBLEPairingManager.SessionKeys reconnect =
				com.airsim.phonecontrol.voble.VoBLEPairingManager.deriveSessionKeys(
						android.pairingKey(), filledBytes(16, 4), "call-1", 1);
		assertTrue(!java.util.Arrays.equals(first.control(), first.media()));
		assertTrue(!java.util.Arrays.equals(first.media(), first.reconnect()));
		assertTrue(!java.util.Arrays.equals(first.control(), reconnect.control()));
		assertEquals(32, com.airsim.phonecontrol.voble.VoBLEPairingManager.deriveSessionKeys(
				android.pairingKey(), filledBytes(16, 5), "", 0).control().length);
		byte[] authenticatedMessage = "authenticated-control".getBytes(
				java.nio.charset.StandardCharsets.UTF_8);
		byte[] controlTag = com.airsim.phonecontrol.voble.VoBLEPairingManager
				.authenticationTag(authenticatedMessage, first.control());
		assertTrue(com.airsim.phonecontrol.voble.VoBLEPairingManager.authenticateTag(
				authenticatedMessage, controlTag, first.control()));
		assertTrue(!com.airsim.phonecontrol.voble.VoBLEPairingManager.authenticateTag(
				authenticatedMessage, controlTag, new byte[32]));

		com.airsim.phonecontrol.voble.VoBLEReplayWindow window =
				new com.airsim.phonecontrol.voble.VoBLEReplayWindow(30_000L, 4);
		assertTrue(window.accept(new byte[]{1}, 100_000L, 100_000L));
		assertTrue(!window.accept(new byte[]{1}, 100_000L, 100_000L));
		assertTrue(!window.accept(new byte[]{2}, 69_999L, 100_000L));
		window.revoke();
		assertTrue(!window.accept(new byte[]{3}, 100_000L, 100_000L));

		java.util.Map<String, String> protectedValues = new java.util.HashMap<>();
		com.airsim.phonecontrol.voble.VoBLECredentialStore store =
				new com.airsim.phonecontrol.voble.VoBLECredentialStore(
						new com.airsim.phonecontrol.voble.VoBLECredentialStore.ProtectedBackend() {
							@Override public String load(String key) { return protectedValues.get(key); }
							@Override public void save(String key, String value) { protectedValues.put(key, value); }
							@Override public void remove(String key) { protectedValues.remove(key); }
						});
		store.save("samsung-test", android.pairingKey());
		assertTrue(store.hasCredential("samsung-test"));
		com.airsim.phonecontrol.voble.VoBLEPairingManager manager =
				new com.airsim.phonecontrol.voble.VoBLEPairingManager(store);
		long now = 1_000_000L;
		var challenge = manager.begin("samsung-new", now);
		var preview = manager.preview(
				challenge.id(), iphonePublic, filledBytes(32, 0x22), now);
		assertEquals(preview.sas(), manager.confirm(
				challenge.id(), iphonePublic, filledBytes(32, 0x22), preview.sas(), now).sas());
		assertTrue(store.load("samsung-new") != null);

		var reconnectChallenge = manager.begin("samsung-new", now + 1);
		var reconnectTranscript = new com.airsim.phonecontrol.voble.VoBLEPairingManager.Transcript(
				reconnectChallenge.androidIdentity(), reconnectChallenge.androidPublicKey(),
				iphonePublic, reconnectChallenge.androidNonce(), filledBytes(32, 0x33));
		byte[] oldPairingKey = store.load("samsung-new");
		var reconnected = manager.confirmReconnect(
				reconnectChallenge.id(), iphonePublic, filledBytes(32, 0x33),
				com.airsim.phonecontrol.voble.VoBLEPairingManager.reconnectTag(
						oldPairingKey, reconnectTranscript), now + 1);
		assertTrue(!java.util.Arrays.equals(oldPairingKey, reconnected.pairingKey()));
		manager.revoke("samsung-test");
		assertTrue(!store.hasCredential("samsung-test"));
		assertTrue(store.load("samsung-test") == null);
	}

	private static void assertVoBLERevocationClosesOnlyOwnedTransport() {
		var channel = new com.airsim.phonecontrol.voble.VoBLEControlChannel();
		var disconnects = new java.util.concurrent.atomic.AtomicInteger();
		channel.subscribeControl("owner");
		channel.subscribeAudio("owner");
		assertTrue(channel.authenticate("owner"));
		assertTrue(!channel.revokeOwnerAndDisconnect("other", disconnects::incrementAndGet));
		assertTrue(disconnects.get() == 0);
		assertTrue(channel.revokeOwnerAndDisconnect("owner", disconnects::incrementAndGet));
		assertTrue(disconnects.get() == 1);
		assertTrue(!channel.isControlSubscribed("owner"));
		assertTrue(!channel.isAudioSubscribed("owner"));
		assertTrue(!channel.revokeOwnerAndDisconnect("owner", disconnects::incrementAndGet));
		assertTrue(disconnects.get() == 1);
	}

	private static void assertVoBLEControlOwnershipAndCallDeduplication() {
		com.airsim.phonecontrol.voble.VoBLEControlChannel channel =
				new com.airsim.phonecontrol.voble.VoBLEControlChannel();
		assertTrue(channel.canAuthenticate("iphone-air"));
		channel.subscribeControl("iphone-air");
		assertTrue(!channel.isReady("iphone-air"));
		assertTrue(channel.authenticate("iphone-air"));
		assertTrue(!channel.canAuthenticate("iphone-other"));
		assertTrue(channel.isReady("iphone-air"));
		channel.subscribeAudio("iphone-air");
		channel.unsubscribeAudio("iphone-air");
		assertTrue(channel.isControlSubscribed("iphone-air"));
		assertTrue(!channel.isAudioSubscribed("iphone-air"));
		assertTrue(!channel.authenticate("other-iphone"));
		assertTrue(channel.revokeOwner("iphone-air"));
		assertTrue(!channel.owns("iphone-air"));
		assertTrue(channel.canAuthenticate("other-iphone"));
		assertTrue(!channel.revokeOwner("iphone-air"));

		java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
		com.airsim.phonecontrol.voble.VoBLECallController controller =
				new com.airsim.phonecontrol.voble.VoBLECallController(request -> {
					calls.incrementAndGet();
					return com.airsim.phonecontrol.voble.VoBLECallController.Result.success("ok");
				});
		assertTrue(!controller.ownsCall("", 0));
		assertTrue(!controller.ownsCall(null, 1));
		assertTrue(!controller.ownsCall("call-1", 0));
		controller.observeCall("call-1", 7, "incoming");
		var request = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"request-1", "answer", "call-1", "", 7);
		assertEquals("authentication_failed", controller.execute(request, false).code());
		assertEquals("ok", controller.execute(request, true).code());
		assertEquals("ok", controller.execute(request, true).code());
		assertEquals(1, calls.get());
		var stale = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"request-2", "answer", "call-1", "", 6);
		assertEquals("stale_generation", controller.execute(stale, true).code());
		assertEquals(1, calls.get());
		assertTrue(controller.observeCall("call-1", 7, "ended"));
		assertTrue(!controller.observeCall("call-1", 7, "ended"));
		java.util.concurrent.atomic.AtomicInteger mediaStarts = new java.util.concurrent.atomic.AtomicInteger();
		var mediaRequest = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"media-1", "start_media", "call-1", "", 7);
		controller.executeOnce(mediaRequest, true, ignored -> {
			mediaStarts.incrementAndGet();
			return com.airsim.phonecontrol.voble.VoBLECallController.Result.success("media_ready");
		});
		controller.executeOnce(mediaRequest, true, ignored -> {
			mediaStarts.incrementAndGet();
			return com.airsim.phonecontrol.voble.VoBLECallController.Result.success("media_ready");
		});
		assertEquals(1, mediaStarts.get());

		var dial = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"dial-1", "dial", "provisional-call", "10086", 8);
		assertEquals("ok", controller.execute(dial, true).code());
		assertTrue(controller.ownsCall("provisional-call", 8));
		controller.observeCall("android-call", 8, "dialing");
		assertTrue(controller.ownsCall("android-call", 8));
		int acceptedCalls = calls.get();
		var reusedActive = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"dial-reused-active", "dial", "different-call", "10086", 8);
		assertEquals("stale_generation", controller.execute(reusedActive, true).code());
		assertEquals(acceptedCalls, calls.get());
		controller.observeCall("android-call", 8, "ended");
		var reusedEnded = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"dial-reused-ended", "dial", "different-call", "10086", 8);
		assertEquals("stale_generation", controller.execute(reusedEnded, true).code());
		assertEquals(acceptedCalls, calls.get());
		assertEquals(8L, controller.currentGeneration());

		// Android process/app data can restart while iPhone keeps its monotonic
		// generation. The first authenticated dial must resynchronize forward,
		// while an older delayed dial must still be rejected.
		var restarted = new com.airsim.phonecontrol.voble.VoBLECallController(ignored ->
				com.airsim.phonecontrol.voble.VoBLECallController.Result.success("ok"));
		var resumedDial = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"dial-resume", "dial", "provisional-resume", "10086", 42);
		assertEquals("ok", restarted.execute(resumedDial, true).code());
		assertTrue(restarted.ownsCall("provisional-resume", 42));
		var delayedDial = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"dial-delayed", "dial", "provisional-old", "10010", 41);
		assertEquals("stale_generation", restarted.execute(delayedDial, true).code());
	}

	private static void assertVoBLEHangupAfterTerminalEventIsIdempotentAndCannotEndNextCall() {
		var invocations = new java.util.concurrent.atomic.AtomicInteger();
		var controller = new com.airsim.phonecontrol.voble.VoBLECallController(request -> {
			invocations.incrementAndGet();
			return com.airsim.phonecontrol.voble.VoBLECallController.Result.success("accepted");
		});
		controller.observeCall("ended-call", 7, "active");
		assertTrue(controller.observeCall("ended-call", 7, "ended"));
		for (String action : new String[]{"end", "reject"}) {
			var late = new com.airsim.phonecontrol.voble.VoBLECallController.Request(
					"late-" + action, action, "ended-call", "", 7);
			assertTrue(controller.execute(late, true).success());
			assertEquals("authentication_failed", controller.execute(late, false).code());
		}
		assertEquals(0, invocations.get());
		controller.observeCall("next-call", 8, "active");
		assertTrue(controller.execute(new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"late-again", "end", "ended-call", "", 7), true).success());
		assertTrue(controller.ownsCall("next-call", 8));
		assertEquals(0, invocations.get());
		assertEquals("call_mismatch", controller.execute(
				new com.airsim.phonecontrol.voble.VoBLECallController.Request(
						"unknown", "end", "unknown-call", "", 8), true).code());
		assertTrue(controller.execute(new com.airsim.phonecontrol.voble.VoBLECallController.Request(
				"end-next", "end", "next-call", "", 8), true).success());
		assertEquals(1, invocations.get());
	}

	private static void assertVoBLEPCMResolutionHandshakeAndMediaCrypto() throws Exception {
		var standalone = com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.resolve(
				com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.Runtime.STANDALONE, "");
		assertEquals("127.0.0.1", standalone.getAddress().getHostAddress());
		assertEquals(7580, standalone.getPort());
		var avf = com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.resolve(
				com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.Runtime.AVF, "10.185.5.25");
		assertEquals("10.185.5.25", avf.getAddress().getHostAddress());
		var movedAVF = com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.resolve(
				com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.Runtime.AVF, "10.185.5.31");
		assertEquals("10.185.5.31", movedAVF.getAddress().getHostAddress());
		assertEquals("10.185.5.25", avf.getAddress().getHostAddress());
		var unsafeDiagnostics = new java.util.LinkedHashMap<String, String>();
		unsafeDiagnostics.put("pcm_ready", "true");
		unsafeDiagnostics.put("phone_number", "+8613800000000");
		unsafeDiagnostics.put("media_key", "secret");
		unsafeDiagnostics.put("nonce", "secret");
		unsafeDiagnostics.put("audio_payload", "secret");
		var safeDiagnostics = com.airsim.phonecontrol.voble.VoBLEDiagnostics.sanitize(unsafeDiagnostics);
		assertEquals(java.util.Map.of("pcm_ready", "true"), safeDiagnostics);
		var diagnosticSnapshot = new com.airsim.phonecontrol.voble.VoBLEDiagnostics.Snapshot(
				"Standalone", true, true, "G.711-mu/8000/mono", 4, 3, 2, "");
		assertTrue(com.airsim.phonecontrol.voble.VoBLEDiagnostics.summary(diagnosticSnapshot)
				.contains("PCM 运行中"));
		try {
			com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.resolve(
					com.airsim.phonecontrol.voble.VoBLEPCMBackendResolver.Runtime.AVF, "");
			throw new AssertionError("missing AVF address must fail closed");
		} catch (IllegalArgumentException expected) {}

		java.io.ByteArrayOutputStream hello = new java.io.ByteArrayOutputStream();
		var bridge = com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.open(
				standalone, endpoint -> new com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.Duplex() {
					@Override public java.io.InputStream input() {
						return new java.io.ByteArrayInputStream("AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
					}
					@Override public java.io.OutputStream output() { return hello; }
					@Override public void close() {}
				});
		assertEquals("AIRSIMPCM1\n", new String(hello.toByteArray(), java.nio.charset.StandardCharsets.US_ASCII));
		assertTrue(bridge.ready());
		bridge.close();
		try {
			com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.open(
					standalone, endpoint -> new com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.Duplex() {
						@Override public java.io.InputStream input() { return new java.io.ByteArrayInputStream("BAD".getBytes()); }
						@Override public java.io.OutputStream output() { return java.io.OutputStream.nullOutputStream(); }
						@Override public void close() {}
					});
			throw new AssertionError("AIRSIMREADY is required");
		} catch (java.io.IOException expected) {}

		byte[] pcm = new byte[320];
		for (int index = 0; index < 160; index++) {
			short sample = (short) ((index - 80) * 300);
			pcm[index * 2] = (byte) sample;
			pcm[index * 2 + 1] = (byte) (sample >>> 8);
		}
		byte[] ulaw = com.airsim.phonecontrol.voble.VoBLEMediaSession.encodeMuLaw(pcm);
		assertEquals(160, ulaw.length);
		assertEquals(320, com.airsim.phonecontrol.voble.VoBLEMediaSession.decodeMuLaw(ulaw).length);
		byte[] key = filledBytes(32, 7);
		var encrypted = com.airsim.phonecontrol.voble.VoBLEMediaSession.encrypt(
				ulaw, key, true, 3, 9, 1_440);
		assertTrue(java.util.Arrays.equals(ulaw,
				com.airsim.phonecontrol.voble.VoBLEMediaSession.decrypt(
						encrypted, key, true, 3, 9, 1_440)));
		try {
			com.airsim.phonecontrol.voble.VoBLEMediaSession.decrypt(
					encrypted, filledBytes(32, 8), true, 3, 9, 1_440);
			throw new AssertionError("wrong media key must fail");
		} catch (java.security.GeneralSecurityException expected) {}

		class BlockingDuplex implements com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.Duplex {
			final byte[] ready = "AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
			final java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
			int offset;
			boolean closed;
			final java.io.InputStream input = new java.io.InputStream() {
				@Override public synchronized int read() throws java.io.IOException {
					if (offset < ready.length) return ready[offset++] & 0xff;
					while (!closed) try { wait(); }
					catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new java.io.IOException(error); }
					return -1;
				}
			};
			@Override public java.io.InputStream input() { return input; }
			@Override public java.io.OutputStream output() { return output; }
			@Override public void close() {
				closed = true;
				synchronized (input) { input.notifyAll(); }
			}
		}
		BlockingDuplex duplex = new BlockingDuplex();
		var identity = new com.airsim.phonecontrol.voble.VoBLEMediaSession.Identity("call-media", 3);
		var media = new com.airsim.phonecontrol.voble.VoBLEMediaSession(
				standalone,
				endpoint -> com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.open(endpoint, ignored -> duplex),
				packet -> true);
		assertTrue(!media.onUplinkFragment(identity, new byte[]{1}));
		media.start(identity, key);
		assertTrue(media.ready());
		var uplinkEncrypted = com.airsim.phonecontrol.voble.VoBLEMediaSession.encrypt(
				ulaw, key, true, 3, 10, 1_600);
		var uplinkPacket = new com.airsim.phonecontrol.voble.VoBLEProtocol.AudioPacket(
				0, com.airsim.phonecontrol.voble.VoBLEProtocol.CODEC_G711_MULAW,
				3, 10, 1_600, uplinkEncrypted.payload(), uplinkEncrypted.authenticationTag());
		for (byte[] fragment : com.airsim.phonecontrol.voble.VoBLEProtocol.encodeAudioFragments(
				uplinkPacket, 247)) assertTrue(media.onUplinkFragment(identity, fragment));
		boolean duplicateAccepted = true;
		for (byte[] fragment : com.airsim.phonecontrol.voble.VoBLEProtocol.encodeAudioFragments(
				uplinkPacket, 247)) duplicateAccepted = media.onUplinkFragment(identity, fragment);
		assertTrue(!duplicateAccepted);
		long deadline = System.currentTimeMillis() + 1_000;
		while (duplex.output.size() < "AIRSIMPCM1\n".length() + 320
				&& System.currentTimeMillis() < deadline) Thread.sleep(5);
		assertTrue(duplex.output.size() >= "AIRSIMPCM1\n".length() + 320);
		media.stop();
		assertTrue(duplex.closed);
		assertTrue(!media.ready());

		byte[] readyAndPCM = new byte["AIRSIMREADY".length() + 320];
		System.arraycopy("AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII),
				0, readyAndPCM, 0, "AIRSIMREADY".length());
		java.util.concurrent.atomic.AtomicInteger notificationAttempts =
				new java.util.concurrent.atomic.AtomicInteger();
		var retryMedia = new com.airsim.phonecontrol.voble.VoBLEMediaSession(
				standalone,
				endpoint -> com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.open(endpoint, ignored ->
						new com.airsim.phonecontrol.voble.VoBLEPCMBridgeSession.Duplex() {
							@Override public java.io.InputStream input() { return new java.io.ByteArrayInputStream(readyAndPCM); }
							@Override public java.io.OutputStream output() { return java.io.OutputStream.nullOutputStream(); }
							@Override public void close() {}
						}),
				packet -> { notificationAttempts.incrementAndGet(); return false; });
		retryMedia.start(new com.airsim.phonecontrol.voble.VoBLEMediaSession.Identity("call-retry", 4), key);
		deadline = System.currentTimeMillis() + 1_000;
		while (retryMedia.stats().droppedFrames() == 0 && System.currentTimeMillis() < deadline) {
			Thread.sleep(5);
		}
		assertTrue(notificationAttempts.get() > 1);
		assertTrue(retryMedia.stats().droppedFrames() >= 1);
		retryMedia.stop();
	}

	private static byte[] filledBytes(int count, int value) {
		byte[] result = new byte[count];
		java.util.Arrays.fill(result, (byte) value);
		return result;
	}

	private static void assertTransientMuteFailureRetriesAndRestorationCancelsStaleRetry() {
		java.util.ArrayDeque<Runnable> immediate = new java.util.ArrayDeque<>();
		java.util.ArrayDeque<Runnable> delayed = new java.util.ArrayDeque<>();
		java.util.List<Boolean> attempts = new java.util.ArrayList<>();
		MuteRequestRetrier retrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
			@Override public void execute(Runnable task) { immediate.add(task); }
			@Override public void schedule(Runnable task, long delayMillis) { delayed.add(task); }
		}, muted -> {
			attempts.add(muted);
			if (muted && attempts.size() == 1) throw new IllegalStateException("transient binder error");
		}, (muted, error) -> {});
		retrier.request(true);
		immediate.remove().run();
		assertEquals(java.util.List.of(true), attempts);
		assertEquals(1, delayed.size());
		delayed.remove().run();
		assertEquals(java.util.List.of(true, true), attempts);

		java.util.List<Boolean> superseded = new java.util.ArrayList<>();
		MuteRequestRetrier second = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
			@Override public void execute(Runnable task) { immediate.add(task); }
			@Override public void schedule(Runnable task, long delayMillis) { delayed.add(task); }
		}, muted -> {
			superseded.add(muted);
			if (muted) throw new IllegalStateException("mute failed");
		}, (muted, error) -> {});
		second.request(true);
		immediate.remove().run();
		second.request(false);
		immediate.remove().run();
		delayed.remove().run();
		assertEquals(java.util.List.of(true, false), superseded);
	}

	private static void assertMutedCallRecoversAfterThreeTransientAudioFailures() {
		java.util.ArrayDeque<Runnable> immediate = new java.util.ArrayDeque<>();
		java.util.ArrayDeque<Runnable> delayed = new java.util.ArrayDeque<>();
		java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
		java.util.List<String> results = new java.util.ArrayList<>();
		MuteRequestRetrier retrier = new MuteRequestRetrier(new MuteRequestRetrier.Scheduler() {
			@Override public void execute(Runnable task) { immediate.add(task); }
			@Override public void schedule(Runnable task, long delayMillis) { delayed.add(task); }
		}, muted -> {
			if (!muted) throw new AssertionError("this test only requests muting");
			if (calls.incrementAndGet() <= 3) throw new IllegalStateException("temporary Shizuku failure");
		}, (muted, error) -> results.add(error == null ? "muted" : "failed"));
		retrier.request(true);
		immediate.remove().run();
		delayed.remove().run();
		delayed.remove().run();
		assertTrue(!delayed.isEmpty());
		delayed.remove().run();
		assertEquals(4, calls.get());
		assertEquals("muted", results.get(results.size() - 1));
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
			int sdk, boolean callPhoneGranted, boolean sendSMSGranted,
			boolean notificationsGranted) throws Exception {
		try {
			Class<?> policy = Class.forName("com.airsim.phonecontrol.RuntimePermissionPolicy");
			return (String[]) policy.getDeclaredMethod(
					"missingPermissions", int.class, boolean.class, boolean.class, boolean.class)
					.invoke(null, sdk, callPhoneGranted, sendSMSGranted, notificationsGranted);
		} catch (ClassNotFoundException error) {
			throw new AssertionError("CALL_PHONE runtime permission policy is missing", error);
		}
	}

	private static String[] invokeOptionalInboxPermissions(
			boolean readSMSGranted, boolean alreadyPrompted) throws Exception {
		try {
			return (String[]) RuntimePermissionPolicy.class.getDeclaredMethod(
					"optionalInboxPermissions", boolean.class, boolean.class)
					.invoke(null, readSMSGranted, alreadyPrompted);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("optional READ_SMS permission policy is missing", error);
		}
	}

	private static int invokeConfirmedSMSSegments(SMSConfirmation.Outcome outcome) throws Exception {
		try {
			return (int) outcome.getClass().getDeclaredMethod("confirmedSegments").invoke(outcome);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("SMS send outcome does not expose confirmed segment count", error);
		}
	}

	private static String invokeSMSIdentity(String sender, String body, long timestamp) throws Exception {
		try {
			Class<?> identity = Class.forName("com.airsim.phonecontrol.SMSDeliveryIdentity");
			return (String) identity.getDeclaredMethod("id", String.class, String.class, long.class)
					.invoke(null, sender, body, timestamp);
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("shared broadcast/inbox SMS delivery identity is missing", error);
		}
	}

	private static long invokeProviderTimestamp(long sent, long received) throws Exception {
		try {
			Class<?> identity = Class.forName("com.airsim.phonecontrol.SMSDeliveryIdentity");
			return (long) identity.getDeclaredMethod("providerTimestamp", long.class, long.class)
					.invoke(null, sent, received);
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("SMS provider timestamp fallback is missing", error);
		}
	}

	private static void assertRecentSMSIDsRetainBoundedDeliveryHistory() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.SMSRecentDeliveryIDs");
			Object recent = type.getDeclaredConstructor(java.util.Collection.class)
					.newInstance(java.util.List.of("first"));
			java.lang.reflect.Method contains = type.getDeclaredMethod("contains", String.class);
			java.lang.reflect.Method remember = type.getDeclaredMethod("remember", String.class);
			assertTrue((boolean) contains.invoke(recent, "first"));
			for (int index = 0; index < 512; index++) remember.invoke(recent, "later-" + index);
			assertTrue(!(boolean) contains.invoke(recent, "first"));
			assertTrue((boolean) contains.invoke(recent, "later-511"));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("completed SMS delivery history is missing", error);
		}
	}

	private static void assertLiveStatusPollerUpdatesWithoutRebuildingPage() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.LiveStatusPoller");
			Class<?> schedulerType = Class.forName("com.airsim.phonecontrol.LiveStatusPoller$Scheduler");
			java.util.concurrent.atomic.AtomicBoolean ready = new java.util.concurrent.atomic.AtomicBoolean(false);
			java.util.List<Boolean> rendered = new java.util.ArrayList<>();
			Runnable[] scheduled = new Runnable[1];
			Object scheduler = java.lang.reflect.Proxy.newProxyInstance(
					schedulerType.getClassLoader(), new Class<?>[]{schedulerType},
					(proxy, method, arguments) -> {
						if ("postDelayed".equals(method.getName())) scheduled[0] = (Runnable) arguments[0];
						if ("removeCallbacks".equals(method.getName()) && scheduled[0] == arguments[0]) {
							scheduled[0] = null;
						}
						return null;
					});
			Object poller = type.getDeclaredConstructor(
					java.util.function.BooleanSupplier.class, java.util.function.Consumer.class,
					schedulerType, long.class)
					.newInstance((java.util.function.BooleanSupplier) ready::get,
							(java.util.function.Consumer<Boolean>) rendered::add, scheduler, 1_000L);
			java.lang.reflect.Method start = type.getDeclaredMethod("start");
			java.lang.reflect.Method stop = type.getDeclaredMethod("stop");
			start.invoke(poller);
			assertEquals(java.util.List.of(false), rendered);
			assertTrue(scheduled[0] != null);
			ready.set(true);
			Runnable oldTick = scheduled[0];
			oldTick.run();
			assertEquals(java.util.List.of(false, true), rendered);
			assertTrue(scheduled[0] != null);
			stop.invoke(poller);
			assertTrue(scheduled[0] == null);
			ready.set(false);
			oldTick.run();
			assertEquals(java.util.List.of(false, true), rendered);
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("visible PCM status must refresh while active and stop when hidden", error);
		}
	}

	private static void assertLiveStatusPollerRecoversAfterOneFailedRead() {
		java.util.concurrent.atomic.AtomicInteger reads = new java.util.concurrent.atomic.AtomicInteger();
		java.util.List<Boolean> rendered = new java.util.ArrayList<>();
		Runnable[] scheduled = new Runnable[1];
		LiveStatusPoller poller = new LiveStatusPoller(() -> {
			if (reads.getAndIncrement() == 0) throw new IllegalStateException("transient status failure");
			return true;
		}, rendered::add, new LiveStatusPoller.Scheduler() {
			@Override public void postDelayed(Runnable task, long delayMillis) { scheduled[0] = task; }
			@Override public void removeCallbacks(Runnable task) {
				if (scheduled[0] == task) scheduled[0] = null;
			}
		}, 1_000L);
		poller.start();
		assertTrue(scheduled[0] != null);
		scheduled[0].run();
		assertEquals(java.util.List.of(true), rendered);
		poller.stop();
	}

	private static void assertLiveStatusPollerRetriesFailedRender() {
		java.util.concurrent.atomic.AtomicInteger renders = new java.util.concurrent.atomic.AtomicInteger();
		java.util.List<Boolean> rendered = new java.util.ArrayList<>();
		Runnable[] scheduled = new Runnable[1];
		LiveStatusPoller poller = new LiveStatusPoller(() -> true, value -> {
			if (renders.getAndIncrement() == 0) throw new IllegalStateException("view briefly unavailable");
			rendered.add(value);
		}, new LiveStatusPoller.Scheduler() {
			@Override public void postDelayed(Runnable task, long delayMillis) { scheduled[0] = task; }
			@Override public void removeCallbacks(Runnable task) {
				if (scheduled[0] == task) scheduled[0] = null;
			}
		}, 1_000L);
		poller.start();
		assertTrue(scheduled[0] != null);
		scheduled[0].run();
		assertEquals(java.util.List.of(true), rendered);
		poller.stop();
	}

	private static void assertPCMBridgeRunningUsesPrivilegedProcessStatus() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.PCMBridgeStatus");
			java.lang.reflect.Method running = type.getDeclaredMethod("isRunning", String.class);
			assertTrue((boolean) running.invoke(null, "uid=2000 pcm=running local_output=normal"));
			assertTrue(!(boolean) running.invoke(null, "uid=2000 pcm=stopped local_output=normal"));
			assertTrue(!(boolean) running.invoke(null, "uid=2000 pcm=runningish local_output=normal"));
			assertTrue(!(boolean) running.invoke(null, (String) null));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("PCM readiness must use the privileged bridge process status", error);
		}
	}

	private static void assertPrivilegedBridgeStatusRefreshTracksProcessExit() throws Exception {
		try {
			Class<?> coordinatorType = Class.forName("com.airsim.phonecontrol.PrivilegedBridgeCoordinator");
			Class<?> transportType = Class.forName(
					"com.airsim.phonecontrol.PrivilegedBridgeCoordinator$Transport");
			java.util.concurrent.atomic.AtomicBoolean processAlive = new java.util.concurrent.atomic.AtomicBoolean(true);
			Object transport = java.lang.reflect.Proxy.newProxyInstance(
					transportType.getClassLoader(), new Class<?>[]{transportType},
					(proxy, method, arguments) -> "uid=2000 pcm="
							+ (processAlive.get() ? "running" : "stopped") + " local_output=normal");
			Object coordinator = coordinatorType.getDeclaredConstructor().newInstance();
			coordinatorType.getDeclaredMethod("connect", transportType).invoke(coordinator, transport);
			java.lang.reflect.Method running = coordinatorType.getDeclaredMethod("bridgeRunning");
			java.lang.reflect.Method refresh = coordinatorType.getDeclaredMethod("refreshStatus");
			assertTrue((boolean) running.invoke(coordinator));
			processAlive.set(false);
			refresh.invoke(coordinator);
			assertTrue(!(boolean) running.invoke(coordinator));
			processAlive.set(true);
			refresh.invoke(coordinator);
			assertTrue((boolean) running.invoke(coordinator));
			coordinatorType.getDeclaredMethod("disconnect").invoke(coordinator);
			assertTrue(!(boolean) running.invoke(coordinator));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("privileged PCM process status must refresh after startup", error);
		}
	}

	private static void assertMuteResultDoesNotHideRunningPCMBridge() throws Exception {
		PrivilegedBridgeCoordinator.Transport transport = new PrivilegedBridgeCoordinator.Transport() {
			@Override public String startBridge() { return "uid=2000 pcm=running local_output=normal"; }
			@Override public String status() { return "uid=2000 pcm=running local_output=muted"; }
			@Override public String setLocalOutputMuted(boolean muted) {
				return "local_output_muted previous_muted=false verified=true";
			}
		};
		PrivilegedBridgeCoordinator connected = new PrivilegedBridgeCoordinator();
		connected.connect(transport);
		connected.setLocalOutputMuted(true);
		assertTrue(connected.bridgeRunning());

		PrivilegedBridgeCoordinator reconnecting = new PrivilegedBridgeCoordinator();
		reconnecting.setLocalOutputMuted(true);
		reconnecting.connect(transport);
		assertTrue(reconnecting.bridgeRunning());
	}

	private static void assertVoWLANFailedRejectPreservesCallOwnership() {
		assertTrue(VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/reject", 502, true));
		assertTrue(VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/hangup", 502, true));
		assertTrue(!VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/reject", 200, true));
		assertTrue(VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/answer", 200, false));
		assertTrue(!VoWLANControlPolicy.ownsCallAfterResponse(
				"/api/calls/answer", 502, false));
	}

	private static void assertVoWLANClosedSocketStopsAcceptLoop() throws Exception {
		java.util.concurrent.atomic.AtomicInteger attempts = new java.util.concurrent.atomic.AtomicInteger();
		try (java.net.ServerSocket broken = new java.net.ServerSocket() {
			@Override public java.net.Socket accept() throws java.io.IOException {
				if (attempts.incrementAndGet() > 1) {
					throw new AssertionError("closed VoWLAN listener was retried");
				}
				throw new java.net.SocketException("Socket closed");
			}
			@Override public boolean isClosed() { return false; }
		}) {
			try {
				Class<?> type = Class.forName("com.airsim.phonecontrol.VoWLANAcceptLoop");
				java.lang.reflect.Method run = type.getDeclaredMethod("run", java.net.ServerSocket.class,
						java.util.function.Consumer.class, java.util.function.Consumer.class);
				run.invoke(null, broken,
						(java.util.function.Consumer<java.net.Socket>) peer -> {},
						(java.util.function.Consumer<java.io.IOException>) error -> {});
				assertEquals(1, attempts.get());
			} catch (ClassNotFoundException | NoSuchMethodException error) {
				throw new AssertionError("VoWLAN listener must stop on terminal SocketException", error);
			}
		}
	}

	private static void assertVoWLANIOExceptionStopsAcceptLoop() throws Exception {
		java.util.concurrent.atomic.AtomicInteger attempts = new java.util.concurrent.atomic.AtomicInteger();
		try (java.net.ServerSocket broken = new java.net.ServerSocket() {
			@Override public java.net.Socket accept() throws java.io.IOException {
				if (attempts.incrementAndGet() > 1) {
					throw new AssertionError("failed VoWLAN listener was retried without a rebind");
				}
				throw new java.io.IOException("listener failure");
			}
			@Override public boolean isClosed() { return false; }
		}) {
			Class<?> type = Class.forName("com.airsim.phonecontrol.VoWLANAcceptLoop");
			type.getDeclaredMethod("run", java.net.ServerSocket.class,
					java.util.function.Consumer.class, java.util.function.Consumer.class)
					.invoke(null, broken,
							(java.util.function.Consumer<java.net.Socket>) peer -> {},
							(java.util.function.Consumer<java.io.IOException>) error -> {});
			assertEquals(1, attempts.get());
		}
	}

	private static void assertInboxCursorBaselinesExistingMessagesAndRetriesFailures() throws Exception {
		try {
			Class<?> type = Class.forName("com.airsim.phonecontrol.SMSInboxCursor");
			Object cursor = type.getDeclaredConstructor(long.class).newInstance(-1L);
			java.lang.reflect.Method initialized = type.getDeclaredMethod("initialized");
			java.lang.reflect.Method baseline = type.getDeclaredMethod("baseline", long.class);
			java.lang.reflect.Method shouldQueue = type.getDeclaredMethod("shouldQueue", long.class);
			java.lang.reflect.Method processed = type.getDeclaredMethod("processed", long.class);
			java.lang.reflect.Method value = type.getDeclaredMethod("value");
			assertTrue(!(boolean) initialized.invoke(cursor));
			baseline.invoke(cursor, 10L);
			assertTrue(!(boolean) shouldQueue.invoke(cursor, 10L));
			assertTrue((boolean) shouldQueue.invoke(cursor, 11L));
			assertEquals(10L, value.invoke(cursor));
			processed.invoke(cursor, 11L);
			assertTrue(!(boolean) shouldQueue.invoke(cursor, 11L));
			assertTrue((boolean) shouldQueue.invoke(cursor, 12L));
		} catch (ClassNotFoundException | NoSuchMethodException error) {
			throw new AssertionError("new-message-only inbox cursor is missing", error);
		}
	}

	private static void assertCrashReportIsSanitizedBoundedAndPersisted() throws Exception {
		String repeated = "x".repeat(80_000);
		RuntimeException crash = new RuntimeException(
				"number=+8613800000000 token=super-secret-value " + repeated);
		String report = CrashReportFormatter.format(
				"0.9.6", "com.airsim.phonecontrol.standalone",
				"samsung", "SM-F766U", 35, "main", crash);
		assertContains(report, "AirSIM Android Crash Report");
		assertContains(report, "RuntimeException");
		assertContains(report, "[truncated]");
		assertTrue(report.length() <= CrashReportFormatter.MAX_REPORT_CHARS);
		assertTrue(!report.contains("+8613800000000"));
		assertTrue(!report.contains("super-secret-value"));

		java.nio.file.Path directory = java.nio.file.Files.createTempDirectory("airsim-crash-test");
		try {
			CrashReportStore.write(directory.toFile(), report);
			assertTrue(CrashReportStore.hasReport(directory.toFile()));
			assertEquals(report, CrashReportStore.read(directory.toFile()));
			CrashReportStore.clear(directory.toFile());
			assertTrue(!CrashReportStore.hasReport(directory.toFile()));
			assertEquals("", CrashReportStore.read(directory.toFile()));
		} finally {
			java.nio.file.Files.walk(directory)
					.sorted(java.util.Comparator.reverseOrder())
					.forEach(path -> { try { java.nio.file.Files.deleteIfExists(path); } catch (Exception ignored) {} });
		}
	}

	private static void assertCrashSharePayloadRequiresAReportAndSanitizesRecentLogs() {
		assertEquals("", CrashReportSharePayload.compose("", "debug line"));
		String payload = CrashReportSharePayload.compose(
				"AirSIM Android Crash Report\nRuntimeException: failure",
				"number=+8613800000000 token=private-value " + "d".repeat(80_000));
		assertContains(payload, "AirSIM Android Crash Report");
		assertContains(payload, "Recent sanitized debug log");
		assertTrue(payload.length() <= CrashReportSharePayload.MAX_SHARE_CHARS);
		assertTrue(!payload.contains("+8613800000000"));
		assertTrue(!payload.contains("private-value"));
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

	private static boolean invokeIsStaleAudioBridge(
			int candidatePid, int ownerPid, String commandLine) throws Exception {
		return invokeIsStaleAudioBridgeForPackage(candidatePid, ownerPid, commandLine,
				"CLASSPATH=/data/app/~~x/com.airsim.phonecontrol.standalone-y/base.apk\0",
				"com.airsim.phonecontrol.standalone");
	}

	private static boolean invokeIsStaleAudioBridgeForPackage(
			int candidatePid, int ownerPid, String commandLine,
			String processEnvironment, String packageName) throws Exception {
		try {
			Class<?> policy = Class.forName(
					"com.airsim.phonecontrol.PhoneAudioBridgeProcessPolicy");
			return (boolean) policy.getDeclaredMethod(
					"isStaleBridge", int.class, int.class, String.class, String.class, String.class)
					.invoke(null, candidatePid, ownerPid, commandLine, processEnvironment, packageName);
		} catch (NoSuchMethodException error) {
			throw new AssertionError("package-scoped stale PCM bridge policy is missing", error);
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
