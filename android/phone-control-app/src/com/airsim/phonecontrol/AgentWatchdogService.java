package com.airsim.phonecontrol;

import android.app.Service;
import android.app.ActivityOptions;
import android.app.PendingIntent;
import android.app.role.RoleManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.telecom.TelecomManager;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class AgentWatchdogService extends Service {
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile boolean running;
	private long lastRecoveryAttempt;

    public static void start(Context context) {
        if (RuntimeMode.isStandalone(context)) {
            StandaloneAgentService.start(context);
            return;
        }
        BridgeLog.debug("watchdog_start_requested");
        try { context.startForegroundService(new Intent(context, AgentWatchdogService.class)); }
        catch (RuntimeException error) { BridgeLog.error("watchdog_start_failed", error); }
    }

    @Override public void onCreate() {
        super.onCreate();
        BridgeLog.info("watchdog_created");
        ShizukuBridgeManager.get(this).ensureStarted();
        startForeground(BridgeNotification.WATCHDOG_ID, BridgeNotification.status(this, "正在连接 Linux Agent"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
        running = true;
        VoWLANGatewayService.start(this);
        worker.execute(this::loop);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void loop() {
        int failures = 0;
        boolean waitingForConfiguration = false;
        while (running) {
            try {
                if (!AppConfig.configured(this)) {
                    if (!waitingForConfiguration) BridgeLog.info("watchdog_waiting_for_configuration");
                    waitingForConfiguration = true;
                    update("等待配置控制令牌");
                    Thread.sleep(2_000);
                    continue;
                }
                if (waitingForConfiguration) BridgeLog.info("watchdog_configuration_available");
                waitingForConfiguration = false;
                String payload = new AgentClient(this).nextCommand();
                failures = 0;
                update(payload.isEmpty() ? "Linux Agent 在线" : "正在执行设备命令");
                if (!payload.isEmpty()) {
                    AgentCommand command = AgentCommand.parse(payload);
                    BridgeLog.info("command_received action=" + command.action + " command_id="
                            + DebugRedactor.safeIdentifier(command.id));
                    RoleManager roleManager = getSystemService(RoleManager.class);
                    boolean dialerRoleHeld = roleManager != null
                            && roleManager.isRoleHeld(RoleManager.ROLE_DIALER);
                    AgentCommandDispatcher.Result result = AgentCommandDispatcher.execute(
                            command, dialerRoleHeld,
                            call -> {
                                CallRepository.ActionResult telecom = CallRepository.execute(
                                        call, getSystemService(TelecomManager.class));
                                return new AgentCommandDispatcher.Result(
                                        telecom.success, telecom.error, 0);
                            },
                            sms -> SMSCommandExecutor.execute(this, sms));
                    if ("send_sms".equals(command.action)) {
                        new AgentClient(this).sendResult(command.id, result.success(),
                                result.error(), result.segments());
                    } else {
                        new AgentClient(this).sendResult(command.id, result.success(), result.error());
                    }
                    BridgeLog.info("command_result action=" + command.action + " success=" + result.success() +
                            " command_id=" + DebugRedactor.safeIdentifier(command.id));
                }
            } catch (InterruptedException interrupted) {
                BridgeLog.info("watchdog_interrupted");
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                failures++;
                update("Linux Agent 离线，自动重试 " + failures);
                BridgeLog.error("watchdog_cycle_failed failures=" + failures, error);
				long now = System.currentTimeMillis();
				if (RecoveryPolicy.shouldAttempt(failures, lastRecoveryAttempt, now)) {
					lastRecoveryAttempt = now;
					attemptTerminalRecovery();
				}
                try { Thread.sleep(RetryPolicy.delayMillis(failures - 1)); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

	private void attemptTerminalRecovery() {
		try {
			Intent terminal = AVFEnvironmentActions.terminalIntent(this);
			int backgroundStartMode = RecoveryLaunchPolicy.backgroundActivityStartMode(Build.VERSION.SDK_INT);
			ActivityOptions creatorOptions = ActivityOptions.makeBasic()
					.setPendingIntentCreatorBackgroundActivityStartMode(
							backgroundStartMode);
			PendingIntent launcher = PendingIntent.getActivity(
					this,
					BridgeNotification.WATCHDOG_ID,
					terminal,
					PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT,
					creatorOptions.toBundle());
			ActivityOptions senderOptions = ActivityOptions.makeBasic()
					.setPendingIntentBackgroundActivityStartMode(
							backgroundStartMode);
			launcher.send(this, 0, null, null, null, null, senderOptions.toBundle());
			update("正在恢复 Android Linux VM");
			BridgeLog.info("terminal_recovery_requested");
		} catch (PendingIntent.CanceledException | RuntimeException error) {
			BridgeLog.error("terminal_recovery_failed", error);
		}
	}

    private void update(String detail) {
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.WATCHDOG_ID, BridgeNotification.status(this, detail));
    }

    @Override public void onDestroy() {
        BridgeLog.info("watchdog_destroyed");
        running = false;
        worker.shutdownNow();
        super.onDestroy();
    }
}
