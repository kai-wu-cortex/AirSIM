package com.airsim.phonecontrol;

import android.Manifest;
import android.app.Activity;
import android.app.role.RoleManager;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CountDownTimer;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.telecom.TelecomManager;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;
import org.json.JSONArray;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int ROLE_REQUEST = 100;
    private static final int DEFAULT_APPS_REQUEST = 102;
    private static final int OPTIONAL_SMS_REQUEST = 103;
    private static final int CALL_ACCOUNT_PERMISSION_REQUEST = 104;
    private static final int SHIZUKU_SETUP_REQUEST = 105;
    private static final int DIAGNOSTIC_TXT_REQUEST = 106;
    private static final java.util.concurrent.ExecutorService DIAGNOSTIC_WORKER = Executors.newSingleThreadExecutor();
    private static final String SHIZUKU_STARTUP_CHECKED = "shizuku_startup_checked";
    private static final String OPTIONAL_SMS_PROMPTED = "optional_sms_prompted";
    private static final java.util.concurrent.ExecutorService SMS_SCAN_WORKER =
            Executors.newSingleThreadExecutor();

    private static final int BG = Color.rgb(8, 14, 20);
    private static final int SURFACE = Color.rgb(17, 28, 39);
    private static final int SURFACE_HIGH = Color.rgb(23, 36, 49);
    private static final int BORDER = Color.rgb(42, 58, 73);
    private static final int PRIMARY = Color.rgb(52, 229, 170);
    private static final int CYAN = Color.rgb(73, 231, 224);
    private static final int BLUE = Color.rgb(47, 128, 237);
    private static final int TEXT = Color.rgb(244, 247, 250);
    private static final int MUTED = Color.rgb(166, 179, 193);
    private static final int WARNING = Color.rgb(255, 184, 77);
    private static final int DANGER = Color.rgb(255, 99, 99);

    private enum Page { STATUS, CALLS, DEBUG, SETTINGS }
    private enum Feature { VOWLAN, AGENT, PCM, PUSH, SHIZUKU }

    private FrameLayout contentHost;
    private LinearLayout bottomBar;
    private final List<TextView> navigationItems = new ArrayList<>();
    private Page currentPage = Page.STATUS;
    private HealthTile pcmHealthTile;
    private LiveStatusPoller pcmStatusPoller;
    private boolean resumed;
    private AppUpdatePresenter appUpdates;

    private EditText endpoint;
    private EditText token;
    private EditText number;
    private String selectedMode;
    private TextView status;
    private TextView shizukuStatus;
    private RadioGroup privilegeChannelGroup;
    private final java.util.Map<Integer, PrivilegeChannelPreference.Channel> privilegeChannelIDs
            = new java.util.LinkedHashMap<>();
    private boolean updatingPrivilegeChannel;
	private TextView installerStatus;
    private TextView pairingStatus;
    private TextView pairingCodeView;
    private TextView pairingCountdownView;
    private TextView voBLEAuthenticationStatusView;
    private TextView voBLEPairingCodeView;
    private TextView voBLEDiagnosticsView;
    private TextView voBLEClearCredentialButton;
    private boolean voBLEAuthenticationVisible;
    private LinearLayout debugRows;
    private String lastRenderedDebugLog;
    private String lastRenderedDebugFilter;
    private TextView agentRefreshResult;
    private String agentRefreshMessage = "点击刷新以查看 Agent 的实际返回结果";
    private int agentRefreshColor = MUTED;
    private int agentRefreshGeneration;
    private String activeDebugFilter = "全部";
    private boolean realtimeLogging = true;
    private boolean agentOnline;
    private String agentDetail = "待检测";
    private boolean pushConfigured;
    private String pushDetail = "尚未检查";
    private String pushDiagnostic = "尚未读取 Agent 的 Push 状态";
	private boolean cloudEnabled;
	private boolean cloudRelayConfigured;
	private String cloudLastError = "";
	private boolean avfStartupPromptShown;
	private boolean crashPromptShown;
    private ShizukuStartupPolicy shizukuStartupPolicy;
    private boolean startupSetupPending;
    private boolean startupSetupInFlight;
    private boolean startupSetupCompleted;
    private AlertDialog shizukuStartupDialog;
    private final Runnable startupSetup = () -> {
        if (startupSetupPending) continueStartupSetup();
    };

    private PairingServer pairingServer;
    private CountDownTimer pairingCountdown;
    private String pairingCode = "";
    private long pairingExpiresAt;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable debugRefresh = new Runnable() {
        @Override public void run() {
            if (currentPage == Page.DEBUG && realtimeLogging) {
                refreshDebugLog();
                handler.postDelayed(this, 2_000);
            }
        }
    };
    private final Runnable voBLEAuthenticationRefresh = new Runnable() {
        @Override public void run() {
            if (!voBLEAuthenticationVisible) return;
            renderVoBLEAuthenticationStatus();
            handler.postDelayed(this, 500);
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        appUpdates = new AppUpdatePresenter(this, () -> resumed && startupSetupCompleted
                && !startupSetupPending && !startupSetupInFlight && CallRepository.firstId().isEmpty());
        shizukuStartupPolicy = new ShizukuStartupPolicy(
                state != null && state.getBoolean(SHIZUKU_STARTUP_CHECKED, false));
        pcmStatusPoller = new LiveStatusPoller(() -> {
            ShizukuBridgeManager bridge = ShizukuBridgeManager.get(this);
            bridge.refreshBridgeStatus();
            return bridge.bridgeRunning();
        }, this::renderPCMStatus, new LiveStatusPoller.Scheduler() {
            @Override public void postDelayed(Runnable task, long delayMillis) {
                handler.postDelayed(task, delayMillis);
            }
            @Override public void removeCallbacks(Runnable task) {
                handler.removeCallbacks(task);
            }
        }, 1_000);
        configureWindow();
        setContentView(buildShell());
        showPage(Page.STATUS);
        Uri data = getIntent().getData();
        if (Intent.ACTION_DIAL.equals(getIntent().getAction()) && data != null) {
            showPage(Page.CALLS);
            if (number != null) number.setText(data.getSchemeSpecificPart());
        }
        refreshStatus();
        refreshAgent();
		String[] missingPermissions = RuntimePermissionPolicy.missingPermissions(
				Build.VERSION.SDK_INT,
				checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED,
				checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS) == PackageManager.PERMISSION_GRANTED,
				Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
						== PackageManager.PERMISSION_GRANTED,
				Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
						== PackageManager.PERMISSION_GRANTED,
				Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
						== PackageManager.PERMISSION_GRANTED);
		if (missingPermissions.length > 0) {
            requestPermissions(missingPermissions, 101);
		} else {
			requestOptionalSMSPermission();
		}
    }

	@Override public void onRequestPermissionsResult(
			int requestCode, String[] permissions, int[] grantResults) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults);
		if (requestCode == 101) requestOptionalSMSPermission();
		if (requestCode == 101 && hasVoBLEPermissions()) {
			com.airsim.phonecontrol.voble.VoBLEGatewayService.start(this);
		}
		if (requestCode == OPTIONAL_SMS_REQUEST) {
			startSMSInboxBaselineIfAuthorized();
			continueStartupSetup();
			if (currentPage == Page.SETTINGS) showPage(Page.SETTINGS);
		}
		if (requestCode == CALL_ACCOUNT_PERMISSION_REQUEST && currentPage == Page.SETTINGS) {
			showPage(Page.SETTINGS);
		}
	}

	private void requestOptionalSMSPermission() {
		boolean granted = checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED;
		boolean prompted = getPreferences(MODE_PRIVATE).getBoolean(OPTIONAL_SMS_PROMPTED, false);
		String[] missing = RuntimePermissionPolicy.optionalInboxPermissions(granted, prompted);
		if (missing.length == 0) {
			continueStartupSetup();
			return;
		}
		getPreferences(MODE_PRIVATE).edit().putBoolean(OPTIONAL_SMS_PROMPTED, true).apply();
		requestPermissions(missing, OPTIONAL_SMS_REQUEST);
	}

	private boolean hasVoBLEPermissions() {
		return Build.VERSION.SDK_INT < 31
				|| (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
				&& checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED);
	}

	private void startSMSInboxBaselineIfAuthorized() {
		if (checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
			SMS_SCAN_WORKER.execute(() -> SMSInboxScanner.scanIfDue(getApplicationContext()));
		}
	}

    private void configureWindow() {
        getWindow().setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        if (Build.VERSION.SDK_INT >= 30) getWindow().setDecorFitsSystemWindows(false);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        getWindow().getDecorView().setSystemUiVisibility(0);
    }

    private View buildShell() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BG);
        root.setFitsSystemWindows(false);

        contentHost = new FrameLayout(this);
        root.addView(contentHost, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        bottomBar = buildBottomBar();
        root.addView(bottomBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(78)));

        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                Insets ime = insets.getInsets(WindowInsets.Type.ime());
                view.setPadding(bars.left, bars.top, bars.right, Math.max(bars.bottom, ime.bottom));
                View focused = getCurrentFocus();
                if (focused instanceof EditText && ime.bottom > 0) focused.post(() ->
                        focused.requestRectangleOnScreen(new android.graphics.Rect(0, 0,
                                focused.getWidth(), focused.getHeight()), false));
            } else {
                view.setPadding(0, insets.getSystemWindowInsetTop(), 0,
                        insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        return root;
    }

    private LinearLayout buildBottomBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER);
        bar.setPadding(dp(10), dp(6), dp(10), dp(8));
        bar.setBackground(rounded(SURFACE, 28, BORDER, 1));
        navigationItems.clear();
        bar.addView(navigationItem("状态", android.R.drawable.presence_online, Page.STATUS), weighted());
        bar.addView(navigationItem("通话", android.R.drawable.sym_action_call, Page.CALLS), weighted());
        bar.addView(navigationItem("调试", android.R.drawable.ic_menu_info_details, Page.DEBUG), weighted());
        bar.addView(navigationItem("设置", android.R.drawable.ic_menu_preferences, Page.SETTINGS), weighted());
        return bar;
    }

    private TextView navigationItem(String title, int icon, Page page) {
        TextView item = label(title, 12, MUTED, Gravity.CENTER);
        item.setCompoundDrawablesWithIntrinsicBounds(0, icon, 0, 0);
        item.setCompoundDrawableTintList(ColorStateList.valueOf(MUTED));
        item.setCompoundDrawablePadding(dp(3));
        item.setPadding(dp(4), dp(4), dp(4), dp(4));
        item.setOnClickListener(ignored -> showPage(page));
        item.setTag(page);
        navigationItems.add(item);
        return item;
    }

    private void showPage(Page page) {
        if (pcmStatusPoller != null) pcmStatusPoller.stop();
        voBLEAuthenticationVisible = false;
        handler.removeCallbacks(voBLEAuthenticationRefresh);
        voBLEAuthenticationStatusView = null;
        voBLEPairingCodeView = null;
        voBLEDiagnosticsView = null;
        voBLEClearCredentialButton = null;
        pcmHealthTile = null;
        currentPage = page;
        handler.removeCallbacks(debugRefresh);
        bottomBar.setVisibility(View.VISIBLE);
        contentHost.removeAllViews();
        View content;
        switch (page) {
        case CALLS: content = callsPage(); break;
        case DEBUG: content = debugPage(); break;
        case SETTINGS: content = settingsPage(); break;
        case STATUS:
        default: content = statusPage(); break;
        }
        contentHost.addView(content, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        updateNavigation();
        if (page == Page.DEBUG && realtimeLogging) handler.post(debugRefresh);
        if (page == Page.STATUS && resumed) pcmStatusPoller.start();
    }

    private void updateNavigation() {
        for (TextView item : navigationItems) {
            boolean selected = item.getTag() == currentPage;
            int color = selected ? PRIMARY : MUTED;
            item.setTextColor(color);
            item.setTypeface(Typeface.DEFAULT, selected ? Typeface.BOLD : Typeface.NORMAL);
            item.setCompoundDrawableTintList(ColorStateList.valueOf(color));
        }
    }

    private View statusPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("AirSIM Bridge", "运行中"));

        boolean paired = VoWLANPairingStore.configured(this);
        LinearLayout hero = card(SURFACE_HIGH, 24);
        hero.setOrientation(LinearLayout.HORIZONTAL);
        hero.setGravity(Gravity.CENTER_VERTICAL);
        hero.setPadding(dp(18), dp(20), dp(18), dp(20));
        ImageView wifi = icon(android.R.drawable.ic_menu_share, CYAN, 54);
        wifi.setBackground(rounded(Color.rgb(20, 80, 73), 28, Color.TRANSPARENT, 0));
        wifi.setPadding(dp(14), dp(14), dp(14), dp(14));
        hero.addView(wifi, new LinearLayout.LayoutParams(dp(58), dp(58)));
        LinearLayout heroCopy = column(dp(14));
        TextView heroTitle = label(
                paired ? (vowlanReady() ? "VoWLAN 已就绪" : "VoWLAN 准备中") : "VoWLAN 尚未配对",
                25, vowlanReady() ? CYAN : WARNING, Gravity.START);
        heroTitle.setTypeface(Typeface.DEFAULT_BOLD);
        heroCopy.addView(heroTitle);
        heroCopy.addView(label(vowlanNetworkLine(), 14, MUTED, Gravity.START));
        hero.addView(heroCopy, weighted());
        hero.setClickable(true);
        hero.setOnClickListener(ignored -> showFeatureDetails(Feature.VOWLAN));
        root.addView(hero, matchWithTop(16));

        String connectionMode = MainScreenPresentation.connectionModeTitle(
                vowlanReady(), cloudEnabled, cloudRelayConfigured, cloudLastError);
        String connectionDetail = MainScreenPresentation.connectionModeDetail(
                vowlanReady(), cloudEnabled, cloudRelayConfigured, cloudLastError);
        int connectionColor = vowlanReady() ? CYAN
                : cloudEnabled && cloudRelayConfigured && cloudLastError.isEmpty() ? BLUE : WARNING;
        LinearLayout connectionCard = card(SURFACE, 18);
        connectionCard.setOrientation(LinearLayout.VERTICAL);
        connectionCard.setPadding(dp(16), dp(14), dp(16), dp(14));
        connectionCard.addView(overline("当前连接模式"));
        TextView connectionTitle = label(connectionMode, 18, connectionColor, Gravity.START);
        connectionTitle.setTypeface(Typeface.DEFAULT_BOLD);
        connectionCard.addView(connectionTitle, matchWithTop(5));
        connectionCard.addView(label(connectionDetail, 13, MUTED, Gravity.START), matchWithTop(5));
        root.addView(connectionCard, matchWithTop(12));

        LinearLayout bluetoothCard = card(SURFACE, 18);
        bluetoothCard.setOrientation(LinearLayout.VERTICAL);
        bluetoothCard.setPadding(dp(16), dp(14), dp(16), dp(14));
        bluetoothCard.addView(overline("蓝牙通话（诊断已脱敏）"));
        bluetoothCard.addView(label(
                com.airsim.phonecontrol.voble.VoBLEGatewayService.diagnosticsSummary(),
                14, MUTED, Gravity.START), matchWithTop(5));
        root.addView(bluetoothCard, matchWithTop(10));

        LinearLayout firstHealthRow = row();
        HealthTile agentTile = healthTile(
                RuntimeMode.agentLabel(this), agentOnline ? "在线" : agentDetail,
                android.R.drawable.ic_menu_manage, agentOnline);
        agentTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.AGENT));
        firstHealthRow.addView(agentTile.view, weightedWithEnd(5));
        pcmHealthTile = healthTile(
                "PCM 音频桥", pcmBridgeRunning() ? "运行中" : "待启动",
                android.R.drawable.ic_media_play, pcmBridgeRunning());
        pcmHealthTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.PCM));
        firstHealthRow.addView(pcmHealthTile.view, weightedWithStart(5));
        root.addView(firstHealthRow, matchWithTop(12));

        LinearLayout secondHealthRow = row();
        HealthTile pushTile = healthTile(
                "Push / Relay", pushDetail,
                android.R.drawable.stat_notify_sync, pushConfigured);
        pushTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.PUSH));
        secondHealthRow.addView(pushTile.view, weightedWithEnd(5));
        HealthTile shizukuTile = healthTile(
                "Shizuku", shizukuReady() ? "已授权" : "待授权",
                android.R.drawable.ic_lock_idle_lock, shizukuReady());
        shizukuTile.view.setOnClickListener(ignored -> showFeatureDetails(Feature.SHIZUKU));
        secondHealthRow.addView(shizukuTile.view, weightedWithStart(5));
        root.addView(secondHealthRow, matchWithTop(10));

        root.addView(modeSelector(), matchWithTop(14));

        TextView pairing = primaryButton(paired ? "重新配对 iPhone" : "配对新 iPhone", BLUE);
        pairing.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_input_add, 0, 0, 0);
        pairing.setCompoundDrawableTintList(ColorStateList.valueOf(Color.WHITE));
        pairing.setCompoundDrawablePadding(dp(8));
        pairing.setOnClickListener(ignored -> openPairingPage());
        root.addView(pairing, matchWithTop(14));

        root.addView(sectionTitle("最近活动"), matchWithTop(22));
        LinearLayout recent = card(SURFACE, 18);
        recent.setPadding(dp(16), dp(14), dp(16), dp(14));
        recent.setOrientation(LinearLayout.HORIZONTAL);
        recent.setGravity(Gravity.CENTER_VERTICAL);
        View dot = new View(this);
        dot.setBackground(rounded(PRIMARY, 7, Color.TRANSPARENT, 0));
        recent.addView(dot, new LinearLayout.LayoutParams(dp(10), dp(10)));
        TextView activity = label(latestActivity(), 14, TEXT, Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams activityParams = weighted();
        activityParams.leftMargin = dp(12);
        recent.addView(activity, activityParams);
        recent.setOnClickListener(ignored -> showPage(Page.DEBUG));
        root.addView(recent, matchWithTop(10));

        status = label("", 12, MUTED, Gravity.START);
        status.setVisibility(View.GONE);
        root.addView(status);
        return scroll(root);
    }

    private View callsPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("通话控制", null));
        root.addView(description("三星 Telecom 本机控制；iPhone 通话优先使用 VoWLAN，局域网不可用时由云端中继。"), matchWithTop(8));

        LinearLayout dialCard = card(SURFACE, 24);
        dialCard.setOrientation(LinearLayout.VERTICAL);
        dialCard.setPadding(dp(18), dp(18), dp(18), dp(18));
        dialCard.addView(overline("拨号号码"));
        number = input("输入电话号码", InputType.TYPE_CLASS_PHONE);
        dialCard.addView(number, matchWithTop(8));
        TextView call = primaryButton("通过系统 Telecom 拨号", PRIMARY);
        call.setTextColor(BG);
        call.setOnClickListener(ignored -> placeSystemCall());
        dialCard.addView(call, matchWithTop(14));
        root.addView(dialCard, matchWithTop(18));

        root.addView(sectionTitle("当前通话"), matchWithTop(22));
        LinearLayout actions = row();
        TextView answer = secondaryButton("三星接听");
        answer.setOnClickListener(ignored -> localCall("answer"));
        TextView hangup = secondaryButton("挂断通话");
        hangup.setTextColor(DANGER);
        hangup.setOnClickListener(ignored -> localCall("end"));
        actions.addView(answer, weightedWithEnd(5));
        actions.addView(hangup, weightedWithStart(5));
        root.addView(actions, matchWithTop(10));

        LinearLayout roleCard = card(SURFACE, 20);
        roleCard.setOrientation(LinearLayout.VERTICAL);
        roleCard.setPadding(dp(16), dp(14), dp(16), dp(14));
        roleCard.addView(label(roleText(), 15, TEXT, Gravity.START));
        roleCard.addView(description("紧急呼叫始终由系统预装拨号器处理。"), matchWithTop(4));
        roleCard.setOnClickListener(ignored -> requestDialerRole());
        root.addView(roleCard, matchWithTop(18));
        return scroll(root);
    }

    private View debugPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("Debug 诊断", null));
        root.addView(smsAssistCard(), matchWithTop(14));
		if (CrashReportStore.hasReport(getFilesDir())) {
			LinearLayout crashCard = card(Color.rgb(57, 31, 36), 22);
			crashCard.setOrientation(LinearLayout.VERTICAL);
			crashCard.setPadding(dp(16), dp(15), dp(16), dp(15));
			TextView title = label("检测到上次闪退", 16, DANGER, Gravity.START);
			title.setTypeface(Typeface.DEFAULT_BOLD);
			crashCard.addView(title);
			crashCard.addView(label("报告已脱敏并保存在本机，只有点击发送后才会离开设备。",
					12, MUTED, Gravity.START), matchWithTop(4));
			LinearLayout crashActions = row();
			TextView send = secondaryButton("发送闪退报告");
			send.setTextColor(PRIMARY);
			send.setOnClickListener(ignored -> shareCrashReport());
			TextView remove = secondaryButton("删除报告");
			remove.setTextColor(DANGER);
			remove.setOnClickListener(ignored -> {
				CrashReportStore.clear(getFilesDir());
				toast("闪退报告已删除");
				showPage(Page.DEBUG);
			});
			crashActions.addView(send, weightedWithEnd(5));
			crashActions.addView(remove, weightedWithStart(5));
			crashCard.addView(crashActions, matchWithTop(12));
			root.addView(crashCard, matchWithTop(12));
		}
        root.addView(debugFilters(), matchWithTop(14));

        LinearLayout logCard = card(SURFACE, 22);
        logCard.setOrientation(LinearLayout.VERTICAL);
        logCard.setPadding(dp(12), dp(4), dp(12), dp(4));
        debugRows = column(0);
        lastRenderedDebugLog = null;
        lastRenderedDebugFilter = null;
        logCard.addView(debugRows);
        root.addView(logCard, matchWithTop(14));

        LinearLayout actions = row();
        TextView copy = secondaryButton("复制日志");
        copy.setOnClickListener(ignored -> copyDebugLog());
        TextView export = secondaryButton("导出诊断");
        export.setOnClickListener(ignored -> exportDebugLog());
        actions.addView(copy, weightedWithEnd(5));
        actions.addView(export, weightedWithStart(5));
        root.addView(actions, matchWithTop(12));

        TextView watchdogExport = secondaryButton("保存音频 Watchdog TXT");
        watchdogExport.setOnClickListener(ignored -> {
            Intent document = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            document.addCategory(Intent.CATEGORY_OPENABLE);
            document.setType("text/plain");
            document.putExtra(Intent.EXTRA_TITLE, "AirSIM-audio-watchdog-" + System.currentTimeMillis() + ".txt");
            try { startActivityForResult(document, DIAGNOSTIC_TXT_REQUEST); }
            catch (RuntimeException error) { toast("无法打开文件保存窗口，请使用复制日志"); }
        });
        root.addView(watchdogExport, matchWithTop(8));
        root.addView(label("远程通话时每 2 秒复检静音状态，受控修复后再次验证。脱敏 VERBOSE 快照自动保存在本机；系统标志不能保证实际扬声器无声。",
                12, MUTED, Gravity.START), matchWithTop(8));

        LinearLayout live = card(SURFACE, 20);
        live.setOrientation(LinearLayout.HORIZONTAL);
        live.setGravity(Gravity.CENTER_VERTICAL);
        live.setPadding(dp(16), dp(14), dp(12), dp(14));
        LinearLayout liveCopy = column(0);
        liveCopy.addView(label("实时记录", 15, TEXT, Gravity.START));
        liveCopy.addView(label("自动刷新最新的日志信息", 12, MUTED, Gravity.START));
        live.addView(liveCopy, weighted());
        Switch toggle = new Switch(this);
        toggle.setChecked(realtimeLogging);
        toggle.setThumbTintList(ColorStateList.valueOf(PRIMARY));
        toggle.setOnCheckedChangeListener((ignored, enabled) -> {
            realtimeLogging = enabled;
            handler.removeCallbacks(debugRefresh);
            if (enabled) handler.post(debugRefresh);
        });
        live.addView(toggle);
        root.addView(live, matchWithTop(12));

        LinearLayout destructive = row();
        TextView refresh = secondaryButton("立即刷新");
        refresh.setOnClickListener(ignored -> refreshDebugLog());
        TextView clear = secondaryButton("清空日志");
        clear.setTextColor(DANGER);
        clear.setOnClickListener(ignored -> { BridgeLog.clear(); refreshDebugLog(); });
        destructive.addView(refresh, weightedWithEnd(5));
        destructive.addView(clear, weightedWithStart(5));
        root.addView(destructive, matchWithTop(10));
        refreshDebugLog();
        return scroll(root);
    }

    private View settingsPage() {
        LinearLayout root = pageRoot();
        root.addView(pageTitle("设置", null));

        boolean standaloneRuntime = RuntimeMode.isStandalone(this);
        root.addView(sectionTitle(RuntimeMode.agentLabel(this)), matchWithTop(18));
        LinearLayout agentCard = card(SURFACE, 22);
        agentCard.setOrientation(LinearLayout.VERTICAL);
        agentCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        if (standaloneRuntime) {
            agentCard.addView(label("Agent 运行在本 APK 的前台服务中，不使用 AVF、Linux Terminal、8575 或 8576。",
                    14, TEXT, Gravity.START));
        } else {
            endpoint = input("Agent 地址", InputType.TYPE_CLASS_TEXT);
            endpoint.setText(AppConfig.endpoint(this));
            agentCard.addView(endpoint);
            token = input("控制令牌", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
            token.setText(AppConfig.token(this));
            agentCard.addView(token, matchWithTop(10));
        }
        selectedMode = AppConfig.mode(this);
        agentCard.addView(modeSelector(), matchWithTop(12));
        TextView save = primaryButton(standaloneRuntime ? "保存模式并启动内置 Agent" : "保存配置并启动守护", BLUE);
        save.setOnClickListener(ignored -> saveConfiguration());
        agentCard.addView(save, matchWithTop(12));
        root.addView(agentCard, matchWithTop(10));

        root.addView(sectionTitle("默认通话卡"), matchWithTop(22));
        LinearLayout callAccountCard = card(SURFACE, 22);
        callAccountCard.setOrientation(LinearLayout.VERTICAL);
        callAccountCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        DefaultCallAccount.Snapshot accounts = DefaultCallAccount.snapshot(this);
        String accountKey = DefaultCallAccount.selectedKey(this);
        boolean available = accountKey.isEmpty() || accounts.accounts().stream()
                .anyMatch(account -> account.key().equals(accountKey));
        callAccountCard.addView(label(DefaultCallAccount.selectedLabel(this)
                + (available ? "" : " · 当前不可用"), 14, available ? TEXT : WARNING, Gravity.START));
        callAccountCard.addView(description("用于 AirSIM 蓝牙、VoWLAN 与云端拨号，不改变系统通话卡或短信卡。"
                + "指定卡关闭或移除时会停止拨号，请重新选择。"), matchWithTop(6));
        if (!accounts.error().isEmpty()) {
            callAccountCard.addView(description(accounts.error()), matchWithTop(6));
        } else if (accounts.accounts().isEmpty()) {
            callAccountCard.addView(description("没有已启用的蜂窝通话卡"), matchWithTop(6));
        }
        TextView chooseAccount = secondaryButton("选择默认通话卡");
        chooseAccount.setOnClickListener(ignored -> chooseDefaultCallAccount());
        callAccountCard.addView(chooseAccount, matchWithTop(10));
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            TextView grantAccountPermission = secondaryButton("授权读取通话卡");
            grantAccountPermission.setOnClickListener(ignored -> requestPermissions(
                    new String[] {Manifest.permission.READ_PHONE_STATE}, CALL_ACCOUNT_PERMISSION_REQUEST));
            callAccountCard.addView(grantAccountPermission, matchWithTop(10));
        }
        root.addView(callAccountCard, matchWithTop(10));

        root.addView(sectionTitle("VoBLE 蓝牙认证"), matchWithTop(22));
        LinearLayout voBLECard = card(SURFACE, 22);
        voBLECard.setOrientation(LinearLayout.VERTICAL);
        voBLECard.setPadding(dp(16), dp(16), dp(16), dp(16));
        boolean voBLEPaired = com.airsim.phonecontrol.voble.VoBLEGatewayService
                .hasStoredCredential(this);
        voBLECard.addView(label(voBLEPaired ? "已保存 iPhone 认证凭据" : "尚未保存认证凭据",
                14, voBLEPaired ? PRIMARY : MUTED, Gravity.START));
        voBLECard.addView(description("管理六位安全码认证、旧凭据恢复与双端取消配对。"),
                matchWithTop(6));
        TextView configureVoBLE = secondaryButton("打开 VoBLE 认证配置");
        configureVoBLE.setOnClickListener(ignored -> openVoBLEAuthenticationPage());
        voBLECard.addView(configureVoBLE, matchWithTop(10));
        root.addView(voBLECard, matchWithTop(10));

		root.addView(sectionTitle("短信收件箱兜底"), matchWithTop(22));
		LinearLayout smsCard = card(SURFACE, 22);
		smsCard.setOrientation(LinearLayout.VERTICAL);
		smsCard.setPadding(dp(16), dp(16), dp(16), dp(16));
		boolean inboxGranted = checkSelfPermission(Manifest.permission.READ_SMS)
				== PackageManager.PERMISSION_GRANTED;
		smsCard.addView(label(inboxGranted ? "已授权 · 仅扫描新收到的短信"
				: "未授权 · 继续使用短信广播接收", 14, TEXT, Gravity.START));
		smsCard.addView(description("可选权限；用于广播未送达时补取新短信，不导入历史短信。"), matchWithTop(6));
		if (!inboxGranted) {
			TextView permissionAction = secondaryButton("在系统设置中授权读取短信");
			permissionAction.setOnClickListener(ignored -> startActivity(new Intent(
					Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
					Uri.parse("package:" + getPackageName()))));
			smsCard.addView(permissionAction, matchWithTop(10));
		}
		root.addView(smsCard, matchWithTop(10));

		if (!standaloneRuntime) {
		root.addView(sectionTitle("AVF Linux 首次安装"), matchWithTop(22));
		LinearLayout bootstrapCard = card(SURFACE, 22);
		bootstrapCard.setOrientation(LinearLayout.VERTICAL);
		bootstrapCard.setPadding(dp(16), dp(16), dp(16), dp(16));
		AVFEnvironmentDetector.Snapshot avf = AVFEnvironmentDetector.inspect(this);
		bootstrapCard.addView(label(avfEnvironmentSummary(avf), 14, TEXT, Gravity.START));
		TextView installCommand = label(AVFStartupPolicy.installCommand(), 12, MUTED, Gravity.START);
		installCommand.setTextIsSelectable(true);
		installCommand.setPadding(0, dp(10), 0, dp(4));
		bootstrapCard.addView(installCommand);
		LinearLayout bootstrapActions = row();
		TextView copyInstall = secondaryButton("复制一键安装命令");
		copyInstall.setOnClickListener(ignored -> copyAVFInstallCommand());
		TextView openLinux = secondaryButton(avf.state() == AVFStartupPolicy.State.RUNNING
				? "打开 Linux Terminal" : "启动 Linux Terminal");
		openLinux.setOnClickListener(ignored -> openAVFTerminalOrSettings());
		bootstrapActions.addView(copyInstall, weightedWithEnd(5));
		bootstrapActions.addView(openLinux, weightedWithStart(5));
		bootstrapCard.addView(bootstrapActions, matchWithTop(10));
		TextView developerOptions = secondaryButton("打开开发者选项");
		developerOptions.setOnClickListener(ignored -> AVFEnvironmentActions.openDeveloperOptions(this));
		bootstrapCard.addView(developerOptions, matchWithTop(10));
		root.addView(bootstrapCard, matchWithTop(10));

		root.addView(sectionTitle("AVF Agent 管理"), matchWithTop(22));
		LinearLayout installerCard = card(SURFACE, 22);
		installerCard.setOrientation(LinearLayout.VERTICAL);
		installerCard.setPadding(dp(16), dp(16), dp(16), dp(16));
		installerStatus = label("正在读取 installerd 状态…", 13, MUTED, Gravity.START);
		installerCard.addView(installerStatus);
		TextView updateAgent = primaryButton("检查并安装最新 Agent", BLUE);
		updateAgent.setOnClickListener(ignored -> runAgentMaintenance("update"));
		installerCard.addView(updateAgent, matchWithTop(12));
		LinearLayout installerActions = row();
		TextView repairAgent = secondaryButton("修复当前版本");
		repairAgent.setOnClickListener(ignored -> runAgentMaintenance("repair"));
		TextView rollbackAgent = secondaryButton("回滚上一版本");
		rollbackAgent.setTextColor(WARNING);
		rollbackAgent.setOnClickListener(ignored -> runAgentMaintenance("rollback"));
		installerActions.addView(repairAgent, weightedWithEnd(5));
		installerActions.addView(rollbackAgent, weightedWithStart(5));
		installerCard.addView(installerActions, matchWithTop(10));
		root.addView(installerCard, matchWithTop(10));
		refreshInstallerStatus();
		}

        root.addView(sectionTitle("Shizuku / Root 权限与 PCM 桥"), matchWithTop(22));
        LinearLayout shizukuCard = card(SURFACE, 22);
        shizukuCard.setOrientation(LinearLayout.VERTICAL);
        shizukuCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        shizukuStatus = label("", 14, TEXT, Gravity.START);
        shizukuCard.addView(shizukuStatus);
        shizukuCard.addView(description("通话音频桥需要 Shizuku 或 KernelSU Root。自动模式优先 Root，失败回 Shizuku。"), matchWithTop(6));

        privilegeChannelGroup = new RadioGroup(this);
        privilegeChannelGroup.setOrientation(RadioGroup.VERTICAL);
        privilegeChannelGroup.setId(View.generateViewId());
        privilegeChannelIDs.clear();
        PrivilegeChannelPreference.Channel currentChannel = PrivilegeChannelPreference.get(this);
        for (PrivilegeChannelPreference.Channel channel : PrivilegeChannelPreference.Channel.values()) {
            RadioButton option = new RadioButton(this);
            option.setText(PrivilegeChannelPreference.label(channel));
            option.setTextColor(TEXT);
            option.setButtonTintList(ColorStateList.valueOf(PRIMARY));
            option.setId(View.generateViewId());
            privilegeChannelIDs.put(option.getId(), channel);
            privilegeChannelGroup.addView(option);
            if (channel == currentChannel) option.setChecked(true);
        }
        privilegeChannelGroup.setOnCheckedChangeListener((group, checkedId) -> {
            if (updatingPrivilegeChannel) return;
            PrivilegeChannelPreference.Channel selected = privilegeChannelIDs.get(checkedId);
            if (selected == null) return;
            ShizukuBridgeManager.get(this).setPrivilegeChannel(selected);
            refreshShizukuStatus();
            toast("权限通道已切换");
        });
        shizukuCard.addView(privilegeChannelGroup, matchWithTop(8));
        shizukuCard.addView(description("切换通道会重建 PCM 桥；选择 Root 后首次会请求 KernelSU 授权。"), matchWithTop(4));

        LinearLayout shizukuActions = row();
        TextView authorize = secondaryButton("授权并启动");
        authorize.setOnClickListener(ignored -> {
            ShizukuBridgeManager.get(this).requestPermission();
            refreshShizukuStatus();
        });
        TextView open = secondaryButton("打开 Shizuku");
        open.setOnClickListener(ignored -> {
            ShizukuBridgeManager.get(this).openShizuku();
            refreshShizukuStatus();
        });
        shizukuActions.addView(authorize, weightedWithEnd(5));
        shizukuActions.addView(open, weightedWithStart(5));
        shizukuCard.addView(shizukuActions, matchWithTop(12));

        LinearLayout rootActions = row();
        TextView rootAuth = secondaryButton("Root 授权 / 重试");
        rootAuth.setOnClickListener(ignored -> {
            ShizukuBridgeManager.get(this).requestRootPermission();
            refreshShizukuStatus();
            toast("正在请求 Root 授权");
        });
        TextView refreshChannel = secondaryButton("刷新通道状态");
        refreshChannel.setOnClickListener(ignored -> refreshShizukuStatus());
        rootActions.addView(rootAuth, weightedWithEnd(5));
        rootActions.addView(refreshChannel, weightedWithStart(5));
        shizukuCard.addView(rootActions, matchWithTop(10));
        root.addView(shizukuCard, matchWithTop(10));

        root.addView(sectionTitle("私有网络与端口"), matchWithTop(22));
        LinearLayout networkCard = card(SURFACE, 22);
        networkCard.setOrientation(LinearLayout.VERTICAL);
        networkCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        networkCard.addView(description("内置已支持 10/8、172.16/12、192.168/16、169.254/16、100.64/10（Tailscale）。"
                + "如局域网使用其他网段，请在此追加，例如 30.0.0.0/8。"), matchWithTop(0));
        EditText rangesInput = new EditText(this);
        rangesInput.setText(NetworkSettings.rangesText(this));
        rangesInput.setHint("例如 30.0.0.0/8, 100.64.0.0/10");
        rangesInput.setTextColor(TEXT);
        rangesInput.setHintTextColor(MUTED);
        rangesInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        networkCard.addView(rangesInput, matchWithTop(10));

        networkCard.addView(description("首选端口（1024–65535；被占用或受限时会自动改用空闲端口，"
                + "Bonjour 通告实际端口）。留 0 表示自动选择。"), matchWithTop(12));
        EditText controlInput = portField("VoWLAN 控制端口", NetworkSettings.controlPort(this));
        networkCard.addView(controlInput, matchWithTop(8));
        EditText pcmInput = portField("VoWLAN PCM 端口", NetworkSettings.pcmPort(this));
        networkCard.addView(pcmInput, matchWithTop(6));
        EditText pairingInput = portField("配对端口（0 = 自动）", NetworkSettings.pairingPort(this));
        networkCard.addView(pairingInput, matchWithTop(6));

        TextView saveNetwork = primaryButton("保存网络与端口设置", BLUE);
        saveNetwork.setOnClickListener(ignored -> {
            String text = rangesInput.getText().toString().trim();
            java.util.List<String> invalid = new java.util.ArrayList<>();
            for (String item : text.split("[,\\s]+")) {
                if (!item.isEmpty() && PrivateNetworkPolicy.parse(item) == null) invalid.add(item);
            }
            if (!invalid.isEmpty()) {
                toast("网段格式无效：" + String.join(", ", invalid));
                return;
            }
            int control = parsePort(controlInput, NetworkSettings.DEFAULT_CONTROL_PORT);
            int pcm = parsePort(pcmInput, NetworkSettings.DEFAULT_PCM_PORT);
            int pairing = parsePort(pairingInput, NetworkSettings.DEFAULT_PAIRING_PORT);
            if (control < 0 || pcm < 0 || pairing < 0) {
                toast("端口需在 1024–65535 之间，配对端口可填 0");
                return;
            }
            if (control == pcm) {
                toast("控制端口与 PCM 端口不能相同");
                return;
            }
            NetworkSettings.setRangesText(this, text);
            NetworkSettings.setPorts(this, control, pcm, pairing);
            VoWLANGatewayService.restartAfterSettingsChange(this);
            toast("已保存；VoWLAN 网关正在按新端口重启");
        });
        networkCard.addView(saveNetwork, matchWithTop(14));
        root.addView(networkCard, matchWithTop(10));

        root.addView(sectionTitle("电话角色与诊断"), matchWithTop(22));
        TextView dialer = secondaryButton("设为默认电话应用");
        dialer.setOnClickListener(ignored -> requestDialerRole());
        root.addView(dialer, matchWithTop(10));
        TextView agent = secondaryButton("刷新 Agent 状态");
        agent.setOnClickListener(ignored -> refreshAgent(true));
        root.addView(agent, matchWithTop(10));
        agentRefreshResult = label(agentRefreshMessage, 12, agentRefreshColor, Gravity.START);
        agentRefreshResult.setPadding(dp(12), dp(8), dp(12), dp(8));
        agentRefreshResult.setBackground(rounded(SURFACE, 12, BORDER, 1));
        root.addView(agentRefreshResult, matchWithTop(6));
        TextView heartbeat = secondaryButton("立即发送云端心跳");
        TextView heartbeatResult = description("仅检查注册和心跳，不拨号、不发送短信；纯本地模式下禁止发送。");
        heartbeat.setOnClickListener(ignored -> {
            if (!heartbeat.isEnabled()) return;
            heartbeat.setEnabled(false);
            heartbeatResult.setText("正在发送，请稍候…");
            new Thread(() -> {
                String message;
                try {
                    if (RelayEgressGate.shared.isBlocked()) throw new IllegalStateException("纯本地模式已开启，禁止发送云端心跳");
                    if (RuntimeMode.isStandalone(this)) StandaloneAgentService.sendManualHeartbeat();
                    else if (!new JSONObject(new AgentClient(this).sendHeartbeat()).optBoolean("accepted", false))
                        throw new IllegalStateException("Agent 未确认心跳已被接受，请升级 Agent 后重试");
                    message = "Relay 已接受心跳，请在 iPhone 重新运行云端自检。此结果不代表通话链路已通过。";
                } catch (Exception error) {
                    message = "心跳发送失败：" + DebugRedactor.sanitize(String.valueOf(error.getMessage()));
                    BridgeLog.error("manual_heartbeat_failed", error);
                }
                final String result = message;
                runOnUiThread(() -> { heartbeat.setEnabled(true); heartbeatResult.setText(result); });
            }, "AirSIMManualHeartbeat").start();
        });
        root.addView(heartbeat, matchWithTop(10));
        root.addView(heartbeatResult, matchWithTop(6));

        CheckBox debugEnabled = new CheckBox(this);
        debugEnabled.setText("启用 Debug 模式");
        debugEnabled.setTextColor(TEXT);
        debugEnabled.setButtonTintList(ColorStateList.valueOf(PRIMARY));
        debugEnabled.setChecked(AppConfig.debugEnabled(this));
        debugEnabled.setOnCheckedChangeListener((ignored, enabled) -> {
            BridgeLog.setDebugEnabled(this, enabled);
            toast(enabled ? "Debug 日志已开启" : "Debug 日志已关闭");
        });
        root.addView(debugEnabled, matchWithTop(14));
        root.addView(sectionTitle("关于"), matchWithTop(22));
        LinearLayout aboutCard = card(SURFACE, 22);
        aboutCard.setOrientation(LinearLayout.VERTICAL);
        aboutCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        aboutCard.addView(label("AirSIM · " + RuntimeMode.agentLabel(this), 16, TEXT, Gravity.START));
        TextView version = label("版本 " + AppInformation.version(this), 14, MUTED, Gravity.START);
        version.setTextIsSelectable(true);
        aboutCard.addView(version, matchWithTop(6));
        TextView notes = secondaryButton("当前版本更新内容");
        notes.setOnClickListener(ignored -> appUpdates.showNotes(() -> {}));
        aboutCard.addView(notes, matchWithTop(10));
        TextView appCheck = secondaryButton("检查应用更新");
        appCheck.setOnClickListener(ignored -> appUpdates.check(true));
        aboutCard.addView(appCheck, matchWithTop(10));
        aboutCard.addView(description(appUpdates.status()), matchWithTop(6));
        TextView repository = secondaryButton("GitHub 仓库");
        repository.setOnClickListener(ignored -> openProjectURL(AppInformation.REPOSITORY_URL));
        aboutCard.addView(repository, matchWithTop(12));
        TextView releases = secondaryButton("版本发布与下载");
        releases.setOnClickListener(ignored -> openProjectURL(AppInformation.RELEASES_URL));
        aboutCard.addView(releases, matchWithTop(10));
        root.addView(aboutCard, matchWithTop(10));

        root.addView(sectionTitle("反馈"), matchWithTop(22));
        LinearLayout feedbackCard = card(SURFACE, 22);
        feedbackCard.setOrientation(LinearLayout.VERTICAL);
        feedbackCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        feedbackCard.addView(description("仅手动上传脱敏日志到 Notion；不上传短信内容或密钥。"));
        EditText feedbackDescription = input("用户描述（可选）", InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        feedbackDescription.setSingleLine(false);
        feedbackDescription.setMinLines(2);
        feedbackDescription.setText(FeedbackUploader.description(this));
        feedbackCard.addView(feedbackDescription, matchWithTop(10));
        feedbackCard.addView(feedbackPasteButton(feedbackDescription, "粘贴到描述"), matchWithTop(6));
        EditText feedbackRemark = input("备注（可选）", InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        feedbackRemark.setSingleLine(false);
        feedbackRemark.setMinLines(2);
        feedbackRemark.setText(FeedbackUploader.remark(this));
        feedbackCard.addView(feedbackRemark, matchWithTop(8));
        feedbackCard.addView(feedbackPasteButton(feedbackRemark, "粘贴到备注"), matchWithTop(6));
        TextView uploadFeedback = secondaryButton("保存并立即上传反馈");
        uploadFeedback.setOnClickListener(ignored -> {
            FeedbackUploader.setFields(this, feedbackDescription.getText().toString(),
                    feedbackRemark.getText().toString());
            FeedbackUploader.submit(this, "manual", "manual:" + UUID.randomUUID());
            toast("反馈已提交，正在上传");
        });
        feedbackCard.addView(uploadFeedback, matchWithTop(12));
        root.addView(feedbackCard, matchWithTop(10));
        refreshShizukuStatus();
        return scroll(root);
    }

    private TextView feedbackPasteButton(EditText input, String title) {
        input.setLongClickable(true);
        input.setSelectAllOnFocus(false);
        input.setGravity(Gravity.TOP | Gravity.START);
        TextView button = secondaryButton(title);
        button.setOnClickListener(ignored -> {
            ClipboardManager clipboard = getSystemService(ClipboardManager.class);
            android.content.ClipData clip = clipboard == null ? null : clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0 || clip.getItemAt(0).getText() == null) {
                toast("剪贴板没有可粘贴的文字"); return;
            }
            int start = Math.max(0, input.getSelectionStart());
            int end = Math.max(0, input.getSelectionEnd());
            input.getText().replace(Math.min(start, end), Math.max(start, end), clip.getItemAt(0).getText());
            input.requestFocus();
        });
        return button;
    }

    private void openProjectURL(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (android.content.ActivityNotFoundException ignored) {
            toast("没有可打开网页的浏览器");
        }
    }

    private void openPairingPage() {
        handler.removeCallbacks(debugRefresh);
        voBLEAuthenticationVisible = false;
        handler.removeCallbacks(voBLEAuthenticationRefresh);
        bottomBar.setVisibility(View.GONE);
        contentHost.removeAllViews();
        contentHost.addView(pairingPage(), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        startPairing();
    }

    private void openVoBLEAuthenticationPage() {
        handler.removeCallbacks(debugRefresh);
        handler.removeCallbacks(voBLEAuthenticationRefresh);
        voBLEAuthenticationVisible = true;
        bottomBar.setVisibility(View.GONE);
        contentHost.removeAllViews();
        contentHost.addView(voBLEAuthenticationPage(), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        handler.post(voBLEAuthenticationRefresh);
    }

    private View voBLEAuthenticationPage() {
        LinearLayout root = pageRoot();
        TextView back = label("‹", 40, TEXT, Gravity.START);
        back.setContentDescription("返回设置");
        back.setOnClickListener(ignored -> {
            bottomBar.setVisibility(View.VISIBLE);
            showPage(Page.SETTINGS);
        });
        root.addView(back, new LinearLayout.LayoutParams(dp(56), dp(52)));

        TextView title = label("VoBLE 认证", 30, TEXT, Gravity.START);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title, matchWithTop(8));
        root.addView(description("蓝牙是独立连接模式；认证凭据不会影响 VoWLAN 或云端 Relay。"),
                matchWithTop(6));

        boolean permissions = hasVoBLEPermissions();
        boolean paired = com.airsim.phonecontrol.voble.VoBLEGatewayService
                .hasStoredCredential(this);
        LinearLayout statusCard = card(SURFACE, 22);
        statusCard.setOrientation(LinearLayout.VERTICAL);
        statusCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        statusCard.addView(overline("认证状态"));
        voBLEAuthenticationStatusView = label(
                MainScreenPresentation.voBLEAuthenticationStatus(
                        paired,
                        com.airsim.phonecontrol.voble.VoBLEGatewayService.isAuthenticated(),
                        com.airsim.phonecontrol.voble.VoBLEGatewayService.pendingPairingCode()),
                19, paired ? PRIMARY : WARNING, Gravity.START);
        statusCard.addView(voBLEAuthenticationStatusView, matchWithTop(7));
        statusCard.addView(label(permissions ? "蓝牙权限：已授权" : "蓝牙权限：需要授权",
                13, permissions ? MUTED : WARNING, Gravity.START), matchWithTop(7));
        voBLEDiagnosticsView = label(
                com.airsim.phonecontrol.voble.VoBLEGatewayService.diagnosticsSummary(),
                13, MUTED, Gravity.START);
        statusCard.addView(voBLEDiagnosticsView, matchWithTop(7));
        statusCard.addView(overline("六位安全码"), matchWithTop(18));
        voBLEPairingCodeView = label(
                MainScreenPresentation.voBLEPairingCode(
                        com.airsim.phonecontrol.voble.VoBLEGatewayService.pendingPairingCode()),
                28, MUTED, Gravity.CENTER);
        voBLEPairingCodeView.setTypeface(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD));
        statusCard.addView(voBLEPairingCodeView, matchWithTop(8));
        root.addView(statusCard, matchWithTop(18));

        LinearLayout flowCard = card(SURFACE, 22);
        flowCard.setOrientation(LinearLayout.VERTICAL);
        flowCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        flowCard.addView(overline("认证流程"));
        flowCard.addView(label("1. iPhone 扫描并连接此 Android Agent\n"
                        + "2. 两端核对同一组六位安全码\n"
                        + "3. 确认后保存应用层密钥并开放拨号与 PCM 音频",
                14, TEXT, Gravity.START), matchWithTop(8));
        flowCard.addView(description("如果 iPhone 显示 already paired 或认证失败，表示两端旧密钥不一致。"
                + "请在此页清除旧凭据，再回到 iPhone 重新配对。"), matchWithTop(10));
        root.addView(flowCard, matchWithTop(12));

        TextView restart = secondaryButton("重启 VoBLE 服务");
        restart.setOnClickListener(ignored -> {
            com.airsim.phonecontrol.voble.VoBLEGatewayService.start(this);
            toast("VoBLE 服务已启动");
            openVoBLEAuthenticationPage();
        });
        root.addView(restart, matchWithTop(16));

        voBLEClearCredentialButton = secondaryButton("清除 VoBLE 配对凭据");
        voBLEClearCredentialButton.setTextColor(paired ? DANGER : MUTED);
        voBLEClearCredentialButton.setEnabled(paired);
        voBLEClearCredentialButton.setOnClickListener(ignored -> new AlertDialog.Builder(this)
                .setTitle("清除旧的 VoBLE 配对？")
                .setMessage("仅删除蓝牙认证密钥并结束当前 VoBLE 会话；不会清除 VoWLAN、Relay 或通话记录。")
                .setPositiveButton("清除并重新配对", (dialog, which) -> {
                    com.airsim.phonecontrol.voble.VoBLEGatewayService.clearStoredCredential(this);
                    handler.postDelayed(() -> {
                        toast("VoBLE 旧凭据已清除");
                        openVoBLEAuthenticationPage();
                    }, 150);
                })
                .setNegativeButton("取消", null)
                .show());
        root.addView(voBLEClearCredentialButton, matchWithTop(10));
        return scroll(root);
    }

    private void renderVoBLEAuthenticationStatus() {
        boolean stored = com.airsim.phonecontrol.voble.VoBLEGatewayService
                .hasStoredCredential(this);
        boolean authenticated = com.airsim.phonecontrol.voble.VoBLEGatewayService.isAuthenticated();
        String pairingCode = com.airsim.phonecontrol.voble.VoBLEGatewayService.pendingPairingCode();
        if (voBLEAuthenticationStatusView != null) {
            voBLEAuthenticationStatusView.setText(MainScreenPresentation.voBLEAuthenticationStatus(
                    stored, authenticated, pairingCode));
            voBLEAuthenticationStatusView.setTextColor(
                    authenticated || stored ? PRIMARY : WARNING);
        }
        if (voBLEPairingCodeView != null) {
            String formatted = MainScreenPresentation.formatPairingCode(pairingCode);
            voBLEPairingCodeView.setText(MainScreenPresentation.voBLEPairingCode(pairingCode));
            voBLEPairingCodeView.setTextColor("--- ---".equals(formatted) ? MUTED : PRIMARY);
        }
        if (voBLEDiagnosticsView != null) {
            voBLEDiagnosticsView.setText(
                    com.airsim.phonecontrol.voble.VoBLEGatewayService.diagnosticsSummary());
        }
        if (voBLEClearCredentialButton != null) {
            voBLEClearCredentialButton.setEnabled(stored);
            voBLEClearCredentialButton.setTextColor(stored ? DANGER : MUTED);
        }
    }

    private View pairingPage() {
        LinearLayout root = pageRoot();
        TextView back = label("‹", 40, TEXT, Gravity.START);
        back.setContentDescription("返回");
        back.setOnClickListener(ignored -> {
            stopPairingServer();
            showPage(Page.STATUS);
        });
        root.addView(back, new LinearLayout.LayoutParams(dp(56), dp(52)));

        TextView title = label("一次性配对", 30, TEXT, Gravity.START);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title, matchWithTop(8));
        root.addView(description("让 iPhone 与三星连接同一 Wi‑Fi 或三星热点"), matchWithTop(6));

        LinearLayout pairingCard = card(SURFACE, 28);
        pairingCard.setOrientation(LinearLayout.VERTICAL);
        pairingCard.setGravity(Gravity.CENTER_HORIZONTAL);
        pairingCard.setPadding(dp(20), dp(24), dp(20), dp(24));
        pairingCard.addView(label("配对码（一次性）", 14, MUTED, Gravity.CENTER));
        pairingCodeView = label(
                MainScreenPresentation.formatPairingCode(pairingCode), 42, TEXT, Gravity.CENTER);
        pairingCodeView.setTypeface(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD));
        pairingCodeView.setLetterSpacing(0.05f);
        pairingCodeView.setBackground(rounded(Color.rgb(20, 32, 45), 18, BORDER, 1));
        pairingCodeView.setPadding(dp(18), dp(18), dp(18), dp(18));
        pairingCard.addView(pairingCodeView, matchWithTop(18));

        pairingCountdownView = label("正在生成安全密钥…", 14, Color.rgb(135, 183, 238), Gravity.CENTER);
        pairingCard.addView(pairingCountdownView, matchWithTop(16));

        ImageView link = icon(android.R.drawable.ic_menu_share, CYAN, 92);
        link.setPadding(dp(22), dp(22), dp(22), dp(22));
        pairingCard.addView(link, new LinearLayout.LayoutParams(dp(112), dp(112)));

        pairingStatus = label("正在检查局域网并生成临时密钥…", 15, TEXT, Gravity.CENTER);
        pairingStatus.setMaxLines(4);
        pairingCard.addView(pairingStatus, matchWithTop(10));
        root.addView(pairingCard, matchWithTop(20));

        TextView cancel = secondaryButton("取消配对");
        cancel.setTextColor(DANGER);
        cancel.setOnClickListener(ignored -> {
            stopPairingServer();
            showPage(Page.STATUS);
        });
        root.addView(cancel, matchWithTop(18));

        TextView note = label("临时密钥 · 仅可使用一次", 13, MUTED, Gravity.CENTER);
        note.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_lock_idle_lock, 0, 0, 0);
        note.setCompoundDrawableTintList(ColorStateList.valueOf(MUTED));
        note.setCompoundDrawablePadding(dp(8));
        root.addView(note, matchWithTop(20));
        return scroll(root);
    }

    private View smsAssistCard() {
        boolean enabled = SmsConfirmationAccessibilityService.isEnabled(this);
        LinearLayout card = card(SURFACE, 20);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(16), dp(14), dp(16), dp(14));
        LinearLayout header = row();
        header.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout copy = column(0);
        copy.addView(overline("短信辅助操控"));
        copy.addView(label(enabled ? "已开启 · 小米发送确认弹窗可自动点击" : "未开启 · 仅影响小米发送确认弹窗",
                13, enabled ? PRIMARY : MUTED, Gravity.START), matchWithTop(3));
        header.addView(copy, weighted());
        card.addView(header);
        card.addView(description("仅在 AirSIM 发起系统短信、且小米弹出“是否发送短信”时点击“发送/允许”。不会读取或保存短信内容。"), matchWithTop(6));
        LinearLayout actions = row();
        TextView open = secondaryButton(enabled ? "查看辅助操控设置" : "打开辅助操控权限");
        open.setTextColor(PRIMARY);
        open.setOnClickListener(ignored -> {
            try {
                startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
            } catch (RuntimeException error) {
                toast("无法打开辅助操控设置，请在系统设置中手动搜索“辅助功能”");
            }
        });
        TextView logs = secondaryButton("短信日志");
        logs.setOnClickListener(ignored -> {
            activeDebugFilter = "SMS";
            showPage(Page.DEBUG);
        });
        actions.addView(open, weightedWithEnd(6));
        actions.addView(logs, weightedWithStart(4));
        card.addView(actions, matchWithTop(8));
        boolean notificationAccess = SmsNotificationListenerService.isEnabled(this);
        TextView notification = secondaryButton(notificationAccess
                ? "回信通知读取 · 已授权"
                : "开启回信通知读取（小米推荐）");
        notification.setTextColor(notificationAccess ? MUTED : PRIMARY);
        notification.setOnClickListener(ignored -> {
            try {
                startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS));
            } catch (RuntimeException error) {
                toast("无法打开通知读取设置，请在系统设置中搜索“通知使用权”");
            }
        });
        card.addView(notification, matchWithTop(6));
        card.addView(description("小米限制非默认短信 App 读取 inbox。开启通知读取后，只转发 com.android.mms 的新短信通知到 iPhone；发送确认仍由上面的辅助操控处理。"), matchWithTop(4));
        return card;
    }

    private LinearLayout debugFilters() {
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        LinearLayout filterRow = row();
        String[] filters = {"全部", "Agent", "SMS", "VoBLE", "VoWLAN", "PCM", "Telecom"};
        for (String filter : filters) {
            boolean selected = filter.equals(activeDebugFilter);
            TextView chip = label(filter, 13, selected ? BG : TEXT, Gravity.CENTER);
            chip.setTypeface(Typeface.DEFAULT, selected ? Typeface.BOLD : Typeface.NORMAL);
            chip.setPadding(dp(16), dp(9), dp(16), dp(9));
            chip.setBackground(rounded(selected ? PRIMARY : SURFACE_HIGH, 18, selected ? PRIMARY : BORDER, 1));
            LinearLayout.LayoutParams chipParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            chipParams.rightMargin = dp(8);
            filterRow.addView(chip, chipParams);
            chip.setOnClickListener(ignored -> {
                activeDebugFilter = filter;
                showPage(Page.DEBUG);
            });
        }
        scroll.addView(filterRow);
        LinearLayout holder = column(0);
        holder.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return holder;
    }

    private View modeSelector() {
        selectedMode = selectedMode == null ? AppConfig.mode(this) : selectedMode;
        LinearLayout segment = row();
        segment.setPadding(dp(3), dp(3), dp(3), dp(3));
        segment.setBackground(rounded(SURFACE_HIGH, 24, BORDER, 1));
        segment.addView(segmentItem("远端静默", AppConfig.MODE_REMOTE_SILENT), weighted());
        segment.addView(segmentItem("本机显示", AppConfig.MODE_LOCAL_AND_PUSH), weighted());
        return segment;
    }

    private TextView segmentItem(String title, String mode) {
        boolean selected = mode.equals(selectedMode);
        TextView item = label(title, 14, selected ? PRIMARY : MUTED, Gravity.CENTER);
        item.setTypeface(Typeface.DEFAULT, selected ? Typeface.BOLD : Typeface.NORMAL);
        item.setPadding(dp(8), dp(12), dp(8), dp(12));
        item.setBackground(rounded(selected ? Color.rgb(19, 70, 61) : Color.TRANSPARENT,
                20, selected ? PRIMARY : Color.TRANSPARENT, 1));
        item.setOnClickListener(ignored -> {
            selectedMode = mode;
            // Persist immediately: previously this only changed a local field and
            // only took effect if the user later found the separate Save button.
            AppConfig.setMode(this, mode);
            if (currentPage == Page.STATUS || currentPage == Page.SETTINGS) showPage(currentPage);
        });
        return item;
    }

    private static final class HealthTile {
        final LinearLayout view;
        final ImageView icon;
        final TextView state;

        HealthTile(LinearLayout view, ImageView icon, TextView state) {
            this.view = view;
            this.icon = icon;
            this.state = state;
        }
    }

    private HealthTile healthTile(String title, String value, int iconResource, boolean healthy) {
        LinearLayout tile = card(SURFACE, 18);
        tile.setOrientation(LinearLayout.HORIZONTAL);
        tile.setGravity(Gravity.CENTER_VERTICAL);
        tile.setPadding(dp(12), dp(15), dp(12), dp(15));
        ImageView icon = icon(iconResource, healthy ? PRIMARY : WARNING, 42);
        icon.setBackground(rounded(healthy ? Color.rgb(17, 66, 57) : Color.rgb(76, 58, 25), 21,
                Color.TRANSPARENT, 0));
        icon.setPadding(dp(10), dp(10), dp(10), dp(10));
        tile.addView(icon, new LinearLayout.LayoutParams(dp(44), dp(44)));
        LinearLayout copy = column(dp(10));
        TextView heading = label(title, 13, TEXT, Gravity.START);
        heading.setSingleLine(true);
        heading.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(heading);
        TextView state = label(value, 13, healthy ? PRIMARY : WARNING, Gravity.START);
        state.setTypeface(Typeface.DEFAULT_BOLD);
        state.setSingleLine(true);
        state.setEllipsize(TextUtils.TruncateAt.END);
        copy.addView(state, matchWithTop(4));
        tile.addView(copy, weighted());
        return new HealthTile(tile, icon, state);
    }

    private void renderPCMStatus(boolean running) {
        HealthTile tile = pcmHealthTile;
        if (tile == null || currentPage != Page.STATUS) return;
        int color = running ? PRIMARY : WARNING;
        tile.state.setText(running ? "运行中" : "待启动");
        tile.state.setTextColor(color);
        tile.icon.setImageTintList(ColorStateList.valueOf(color));
        tile.icon.setBackground(rounded(running ? Color.rgb(17, 66, 57) : Color.rgb(76, 58, 25),
                21, Color.TRANSPARENT, 0));
    }

    private LinearLayout pageTitle(String title, String badge) {
        LinearLayout block = column(0);
        TextView heading = label(title, 30, TEXT, Gravity.START);
        heading.setTypeface(Typeface.DEFAULT_BOLD);
        block.addView(heading);
        if (badge != null) {
            TextView chip = label(badge, 13, PRIMARY, Gravity.CENTER);
            chip.setTypeface(Typeface.DEFAULT_BOLD);
            chip.setPadding(dp(12), dp(5), dp(12), dp(5));
            chip.setBackground(rounded(Color.rgb(15, 66, 56), 16, Color.TRANSPARENT, 0));
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            params.topMargin = dp(6);
            block.addView(chip, params);
        }
        return block;
    }

    private void placeSystemCall() {
        String value = number == null ? "" : number.getText().toString().trim();
        if (value.isEmpty()) { toast("请输入号码"); return; }
        if (!dialerRoleHeld()) {
            toast("请先将 AirSIM 设为默认电话应用");
            requestDialerRole();
            return;
        }
        try {
            getSystemService(TelecomManager.class).placeCall(Uri.parse("tel:" + value),
                    DefaultCallAccount.dialExtras(this));
        } catch (RuntimeException error) {
            toast(error.getMessage() == null ? "系统拨号失败" : error.getMessage());
        }
    }

    private void chooseDefaultCallAccount() {
        DefaultCallAccount.Snapshot snapshot = DefaultCallAccount.snapshot(this);
        String[] choices = new String[snapshot.accounts().size() + 1];
        choices[0] = "跟随系统默认";
        String key = DefaultCallAccount.selectedKey(this);
        int checked = key.isEmpty() ? 0 : -1;
        for (int i = 0; i < snapshot.accounts().size(); i++) {
            DefaultCallAccount.Account account = snapshot.accounts().get(i);
            choices[i + 1] = account.label() + (account.number().isEmpty() ? "" : "\n" + account.number());
            if (key.equals(account.key())) checked = i + 1;
        }
        new AlertDialog.Builder(this).setTitle("默认通话卡")
                .setSingleChoiceItems(choices, checked, (dialog, which) -> {
                    if (which == 0) DefaultCallAccount.followSystem(this);
                    else DefaultCallAccount.select(this, snapshot.accounts().get(which - 1));
                    dialog.dismiss();
                    showPage(Page.SETTINGS);
                    toast("已保存默认通话卡");
                }).setNegativeButton("取消", null).show();
    }

    private void continueStartupSetup() {
        if (isFinishing() || isDestroyed() || startupSetupInFlight) return;
        startupSetupPending = true;
        if (!resumed) return;
        if (appUpdates.showStartupNotes(this::continueStartupSetup)) return;
        ShizukuBridgeManager shizuku = ShizukuBridgeManager.get(this);
        ShizukuBridgeManager.StartupSnapshot snapshot = shizuku.startupSnapshot();
        ShizukuStartupPolicy.Prompt prompt = shizukuStartupPolicy.inspect(
                snapshot.installed(), snapshot.running(), snapshot.authorized(), true);
        startupSetupInFlight = true;
        startupSetupPending = false;
        if (prompt != ShizukuStartupPolicy.Prompt.NONE) {
            showShizukuStartupPrompt(prompt);
            return;
        }
        switch (DialerRoleSetupPolicy.initial(
                dialerRoleHeld(), shizuku.dialerRoleAutomationAuthorized())) {
            case COMPLETE -> checkAVFEnvironmentAtStartup();
            case SHIZUKU -> attemptPrivilegedDialerRole(false);
            case SYSTEM_ROLE -> requestDialerRole();
            case SETTINGS -> openDefaultAppsSettings();
        }
    }

    private void scheduleStartupSetup() {
        handler.removeCallbacks(startupSetup);
        handler.postDelayed(startupSetup, 500);
    }

    private void showShizukuStartupPrompt(ShizukuStartupPolicy.Prompt prompt) {
        String title;
        String message;
        String action;
        switch (prompt) {
            case INSTALL -> {
                title = "需要安装 Shizuku";
                message = "AirSIM 的通话音频桥需要 Shizuku。当前未检测到安装；安装后请启动服务并授权 AirSIM。"
                        + "\n\n官方下载：\n" + ShizukuBridgeManager.DOWNLOAD_URL;
                action = "下载 Shizuku";
            }
            case START -> {
                title = "Shizuku 尚未运行";
                message = "已安装 Shizuku，但服务尚未启动。请打开 Shizuku，使用无线调试或 Root 启动服务，再返回 AirSIM。"
                        + "\n\n未就绪时，通话音频无法转送到 iPhone。";
                action = "打开 Shizuku";
            }
            case AUTHORIZE -> {
                title = "需要 Shizuku 授权";
                message = "Shizuku 已运行，但 AirSIM 尚未获授权。请允许 AirSIM 使用 Shizuku，以启动通话音频桥。"
                        + "\n\n若此前拒绝过，请在 Shizuku 的「已授权应用」中允许 AirSIM。";
                action = "授权";
            }
            default -> throw new IllegalArgumentException("No Shizuku prompt to present");
        }
        boolean[] awaitingAction = {false};
        shizukuStartupDialog = new AlertDialog.Builder(this).setTitle(title).setMessage(message)
                .setPositiveButton(action, (dialog, which) -> {
                    if (prompt == ShizukuStartupPolicy.Prompt.AUTHORIZE) {
                        awaitingAction[0] = true;
                        attemptPrivilegedDialerRole(true);
                    } else {
                        awaitingAction[0] = openShizukuStartupAction(prompt);
                    }
                })
                .setNegativeButton("稍后", null).create();
        shizukuStartupDialog.setOnDismissListener(dialog -> {
            shizukuStartupDialog = null;
            if (!awaitingAction[0] && !isFinishing() && !isDestroyed()) {
                startupSetupInFlight = false;
                startupSetupPending = true;
                scheduleStartupSetup();
            }
        });
        shizukuStartupDialog.show();
        if (prompt == ShizukuStartupPolicy.Prompt.INSTALL) {
            TextView text = shizukuStartupDialog.findViewById(android.R.id.message);
            if (text != null) {
                // Selectable URL remains usable even if no browser is installed.
                text.setTextIsSelectable(true);
            }
        }
    }

    private boolean openShizukuStartupAction(ShizukuStartupPolicy.Prompt prompt) {
        try {
            Intent intent = prompt == ShizukuStartupPolicy.Prompt.INSTALL
                    ? new Intent(Intent.ACTION_VIEW, Uri.parse(ShizukuBridgeManager.DOWNLOAD_URL))
                    : getPackageManager().getLaunchIntentForPackage(ShizukuBridgeManager.MANAGER_PACKAGE);
            if (intent == null) {
                toast("无法打开 Shizuku，请从官方下载页安装");
                return false;
            }
            // Keep the return callback in this Activity's task, even if the
            // package manager's launch intent originally had NEW_TASK set.
            intent.setFlags(intent.getFlags() & ~Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivityForResult(intent, SHIZUKU_SETUP_REQUEST);
            return true;
        } catch (RuntimeException error) {
            BridgeLog.error("shizuku_startup_action_failed", error);
            toast("无法打开页面，请复制弹窗中的官方下载地址");
            return false;
        }
    }

    private void completeStartupSetup() {
        startupSetupInFlight = false;
        startupSetupPending = false;
        startupSetupCompleted = true;
        handler.post(this::maybeShowCrashReportPrompt);
    }

    private void requestDialerRole() {
        RoleManager manager = getSystemService(RoleManager.class);
        if (manager == null || !manager.isRoleAvailable(RoleManager.ROLE_DIALER)) {
            toast("设备不支持默认拨号器角色");
            continueAfterSystemRoleRequest();
            return;
        }
        try {
            startActivityForResult(manager.createRequestRoleIntent(RoleManager.ROLE_DIALER), ROLE_REQUEST);
        } catch (RuntimeException error) {
            BridgeLog.error("dialer_role_system_request_failed", error);
            continueAfterSystemRoleRequest();
        }
    }

    private void continueAfterSystemRoleRequest() {
        ShizukuBridgeManager shizuku = ShizukuBridgeManager.get(this);
        switch (DialerRoleSetupPolicy.afterSystemRequest(
                dialerRoleHeld(), shizuku.dialerRoleAutomationAvailable())) {
            case COMPLETE -> checkAVFEnvironmentAtStartup();
            case SHIZUKU -> attemptPrivilegedDialerRole(true);
            case SETTINGS -> openDefaultAppsSettings();
            case SYSTEM_ROLE -> requestDialerRole();
        }
    }

    private void attemptPrivilegedDialerRole(boolean requestPermission) {
        ShizukuBridgeManager.get(this).ensureDialerRole(requestPermission, (success, detail) -> {
            if (isFinishing() || isDestroyed()) return;
            refreshStatus();
            DialerRoleSetupPolicy.Action next = DialerRoleSetupPolicy.afterPrivilegedAttempt(
                    success && dialerRoleHeld());
            if (next == DialerRoleSetupPolicy.Action.COMPLETE) {
                toast("默认电话角色已由系统启用");
                checkAVFEnvironmentAtStartup();
            } else {
                toast(detail + "，请在默认应用中选择 AirSIM");
                openDefaultAppsSettings();
            }
        });
    }

    private void openDefaultAppsSettings() {
        Intent settings = new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS);
        try {
            startActivityForResult(settings, DEFAULT_APPS_REQUEST);
        } catch (RuntimeException error) {
            BridgeLog.error("default_apps_settings_open_failed", error);
            Intent details = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + getPackageName()));
            startActivityForResult(details, DEFAULT_APPS_REQUEST);
        }
    }

    private void localCall(String action) {
        if (!dialerRoleHeld()) {
            toast("当前通话属于其他默认电话应用；请先选择 AirSIM");
            requestDialerRole();
            return;
        }
        String callId = CallRepository.idForAction(action);
        if (callId.isEmpty()) { toast("当前没有可控制的通话"); return; }
        Executors.newSingleThreadExecutor().execute(() -> {
            CallRepository.ActionResult result = CallRepository.execute(
                    MainActivity.this, new AgentCommand(UUID.randomUUID().toString(), action, callId, ""));
            runOnUiThread(() -> toast(result.success ? "Telecom 已确认" : result.error));
        });
    }

    private void refreshAgent() {
        refreshAgent(false);
    }

    private void refreshAgent(boolean showResult) {
        final int generation = ++agentRefreshGeneration;
        agentDetail = "检测中";
        if (showResult) setAgentRefreshMessage("正在请求 " + AppConfig.endpoint(this)
                + " 的 Agent 状态…", MUTED);
        updateVisibleStatus();
        Executors.newSingleThreadExecutor().execute(() -> {
            String address = AppConfig.endpoint(this);
            String path = AppConfig.configured(this) ? "/api/android/status" : "/api/health";
            try {
                boolean paired = AppConfig.configured(this);
                AgentClient client = new AgentClient(this);
                String payload = paired ? client.status() : client.health();
                JSONObject result = new JSONObject(payload);
                boolean healthy = result.optBoolean("ok", false);
                String profile = result.optString("runtime_profile", "未知");
                String detail = paired
                        ? "接口：GET " + path + " · HTTP 200\nAgent：" + address
                                + "\n运行模式：" + profile
                                + " · 待执行命令：" + result.optInt("pending_commands", 0)
                                + "\n最近活动：" + result.optString("last_seen", "未记录")
                        : "接口：GET " + path + " · HTTP 200\nAgent：" + address
                                + "\n版本：" + result.optString("version", "未知")
                                + " · 运行模式：" + profile
                                + "\n控制令牌：尚未配置";
                BridgeLog.info("agent_status_refresh path=" + path + " ok=" + healthy
                        + " profile=" + profile + " endpoint=" + address);
                runOnUiThread(() -> {
                    if (generation != agentRefreshGeneration) return;
                    agentOnline = paired && healthy;
                    agentDetail = healthy
                            ? (paired ? "在线" : "可达 · 尚未配对控制令牌")
                            : "可达 · Agent 报告未就绪";
                    if (showResult) setAgentRefreshMessage(
                            (healthy ? "刷新成功" : "Agent 未就绪") + "\n" + detail,
                            healthy ? PRIMARY : WARNING);
                    updateVisibleStatus();
                });
                try {
                    JSONObject pushStatus = new JSONObject(client.pushStatus());
                    runOnUiThread(() -> {
                        if (generation != agentRefreshGeneration) return;
                        updatePushStatus(pushStatus);
                        updateVisibleStatus();
                    });
                } catch (Exception error) {
                    BridgeLog.error("push_status_refresh_failed endpoint=" + address, error);
                    String pushError = error.getClass().getSimpleName() + " · " + error.getMessage();
                    runOnUiThread(() -> {
                        if (generation != agentRefreshGeneration) return;
                        pushConfigured = false;
                        pushDetail = "状态不可读";
                        cloudRelayConfigured = false;
                        cloudLastError = DebugRedactor.sanitize(pushError);
                        pushDiagnostic = "读取 /api/push/status 失败："
                                + DebugRedactor.sanitize(pushError);
                        updateVisibleStatus();
                    });
                }
            } catch (Exception error) {
                BridgeLog.error("agent_status_refresh_failed path=" + path + " endpoint=" + address, error);
                runOnUiThread(() -> {
                    if (generation != agentRefreshGeneration) return;
                    agentOnline = false;
                    agentDetail = "离线 · " + error.getClass().getSimpleName();
                    pushConfigured = false;
                    pushDetail = "Agent 不可达";
                    cloudRelayConfigured = false;
                    cloudLastError = RuntimeMode.agentLabel(this) + "不可达";
                    pushDiagnostic = "先恢复" + RuntimeMode.agentLabel(this)
                            + "；当前无法查询 /api/push/status。";
                    if (showResult) setAgentRefreshMessage("刷新失败 · GET " + path
                            + "\nAgent：" + address + "\n原因："
                            + DebugRedactor.sanitize(error.getClass().getSimpleName() + " · "
                                    + String.valueOf(error.getMessage())), DANGER);
                    updateVisibleStatus();
                });
            }
        });
    }

    private void setAgentRefreshMessage(String message, int color) {
        agentRefreshMessage = message;
        agentRefreshColor = color;
        if (agentRefreshResult != null) {
            agentRefreshResult.setText(message);
            agentRefreshResult.setTextColor(color);
        }
    }

    private void updatePushStatus(JSONObject result) {
        boolean enabled = result.optBoolean("cloud_enabled", false);
        boolean calls = result.optBoolean("call_push_ready", false);
        boolean messages = result.optBoolean("message_push_ready", false);
        String relay = result.optString("relay_url", "");
        String lastError = result.optString("last_error", "");
        cloudEnabled = enabled;
        cloudRelayConfigured = enabled && result.optBoolean("configured", false) && !relay.isEmpty();
        cloudLastError = DebugRedactor.sanitize(lastError);
        pushConfigured = enabled && calls && messages;
        pushDetail = !enabled ? "云端已关闭" : pushConfigured ? "推送已配置" : "配置不完整";
        pushDiagnostic = "云端开关：" + (enabled ? "开启" : "关闭")
                + "\n来电 Push：" + (calls ? "已配置" : "未就绪")
                + " · 短信 Push：" + (messages ? "已配置" : "未就绪")
                + "\nRelay：" + (relay.isEmpty() ? "未配置" : relay)
                + "\nAPNs 环境：" + result.optString("environment", "未知")
                + " · WAN：" + result.optString("wan_interface", "未检测到")
                + (lastError.isEmpty() ? "" : "\n最近错误：" + DebugRedactor.sanitize(lastError))
                + "\n注意：已配置不等于公网 Relay 已验证可达。";
    }

    private void showFeatureDetails(Feature feature) {
        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(featureTitle(feature))
                .setMessage(featureDetails(feature, ""))
                .setPositiveButton("关闭", null)
                .setNeutralButton("重新检查", (ignored, which) -> showFeatureDetails(feature))
                .create();
        dialog.show();
        if (feature != Feature.AGENT && feature != Feature.PUSH) return;
        Executors.newSingleThreadExecutor().execute(() -> {
            String live;
            try {
                AgentClient client = new AgentClient(this);
                JSONObject result = new JSONObject(feature == Feature.PUSH
                        ? client.pushStatus()
                        : AppConfig.configured(this) ? client.status() : client.health());
                if (feature == Feature.PUSH) {
                    String cloudLogs;
                    try {
                        cloudLogs = cloudAgentLogs(new JSONObject(client.debugSnapshot()));
                    } catch (Exception error) {
                        cloudLogs = "Agent 云端事件读取失败：" + DebugRedactor.sanitize(
                                error.getClass().getSimpleName() + " · " + error.getMessage());
                    }
                    String liveCloudLogs = cloudLogs;
                    runOnUiThread(() -> {
                        updatePushStatus(result);
                        updateVisibleStatus();
                        if (dialog.isShowing()) dialog.setMessage(featureDetails(feature,
                                "实时查询：/api/push/status · HTTP 200\n\nAgent 云端事件（新到旧）\n"
                                        + liveCloudLogs));
                    });
                    return;
                }
                live = "实时查询：" + (AppConfig.configured(this) ? "/api/android/status" : "/api/health")
                        + " · HTTP 200\n返回：ok=" + result.optBoolean("ok", false)
                        + " · runtime_profile=" + result.optString("runtime_profile", "未知")
                        + (AppConfig.configured(this)
                            ? " · pending_commands=" + result.optInt("pending_commands", 0)
                            : " · version=" + result.optString("version", "未知"));
            } catch (Exception error) {
                live = "实时查询失败：" + DebugRedactor.sanitize(
                        error.getClass().getSimpleName() + " · " + error.getMessage());
                BridgeLog.error("feature_diagnostic_failed feature=" + feature, error);
            }
            String outcome = live;
            runOnUiThread(() -> {
                if (dialog.isShowing()) dialog.setMessage(featureDetails(feature, outcome));
            });
        });
    }

    private String cloudAgentLogs(JSONObject snapshot) {
        JSONArray events = snapshot.optJSONArray("events");
        if (events == null) return "Agent 未返回事件列表";
        StringBuilder output = new StringBuilder();
        int count = 0;
        for (int index = events.length() - 1; index >= 0 && count < 10; index--) {
            JSONObject event = events.optJSONObject(index);
            if (event == null) continue;
            String category = event.optString("category", "");
            if (!category.equals("push") && !category.startsWith("cloud")) continue;
            if (output.length() > 0) output.append('\n');
            output.append(DebugRedactor.sanitize(event.optString("timestamp", "")))
                    .append(" · ").append(category)
                    .append(" · ").append(DebugRedactor.sanitize(event.optString("summary", "")));
            String payload = event.optString("payload", "");
            if (!payload.isEmpty()) output.append("\n  ").append(
                    payload.contains("://") ? "[可能包含媒体凭据，链接详情已省略]"
                            : DebugRedactor.sanitize(payload));
            count++;
        }
        return output.length() == 0 ? "暂无 Push / Cloud 事件" : output.toString();
    }

    private String featureTitle(Feature feature) {
        return switch (feature) {
            case VOWLAN -> "VoWLAN 连接详情";
            case AGENT -> RuntimeMode.agentLabel(this) + " 详情";
            case PCM -> "PCM 音频桥详情";
            case PUSH -> "Push / Relay 详情";
            case SHIZUKU -> "Shizuku 详情";
        };
    }

    private String featureDetails(Feature feature, String live) {
        String log = BridgeLog.read();
        String latestVoWLAN = MainScreenPresentation.latestContaining(log, "vowlan_state");
        String currentVoWLAN = VoWLANGatewayService.currentDiagnosticState();
        String details;
        String[] keywords;
        switch (feature) {
            case VOWLAN -> {
                boolean paired = VoWLANPairingStore.configured(this);
                String address = localVoWLANAddress();
                String pcmBackend = RuntimeMode.isStandalone(this) ? "本机 PCM 端口 7580" : "AVF PCM 端口 7580";
                String reason = !paired ? "尚未与 iPhone 配对"
                        : address.isEmpty() ? "没有可用的同网 Wi-Fi 或三星热点地址"
                        : currentVoWLAN.contains("avf=missing") ? "AVF 虚拟网卡未出现"
                        : currentVoWLAN.contains("agent_ready=false") ? "Agent 未通过 VoWLAN 就绪检查"
                        : currentVoWLAN.contains("pcm_ready=false") ? pcmBackend + "未就绪"
                        : !vowlanReady() ? "VoWLAN 服务尚未完成当前检查：" + currentVoWLAN
                        : "当前检查项满足；仍需实际通话验证";
                details = "配对：" + (paired ? "已保存密钥" : "未配对")
                        + "\n本机局域网：" + (address.isEmpty() ? "未发现" : address)
                        + "\n状态原因：" + reason
                        + "\n当前检查：" + currentVoWLAN
                        + "\n最近检查：" + (latestVoWLAN.isEmpty() ? "无" : latestVoWLAN);
                keywords = new String[]{"vowlan", "pairing"};
            }
            case AGENT -> {
                boolean standalone = RuntimeMode.isStandalone(this);
                details = "状态：" + agentDetail
                        + (standalone ? "\n运行位置：本 APK 前台服务"
                                : "\n地址：" + AppConfig.endpoint(this)
                                + "\n控制令牌：" + (AppConfig.configured(this) ? "已配置" : "未配置"))
                        + "\n原因：" + (agentOnline ? "最近一次状态检查通过"
                            : standalone ? "检查前台服务、通知权限与系统省电限制"
                            : "检查 AVF Linux 是否运行、地址是否为 :8575，以及控制令牌是否匹配")
                        + "\n" + agentRefreshMessage;
                keywords = new String[]{"agent", "watchdog", "http_request", "avf"};
            }
            case PCM -> {
                String shizuku = ShizukuBridgeManager.get(this).status();
                String pcmBackend = RuntimeMode.isStandalone(this) ? "本机 PCM 端口 7580" : "AVF PCM 端口 7580";
                String reason = !shizukuReady() ? "Shizuku 未连接或未授权，PCM 用户服务不可用"
                        : currentVoWLAN.contains("pcm_ready=false") ? pcmBackend + "未响应"
                        : !pcmBridgeRunning() ? "PCM 音频桥进程尚未运行"
                        : "当前检查项满足；仍需实际通话验证双向音频";
                details = "Shizuku：" + shizuku + "\n桥状态：" + (pcmBridgeRunning() ? "运行中" : "待启动")
                        + "\n状态原因：" + reason
                        + "\n当前 VoWLAN 检查：" + currentVoWLAN
                        + "\n最近 VoWLAN 检查：" + (latestVoWLAN.isEmpty() ? "无" : latestVoWLAN);
                keywords = new String[]{"pcm", "shizuku", "vowlan_state"};
            }
            case PUSH -> {
                details = "状态：" + pushDetail + "\n" + pushDiagnostic
                        + "\n原因：" + (agentOnline ? "请核对开关、Relay 地址、APNs token 与最近错误"
                            : "Agent 不可达时无法确认云端注册或心跳");
                keywords = new String[]{"push", "relay", "pairing"};
            }
            case SHIZUKU -> {
                String shizuku = ShizukuBridgeManager.get(this).status();
                details = "状态：" + shizuku + "\n原因：" + (shizukuReady()
                        ? "Binder 已连接；是否有声音仍需检查 PCM 路由"
                        : "检查 Shizuku 是否运行、AirSIM 授权及 PCM 用户服务是否成功绑定");
                keywords = new String[]{"shizuku", "local_output"};
            }
            default -> throw new IllegalStateException("未知功能");
        }
        String recent = MainScreenPresentation.recentMatchingLogLines(log, 12, keywords);
        return details + (live.isEmpty() ? "" : "\n\n" + live)
                + "\n\n相关日志（新到旧）\n" + recent;
    }

	private void checkAVFEnvironmentAtStartup() {
		if (RuntimeMode.isStandalone(this)) {
			StandaloneAgentService.start(this);
			completeStartupSetup();
			return;
		}
		if (avfStartupPromptShown) { completeStartupSetup(); return; }
		AVFEnvironmentDetector.Snapshot snapshot = AVFEnvironmentDetector.inspect(this);
		boolean agentConfigured = AppConfig.configured(this);
		if (!AVFStartupPolicy.shouldPrompt(snapshot.state(), agentConfigured)) {
            completeStartupSetup();
            return;
        }
		avfStartupPromptShown = true;
		boolean needsInstall = snapshot.state() == AVFStartupPolicy.State.RUNNING && !agentConfigured;
		boolean canLaunch = snapshot.state() == AVFStartupPolicy.State.READY_TO_START;
		AlertDialog dialog = new AlertDialog.Builder(this)
				.setTitle(needsInstall ? "配置 AirSIM AVF Agent" : "需要启动 AVF Linux 环境")
				.setMessage(avfEnvironmentSummary(snapshot)
						+ (needsInstall
						? "\n\n若尚未安装，复制首次安装命令到 Linux Terminal；" +
								"若 Agent 已运行，先执行 sudo airsim-avf-pair 配对并检查 installerd。"
						: "\n\n启动 Linux 后，在 Terminal 中粘贴 AirSIM 一键安装命令。"))
				.setPositiveButton(needsInstall ? "复制首次安装命令"
						: canLaunch ? "启动 Linux Terminal" : "打开开发者选项",
						(ignored, which) -> {
							if (needsInstall) copyAVFInstallCommand();
							else if (canLaunch) openAVFTerminalOrSettings();
							else AVFEnvironmentActions.openDeveloperOptions(this);
						})
				.setNeutralButton(needsInstall ? "打开 Linux Terminal" : "复制安装命令",
						(ignored, which) -> {
							if (needsInstall) openAVFTerminalOrSettings();
							else copyAVFInstallCommand();
						})
				.setNegativeButton("稍后", null)
				.create();
		dialog.setOnDismissListener(ignored -> completeStartupSetup());
		dialog.show();
	}

	private String avfEnvironmentSummary(AVFEnvironmentDetector.Snapshot snapshot) {
		return switch (snapshot.state()) {
			case RUNNING -> "AVF Linux 已启动，可连接 Agent。";
			case READY_TO_START -> "系统已提供 AVF 和 Linux Terminal，但虚拟 Linux 尚未启动。";
			case TERMINAL_DISABLED -> "系统包含 Linux Terminal，但当前被开发者选项停用。";
			case TERMINAL_MISSING -> snapshot.restrictedChinaOEM()
					? "当前国产 ROM 未提供 AOSP Linux Terminal 组件；AirSIM 无法用普通应用权限强制补装或开启。"
					: "系统声明支持 AVF，但未安装 AOSP Linux Terminal 组件。";
			case AVF_UNSUPPORTED -> snapshot.restrictedChinaOEM()
					? "当前国产 ROM 没有向第三方应用公开 AVF Linux 能力，无法由 AirSIM 强制开启。"
					: "当前系统没有公开 AVF 能力，请检查系统版本和厂商支持。";
		};
	}

	private void openAVFTerminalOrSettings() {
		if (!AVFEnvironmentActions.openTerminal(this)) {
			AVFEnvironmentActions.openDeveloperOptions(this);
			toast("未找到可启动的 Linux Terminal，请在开发者选项中启用");
		}
	}

	private void copyAVFInstallCommand() {
		getSystemService(ClipboardManager.class).setPrimaryClip(
				ClipData.newPlainText("AirSIM AVF 一键安装", AVFStartupPolicy.installCommand()));
		toast("AVF 一键安装命令已复制");
	}

	private void refreshInstallerStatus() {
		if (installerStatus == null) return;
		if (!AppConfig.configured(this)) {
			installerStatus.setText("尚未配对控制令牌。先在 AVF Linux Terminal 完成首次签名安装，" +
					"再运行 sudo airsim-avf-pair，将令牌保存到上方配置。" +
					"已有 Agent 但安装服务不可用时，先在 Terminal 检查 airsim-installerd 服务，不要清除 Linux 数据。");
			return;
		}
		Executors.newSingleThreadExecutor().execute(() -> {
			try {
				String value = new AgentReleaseManager(this).status();
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("installerd 在线\n" + value);
				});
			} catch (Exception error) {
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("installerd 不可用 · " +
							error.getClass().getSimpleName() +
							"。请在 Linux Terminal 检查 sudo systemctl status airsim-installerd；" +
							"不要清除 Linux 数据。");
				});
			}
		});
	}

	private void runAgentMaintenance(String action) {
		if (!AppConfig.configured(this)) {
			if (installerStatus != null) installerStatus.setText(
					"尚未配对。先完成 AVF Linux 首次安装并运行 sudo airsim-avf-pair，" +
					"保存控制令牌后再更新、修复或回滚。");
			return;
		}
		if (installerStatus != null) installerStatus.setText("Agent 操作进行中 · " + action);
		Executors.newSingleThreadExecutor().execute(() -> {
			try {
				AgentReleaseManager manager = new AgentReleaseManager(this);
				String result = switch (action) {
					case "repair" -> manager.repairLatest();
					case "rollback" -> manager.rollback();
					default -> manager.installLatest();
				};
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("Agent 操作完成\n" + result);
					toast("AVF Agent 操作完成");
					refreshAgent();
				});
			} catch (Exception error) {
				BridgeLog.error("avf_agent_maintenance_failed action=" + action, error);
				runOnUiThread(() -> {
					if (installerStatus != null) installerStatus.setText("Agent 操作失败 · " + error.getMessage());
					toast("AVF Agent 操作失败");
				});
			}
		});
	}

    private void updateVisibleStatus() {
        if (status != null) status.setText(roleText() + "\nAgent：" + agentDetail);
        if (currentPage == Page.STATUS && contentHost != null
                && bottomBar.getVisibility() == View.VISIBLE) showPage(Page.STATUS);
    }

    private void startPairing() {
        stopPairingServer();
        if (pairingStatus != null) pairingStatus.setText("正在检查局域网并生成临时密钥…");
        pairingServer = new PairingServer(this, new PairingServer.Listener() {
            @Override public void onStarted(String code, String address, long expiresAtMillis) {
                BridgeLog.info("pairing_started address=" + address + " expires_at=" + expiresAtMillis);
                pairingCode = code;
                pairingExpiresAt = expiresAtMillis;
                runOnUiThread(() -> {
                    if (pairingCodeView != null) pairingCodeView.setText(
                            MainScreenPresentation.formatPairingCode(code));
                    if (pairingStatus != null) {
                        pairingStatus.setText("等待 iPhone 自动发现或手动地址配对…\n" + address);
                        pairingStatus.setTextIsSelectable(true);
                    }
                    startPairingCountdown();
                });
            }

            @Override public void onSucceeded(String agentResponse) {
                BridgeLog.info("pairing_completed");
                boolean localMode = false;
                try {
                    localMode = new JSONObject(agentResponse).optBoolean("local_mode", false);
                } catch (Exception ignored) {
                    // Older Agent responses do not carry a mode marker.
                }
                boolean pairedLocally = localMode;
                runOnUiThread(() -> {
                    cancelPairingCountdown();
                    if (pairingCodeView != null) {
                        pairingCodeView.setText("配对成功");
                        pairingCodeView.setTextSize(28);
                    }
                    if (pairingCountdownView != null) pairingCountdownView.setText("VoWLAN 密钥已安全保存");
                    if (pairingStatus != null) pairingStatus.setText(pairedLocally
                            ? "本地模式已启用，不使用 Relay 或 Push"
                            : "iOS Push 身份已写入 Android Agent");
                    refreshAgent();
                });
            }

            @Override public void onFailed(String message) {
                BridgeLog.error("pairing_failed", new IllegalStateException(message));
                runOnUiThread(() -> {
                    cancelPairingCountdown();
                    if (pairingCountdownView != null) pairingCountdownView.setText("配对窗口已关闭");
                    if (pairingStatus != null) pairingStatus.setText("配对失败：" + message);
                });
            }
        });
        pairingServer.start();
    }

    private void startPairingCountdown() {
        cancelPairingCountdown();
        long remaining = Math.max(0, pairingExpiresAt - System.currentTimeMillis());
        pairingCountdown = new CountDownTimer(remaining, 1_000) {
            @Override public void onTick(long millisUntilFinished) {
                long seconds = millisUntilFinished / 1_000;
                if (pairingCountdownView != null) pairingCountdownView.setText(
                        String.format(java.util.Locale.CHINA, "%02d:%02d 后失效", seconds / 60, seconds % 60));
            }

            @Override public void onFinish() {
                if (pairingCountdownView != null) pairingCountdownView.setText("配对窗口已失效");
            }
        }.start();
    }

    private void cancelPairingCountdown() {
        if (pairingCountdown != null) pairingCountdown.cancel();
        pairingCountdown = null;
    }

    private void stopPairingServer() {
        cancelPairingCountdown();
        PairingServer active = pairingServer;
        pairingServer = null;
        if (active != null) {
            try { active.close(); }
            catch (Exception error) { BridgeLog.error("pairing_close", error); }
        }
    }

    private void refreshStatus() {
        refreshShizukuStatus();
    }

    private EditText portField(String hint, int value) {
        EditText input = new EditText(this);
        input.setText(value <= 0 && hint.contains("0 = 自动") ? "0" : Integer.toString(value));
        input.setHint(hint);
        input.setTextColor(TEXT);
        input.setHintTextColor(MUTED);
        input.setInputType(InputType.TYPE_CLASS_NUMBER);
        return input;
    }

    /** Returns the port, or -1 when the text is not a usable port. */
    private static int parsePort(EditText input, int fallback) {
        String text = input.getText().toString().trim();
        if (text.isEmpty()) return fallback;
        if (text.length() > 5 || !text.chars().allMatch(Character::isDigit)) return -1;
        int value = Integer.parseInt(text);
        return NetworkSettings.isUsablePort(value) ? value : -1;
    }

    private void refreshShizukuStatus() {
        if (shizukuStatus != null) shizukuStatus.setText(ShizukuBridgeManager.get(this).status());
        if (privilegeChannelGroup == null) return;
        PrivilegeChannelPreference.Channel selected = PrivilegeChannelPreference.get(this);
        for (java.util.Map.Entry<Integer, PrivilegeChannelPreference.Channel> entry
                : privilegeChannelIDs.entrySet()) {
            if (entry.getValue() != selected) continue;
            int id = entry.getKey();
            if (privilegeChannelGroup.getCheckedRadioButtonId() != id) {
                updatingPrivilegeChannel = true;
                privilegeChannelGroup.check(id);
                updatingPrivilegeChannel = false;
            }
            return;
        }
    }

    private void refreshDebugLog() {
        if (debugRows == null) return;
        String log = BridgeLog.read();
        if (log.equals(lastRenderedDebugLog) && activeDebugFilter.equals(lastRenderedDebugFilter)) return;
        lastRenderedDebugLog = log;
        lastRenderedDebugFilter = activeDebugFilter;
        debugRows.removeAllViews();
        String visible = MainScreenPresentation.recentLogLines(
                log, activeDebugFilter, 60);
        if (visible.startsWith("暂无") || visible.startsWith("此分类")) {
            TextView empty = description(visible);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(dp(8), dp(28), dp(8), dp(28));
            debugRows.addView(empty);
            return;
        }
        String[] lines = visible.split("\\R");
        for (int index = 0; index < lines.length; index++) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.TOP);
            row.setPadding(dp(2), dp(6), dp(2), dp(6));

            View dot = new View(this);
            dot.setBackground(rounded(MainScreenPresentation.isErrorLog(lines[index]) ? DANGER : PRIMARY,
                    4, Color.TRANSPARENT, 0));
            LinearLayout.LayoutParams dotParams = new LinearLayout.LayoutParams(dp(7), dp(7));
            dotParams.topMargin = dp(5);
            row.addView(dot, dotParams);

            LinearLayout copy = column(dp(9));
            TextView metadata = label(MainScreenPresentation.logMetadata(lines[index]),
                    10, MUTED, Gravity.START);
            copy.addView(metadata);
            TextView title = label(MainScreenPresentation.activitySummary(lines[index]),
                    13, TEXT, Gravity.START);
            title.setTypeface(Typeface.DEFAULT_BOLD);
            copy.addView(title, matchWithTop(1));
            TextView detail = label(MainScreenPresentation.eventBody(lines[index]),
                    11, MUTED, Gravity.START);
            detail.setTypeface(Typeface.MONOSPACE);
            copy.addView(detail, matchWithTop(1));
            row.addView(copy, weighted());
            debugRows.addView(row);

            if (index < lines.length - 1) {
                View divider = new View(this);
                divider.setBackgroundColor(BORDER);
                LinearLayout.LayoutParams dividerParams = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(1));
                dividerParams.leftMargin = dp(18);
                debugRows.addView(divider, dividerParams);
            }
        }
    }

    private void copyDebugLog() {
        String value = BridgeLog.read();
        getSystemService(ClipboardManager.class).setPrimaryClip(
                ClipData.newPlainText("AirSIM Debug Log", value));
        toast("日志已复制");
    }

    private void exportDebugLog() {
        Intent share = new Intent(Intent.ACTION_SEND);
        share.setType("text/plain");
        share.putExtra(Intent.EXTRA_SUBJECT, "AirSIM Android 诊断");
        share.putExtra(Intent.EXTRA_TEXT, BridgeLog.read());
        startActivity(Intent.createChooser(share, "导出诊断"));
    }

	private void shareCrashReport() {
		String payload = CrashReportSharePayload.compose(
				CrashReportStore.read(getFilesDir()), BridgeLog.read());
		if (payload.isBlank()) {
			toast("暂无闪退报告");
			return;
		}
		Intent share = new Intent(Intent.ACTION_SEND);
		share.setType("text/plain");
		share.putExtra(Intent.EXTRA_SUBJECT, "AirSIM Android 闪退报告");
		share.putExtra(Intent.EXTRA_TEXT, payload);
		startActivity(Intent.createChooser(share, "发送闪退报告"));
	}

	private void maybeShowCrashReportPrompt() {
		if (!resumed || startupSetupInFlight || isFinishing() || isDestroyed()) return;
        if (crashPromptShown || !CrashReportStore.hasReport(getFilesDir())) {
            appUpdates.foreground();
            return;
        }
		crashPromptShown = true;
		new AlertDialog.Builder(this)
				.setTitle("检测到上次闪退")
				.setMessage("AirSIM 已在本机保存脱敏报告。不会自动上传，是否现在发送给开发者？")
				.setPositiveButton("发送", (ignored, which) -> shareCrashReport())
				.setNeutralButton("查看", (ignored, which) -> showPage(Page.DEBUG))
				.setNegativeButton("稍后", null)
				.setOnDismissListener(ignored -> appUpdates.foreground())
				.show();
	}

    private void saveConfiguration() {
        try {
            if (RuntimeMode.isStandalone(this)) {
                AppConfig.save(this, "", "", selectedMode);
            } else {
                AppConfig.save(this, endpoint.getText().toString(), token.getText().toString(), selectedMode);
            }
            AgentWatchdogService.start(this);
            toast(RuntimeMode.isStandalone(this)
                    ? "模式已保存，内置 Agent 正在启动" : "配置已保存，守护服务正在启动");
            refreshAgent();
        } catch (IllegalArgumentException error) {
            toast(error.getMessage());
        }
    }

    private String roleText() {
        return "默认电话角色：" + (dialerRoleHeld() ? "已启用" : "未启用");
    }

    private boolean dialerRoleHeld() {
        RoleManager manager = getSystemService(RoleManager.class);
        return manager != null && manager.isRoleAvailable(RoleManager.ROLE_DIALER)
                && manager.isRoleHeld(RoleManager.ROLE_DIALER);
    }

    private String vowlanNetworkLine() {
        String host = localVoWLANAddress();
        return host.isEmpty() ? "同一 Wi‑Fi / 三星热点" : "同一 Wi‑Fi · " + host;
    }

    private boolean vowlanReady() {
        String state = VoWLANGatewayService.currentDiagnosticState();
        return dialerRoleHeld() && VoWLANPairingStore.configured(this) && !localVoWLANAddress().isEmpty()
                && state.contains("paired=true") && state.contains("agent_ready=true")
                && state.contains("pcm_ready=true") && state.contains("dialer_role=true")
                && !state.contains("avf=missing");
    }

    private String localVoWLANAddress() {
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            while (interfaces.hasMoreElements()) {
                NetworkInterface item = interfaces.nextElement();
                if (!item.isUp() || item.isLoopback()) continue;
                Enumeration<InetAddress> addresses = item.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    InetAddress address = addresses.nextElement();
                    if (address instanceof Inet4Address
                            && VoWLANNetworkPolicy.isVoWLANInterface(item.getName(), address.getHostAddress())) {
                        return address.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {}
        return "";
    }

    private boolean shizukuReady() {
        String value = ShizukuBridgeManager.get(this).status();
        return value.contains("Shizuku 已连接");
    }

    private boolean pcmBridgeRunning() {
        return ShizukuBridgeManager.get(this).bridgeRunning();
    }

    private String latestActivity() {
        String line = MainScreenPresentation.recentLogLines(BridgeLog.read(), "", 1);
        return "暂无 Debug 日志".equals(line)
                ? "等待连接活动"
                : "刚刚 · " + MainScreenPresentation.activitySummary(line);
    }

    private LinearLayout pageRoot() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(18), dp(20), dp(18), dp(30));
        root.setBackgroundColor(BG);
        return root;
    }

    private ScrollView scroll(View content) {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(false);
        scroll.setOverScrollMode(View.OVER_SCROLL_NEVER);
        scroll.addView(content, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return scroll;
    }

    private LinearLayout card(int color, int radius) {
        LinearLayout card = new LinearLayout(this);
        card.setBackground(rounded(color, radius, BORDER, 1));
        return card;
    }

    private LinearLayout row() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        return row;
    }

    private LinearLayout column(int startPadding) {
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        if (startPadding > 0) column.setPadding(startPadding, 0, 0, 0);
        return column;
    }

    private TextView sectionTitle(String value) {
        TextView title = label(value, 18, TEXT, Gravity.START);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        return title;
    }

    private TextView overline(String value) {
        TextView text = label(value, 12, MUTED, Gravity.START);
        text.setLetterSpacing(0.04f);
        return text;
    }

    private TextView description(String value) {
        TextView text = label(value, 13, MUTED, Gravity.START);
        text.setLineSpacing(dp(2), 1f);
        return text;
    }

    private TextView label(String value, int sp, int color, int gravity) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setGravity(gravity);
        view.setFontFeatureSettings("kern");
        return view;
    }

    private EditText input(String hint, int type) {
        EditText view = new EditText(this);
        view.setHint(hint);
        view.setHintTextColor(MUTED);
        view.setTextColor(TEXT);
        view.setTextSize(15);
        view.setInputType(type);
        view.setSingleLine(true);
        view.setPadding(dp(14), dp(11), dp(14), dp(11));
        view.setBackground(rounded(SURFACE_HIGH, 15, BORDER, 1));
        return view;
    }

    private TextView primaryButton(String title, int color) {
        TextView button = label(title, 16, Color.WHITE, Gravity.CENTER);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setMinHeight(dp(54));
        button.setPadding(dp(16), dp(13), dp(16), dp(13));
        button.setBackground(rounded(color, 20, color, 1));
        button.setClickable(true);
        button.setFocusable(true);
        return button;
    }

    private TextView secondaryButton(String title) {
        TextView button = label(title, 14, TEXT, Gravity.CENTER);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setMinHeight(dp(50));
        button.setPadding(dp(12), dp(12), dp(12), dp(12));
        button.setBackground(rounded(SURFACE_HIGH, 18, BORDER, 1));
        button.setClickable(true);
        button.setFocusable(true);
        return button;
    }

    private ImageView icon(int resource, int tint, int contentSize) {
        ImageView view = new ImageView(this);
        view.setImageResource(resource);
        view.setImageTintList(ColorStateList.valueOf(tint));
        view.setScaleType(ImageView.ScaleType.CENTER_INSIDE);
        view.setMinimumWidth(dp(contentSize));
        view.setMinimumHeight(dp(contentSize));
        return view;
    }

    private GradientDrawable rounded(int color, int radius, int strokeColor, int strokeWidth) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(dp(radius));
        if (strokeWidth > 0 && strokeColor != Color.TRANSPARENT) {
            drawable.setStroke(dp(strokeWidth), strokeColor);
        }
        return drawable;
    }

    private LinearLayout.LayoutParams weighted() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
    }

    private LinearLayout.LayoutParams weightedWithStart(int start) {
        LinearLayout.LayoutParams params = weighted();
        params.leftMargin = dp(start);
        return params;
    }

    private LinearLayout.LayoutParams weightedWithEnd(int end) {
        LinearLayout.LayoutParams params = weighted();
        params.rightMargin = dp(end);
        return params;
    }

    private LinearLayout.LayoutParams matchWithTop(int top) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(top);
        return params;
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == DIAGNOSTIC_TXT_REQUEST) {
            if (result == RESULT_OK && data != null && data.getData() != null) {
                Uri destination = data.getData();
                DIAGNOSTIC_WORKER.execute(() -> {
                    try (java.io.OutputStream output = getContentResolver().openOutputStream(destination, "wt")) {
                        if (output == null) throw new java.io.IOException("document unavailable");
                        String report = AudioWatchdogReport.compose(AppInformation.version(this), Build.VERSION.SDK_INT,
                                Build.MANUFACTURER, Build.MODEL, BridgeLog.read());
                        output.write(report.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                        runOnUiThread(() -> toast("Watchdog TXT 已保存"));
                    } catch (Exception error) {
                        runOnUiThread(() -> toast("保存 TXT 失败，请重试或使用复制日志"));
                    }
                });
            }
            return;
        }
        refreshStatus();
        if (request == ROLE_REQUEST) {
            continueAfterSystemRoleRequest();
        } else if (request == DEFAULT_APPS_REQUEST) {
            if (dialerRoleHeld()) checkAVFEnvironmentAtStartup();
            else {
                toast("AirSIM 仍未获得默认电话角色");
                completeStartupSetup();
            }
        } else if (request == SHIZUKU_SETUP_REQUEST) {
            startupSetupInFlight = false;
            startupSetupPending = true;
            scheduleStartupSetup();
        }
    }

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        if (hasVoBLEPermissions()) {
            com.airsim.phonecontrol.voble.VoBLEGatewayService.start(this);
        }
        if (startupSetupPending) scheduleStartupSetup();
        if (currentPage == Page.SETTINGS && !voBLEAuthenticationVisible) showPage(Page.SETTINGS);
        if (currentPage == Page.STATUS && pcmStatusPoller != null) pcmStatusPoller.start();
        if (voBLEAuthenticationVisible) handler.post(voBLEAuthenticationRefresh);
        refreshShizukuStatus();
		startSMSInboxBaselineIfAuthorized();
        if (startupSetupCompleted && !startupSetupPending && !startupSetupInFlight) {
            handler.post(this::maybeShowCrashReportPrompt);
        }
    }

    @Override protected void onPause() {
        resumed = false;
        if (appUpdates != null) appUpdates.pause();
        if (pcmStatusPoller != null) pcmStatusPoller.stop();
        handler.removeCallbacks(voBLEAuthenticationRefresh);
        super.onPause();
    }

    @Override public void onBackPressed() {
        if (bottomBar != null && bottomBar.getVisibility() == View.GONE) {
            stopPairingServer();
            showPage(Page.STATUS);
            return;
        }
        if (currentPage != Page.STATUS) {
            showPage(Page.STATUS);
            return;
        }
        super.onBackPressed();
    }

    @Override protected void onDestroy() {
        if (appUpdates != null) appUpdates.destroy();
        handler.removeCallbacks(startupSetup);
        if (shizukuStartupDialog != null) {
            shizukuStartupDialog.setOnDismissListener(null);
            shizukuStartupDialog.dismiss();
        }
        if (pcmStatusPoller != null) pcmStatusPoller.stop();
        handler.removeCallbacks(debugRefresh);
        handler.removeCallbacks(voBLEAuthenticationRefresh);
        stopPairingServer();
        super.onDestroy();
    }

    @Override protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean(SHIZUKU_STARTUP_CHECKED, shizukuStartupPolicy.checked());
        super.onSaveInstanceState(outState);
    }
}
