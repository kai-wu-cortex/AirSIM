package com.airsim.phonecontrol;

import android.Manifest;
import android.app.Activity;
import android.app.role.RoleManager;
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
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

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

    private FrameLayout contentHost;
    private LinearLayout bottomBar;
    private final List<TextView> navigationItems = new ArrayList<>();
    private Page currentPage = Page.STATUS;

    private EditText endpoint;
    private EditText token;
    private EditText number;
    private String selectedMode;
    private TextView status;
    private TextView shizukuStatus;
    private TextView pairingStatus;
    private TextView pairingCodeView;
    private TextView pairingCountdownView;
    private LinearLayout debugRows;
    private String activeDebugFilter = "全部";
    private boolean realtimeLogging = true;
    private boolean agentOnline;
    private String agentDetail = "待检测";

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

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
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
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 101);
        }
    }

    private void configureWindow() {
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
                view.setPadding(0, bars.top, 0, bars.bottom);
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
                paired ? (agentOnline ? "VoWLAN 已就绪" : "VoWLAN 准备中") : "VoWLAN 尚未配对",
                25, paired ? CYAN : WARNING, Gravity.START);
        heroTitle.setTypeface(Typeface.DEFAULT_BOLD);
        heroCopy.addView(heroTitle);
        heroCopy.addView(label(vowlanNetworkLine(), 14, MUTED, Gravity.START));
        hero.addView(heroCopy, weighted());
        root.addView(hero, matchWithTop(16));

        LinearLayout firstHealthRow = row();
        firstHealthRow.addView(healthTile(
                "Linux Agent", agentOnline ? "在线" : agentDetail,
                android.R.drawable.ic_menu_manage, agentOnline), weightedWithEnd(5));
        firstHealthRow.addView(healthTile(
                "PCM 音频桥", pcmReady() ? "就绪" : "待启动",
                android.R.drawable.ic_media_play, pcmReady()), weightedWithStart(5));
        root.addView(firstHealthRow, matchWithTop(12));

        LinearLayout secondHealthRow = row();
        secondHealthRow.addView(healthTile(
                "Push / Relay", agentOnline ? "在线" : "检查中",
                android.R.drawable.stat_notify_sync, agentOnline), weightedWithEnd(5));
        secondHealthRow.addView(healthTile(
                "Shizuku", shizukuReady() ? "已授权" : "待授权",
                android.R.drawable.ic_lock_idle_lock, shizukuReady()), weightedWithStart(5));
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
        root.addView(debugFilters(), matchWithTop(14));

        LinearLayout logCard = card(SURFACE, 22);
        logCard.setOrientation(LinearLayout.VERTICAL);
        logCard.setPadding(dp(14), dp(8), dp(14), dp(8));
        debugRows = column(0);
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

        root.addView(sectionTitle("Linux Agent"), matchWithTop(18));
        LinearLayout agentCard = card(SURFACE, 22);
        agentCard.setOrientation(LinearLayout.VERTICAL);
        agentCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        endpoint = input("Agent 地址", InputType.TYPE_CLASS_TEXT);
        endpoint.setText(AppConfig.endpoint(this));
        agentCard.addView(endpoint);
        token = input("控制令牌", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        token.setText(AppConfig.token(this));
        agentCard.addView(token, matchWithTop(10));
        selectedMode = AppConfig.mode(this);
        agentCard.addView(modeSelector(), matchWithTop(12));
        TextView save = primaryButton("保存配置并启动守护", BLUE);
        save.setOnClickListener(ignored -> saveConfiguration());
        agentCard.addView(save, matchWithTop(12));
        root.addView(agentCard, matchWithTop(10));

        root.addView(sectionTitle("Shizuku 权限与 PCM 桥"), matchWithTop(22));
        LinearLayout shizukuCard = card(SURFACE, 22);
        shizukuCard.setOrientation(LinearLayout.VERTICAL);
        shizukuCard.setPadding(dp(16), dp(16), dp(16), dp(16));
        shizukuStatus = label("", 14, TEXT, Gravity.START);
        shizukuCard.addView(shizukuStatus);
        shizukuCard.addView(description("首次通过无线调试启动并授权；之后 AirSIM 会自动恢复 PCM 桥。"), matchWithTop(6));
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
        root.addView(shizukuCard, matchWithTop(10));

        root.addView(sectionTitle("电话角色与诊断"), matchWithTop(22));
        TextView dialer = secondaryButton("设为默认电话应用");
        dialer.setOnClickListener(ignored -> requestDialerRole());
        root.addView(dialer, matchWithTop(10));
        TextView agent = secondaryButton("刷新 Agent 状态");
        agent.setOnClickListener(ignored -> refreshAgent());
        root.addView(agent, matchWithTop(10));

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
        refreshShizukuStatus();
        return scroll(root);
    }

    private void openPairingPage() {
        handler.removeCallbacks(debugRefresh);
        bottomBar.setVisibility(View.GONE);
        contentHost.removeAllViews();
        contentHost.addView(pairingPage(), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        startPairing();
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

    private LinearLayout debugFilters() {
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        LinearLayout filterRow = row();
        String[] filters = {"全部", "Agent", "VoWLAN", "PCM", "Telecom"};
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
            if (currentPage == Page.STATUS || currentPage == Page.SETTINGS) showPage(currentPage);
        });
        return item;
    }

    private LinearLayout healthTile(String title, String value, int iconResource, boolean healthy) {
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
        return tile;
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
        getSystemService(TelecomManager.class).placeCall(Uri.parse("tel:" + value), null);
    }

    private void requestDialerRole() {
        RoleManager manager = getSystemService(RoleManager.class);
        if (!manager.isRoleAvailable(RoleManager.ROLE_DIALER)) {
            toast("设备不支持默认拨号器角色");
            return;
        }
        startActivityForResult(manager.createRequestRoleIntent(RoleManager.ROLE_DIALER), ROLE_REQUEST);
    }

    private void localCall(String action) {
        String callId = CallRepository.firstId();
        if (callId.isEmpty()) { toast("当前没有可控制的通话"); return; }
        Executors.newSingleThreadExecutor().execute(() -> {
            CallRepository.ActionResult result = CallRepository.execute(
                    new AgentCommand(UUID.randomUUID().toString(), action, callId, ""),
                    getSystemService(TelecomManager.class));
            runOnUiThread(() -> toast(result.success ? "Telecom 已确认" : result.error));
        });
    }

    private void refreshAgent() {
        agentDetail = "检测中";
        updateVisibleStatus();
        Executors.newSingleThreadExecutor().execute(() -> {
            try {
                new AgentClient(this).status();
                runOnUiThread(() -> {
                    agentOnline = true;
                    agentDetail = "在线";
                    updateVisibleStatus();
                });
            } catch (Exception error) {
                runOnUiThread(() -> {
                    agentOnline = false;
                    agentDetail = "离线 · " + error.getClass().getSimpleName();
                    updateVisibleStatus();
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
                    if (pairingStatus != null) pairingStatus.setText("等待 iPhone 连接…\n" + address);
                    startPairingCountdown();
                });
            }

            @Override public void onSucceeded(String agentResponse) {
                BridgeLog.info("pairing_completed");
                runOnUiThread(() -> {
                    cancelPairingCountdown();
                    if (pairingCodeView != null) {
                        pairingCodeView.setText("配对成功");
                        pairingCodeView.setTextSize(28);
                    }
                    if (pairingCountdownView != null) pairingCountdownView.setText("VoWLAN 密钥已安全保存");
                    if (pairingStatus != null) pairingStatus.setText("iOS Push 身份已写入 Linux Agent");
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

    private void refreshShizukuStatus() {
        if (shizukuStatus != null) shizukuStatus.setText(ShizukuBridgeManager.get(this).status());
    }

    private void refreshDebugLog() {
        if (debugRows == null) return;
        debugRows.removeAllViews();
        String visible = MainScreenPresentation.recentLogLines(
                BridgeLog.read(), activeDebugFilter, 8);
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
            row.setPadding(dp(4), dp(12), dp(4), dp(12));

            View dot = new View(this);
            dot.setBackground(rounded(PRIMARY, 5, Color.TRANSPARENT, 0));
            LinearLayout.LayoutParams dotParams = new LinearLayout.LayoutParams(dp(9), dp(9));
            dotParams.topMargin = dp(5);
            row.addView(dot, dotParams);

            LinearLayout copy = column(dp(12));
            TextView title = label(MainScreenPresentation.activitySummary(lines[index]),
                    14, TEXT, Gravity.START);
            title.setTypeface(Typeface.DEFAULT_BOLD);
            copy.addView(title);
            TextView detail = label("刚刚 · 已写入本机诊断日志", 12, MUTED, Gravity.START);
            copy.addView(detail, matchWithTop(3));
            row.addView(copy, weighted());
            debugRows.addView(row);

            if (index < lines.length - 1) {
                View divider = new View(this);
                divider.setBackgroundColor(BORDER);
                LinearLayout.LayoutParams dividerParams = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(1));
                dividerParams.leftMargin = dp(25);
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

    private void saveConfiguration() {
        try {
            AppConfig.save(this, endpoint.getText().toString(), token.getText().toString(), selectedMode);
            AgentWatchdogService.start(this);
            toast("配置已保存，守护服务正在启动");
            refreshAgent();
        } catch (IllegalArgumentException error) {
            toast(error.getMessage());
        }
    }

    private String roleText() {
        RoleManager manager = getSystemService(RoleManager.class);
        return "默认电话角色：" + (manager.isRoleHeld(RoleManager.ROLE_DIALER) ? "已启用" : "未启用");
    }

    private String vowlanNetworkLine() {
        String host = localVoWLANAddress();
        return host.isEmpty() ? "同一 Wi‑Fi / 三星热点" : "同一 Wi‑Fi · " + host;
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
        return value.contains("已连接") || value.contains("在线 · UID");
    }

    private boolean pcmReady() {
        String value = ShizukuBridgeManager.get(this).status();
        return value.contains("bridge_running") || value.contains("已连接");
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
        refreshStatus();
    }

    @Override protected void onResume() {
        super.onResume();
        refreshShizukuStatus();
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
        handler.removeCallbacks(debugRefresh);
        stopPairingServer();
        super.onDestroy();
    }
}
