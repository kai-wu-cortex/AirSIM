package com.airsim.phonecontrol;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.telecom.Call;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Minimal call surface that can appear above the keyguard without exposing SMS or settings. */
public final class CallScreenActivity extends Activity {
    static final String EXTRA_CALL_ID = "com.airsim.phonecontrol.SCREEN_CALL_ID";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            updateCall();
            if (!isFinishing()) handler.postDelayed(this, 500);
        }
    };
    private String callId = "";
    private TextView title;
    private TextView detail;
    private Button answer;
    private Button reject;
    private Button end;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setShowWhenLocked(true);
        setTurnScreenOn(BridgeNotification.wakesForCalls(this, AppConfig.mode(this)));
        callId = getIntent().getStringExtra(EXTRA_CALL_ID);
        if (callId == null || callId.isEmpty()) { finish(); return; }

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(dp(28), dp(48), dp(28), dp(48));
        root.setBackgroundColor(Color.rgb(5, 17, 38));

        title = new TextView(this);
        title.setTextColor(Color.WHITE);
        title.setTextSize(30);
        title.setGravity(Gravity.CENTER);
        root.addView(title, new LinearLayout.LayoutParams(-1, -2));

        detail = new TextView(this);
        detail.setTextColor(Color.rgb(170, 190, 215));
        detail.setTextSize(16);
        detail.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams detailLayout = new LinearLayout.LayoutParams(-1, -2);
        detailLayout.topMargin = dp(16);
        root.addView(detail, detailLayout);

        answer = button("接听", Color.rgb(38, 202, 93), "answer");
        reject = button("拒接", Color.rgb(225, 63, 66), "reject");
        end = button("挂断", Color.rgb(225, 63, 66), "end");
        root.addView(answer, buttonLayout());
        root.addView(reject, buttonLayout());
        root.addView(end, buttonLayout());
        setContentView(root);
        updateCall();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        callId = intent.getStringExtra(EXTRA_CALL_ID);
        updateCall();
    }

    @Override protected void onResume() {
        super.onResume();
        handler.removeCallbacks(refresh);
        handler.post(refresh);
    }

    @Override protected void onPause() {
        handler.removeCallbacks(refresh);
        super.onPause();
    }

    private void updateCall() {
        if (callId == null || callId.isEmpty()) { finish(); return; }
        int state = CallRepository.state(callId);
        if (state == -1 || state == Call.STATE_DISCONNECTED || state == Call.STATE_DISCONNECTING) {
            finish();
            return;
        }
        boolean ringing = "incoming".equals(TelecomStateMapper.toWireState(state));
        String number = CallRepository.number(callId);
        title.setText(ringing
                ? (number.isEmpty() ? "AirSIM 来电" : number)
                : "AirSIM 通话中");
        String modeLabel = AppConfig.MODE_REMOTE_SILENT.equals(AppConfig.mode(this))
                ? "远端静默" : "本机显示";
        detail.setText(ringing
                ? modeLabel + " · 可直接在 Android 接听或拒接；iPhone 也在响时可在任一端处理"
                : modeLabel + " · 点按下方按钮挂断");
        answer.setVisibility(ringing ? View.VISIBLE : View.GONE);
        reject.setVisibility(ringing ? View.VISIBLE : View.GONE);
        end.setVisibility(ringing ? View.GONE : View.VISIBLE);
    }

    private Button button(String text, int color, String action) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextColor(Color.WHITE);
        button.setBackgroundTintList(android.content.res.ColorStateList.valueOf(color));
        button.setOnClickListener(ignored -> {
            detail.setText("正在处理…");
            sendBroadcast(CallNotificationActionReceiver.actionIntent(this, callId, action));
        });
        return button;
    }

    private LinearLayout.LayoutParams buttonLayout() {
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, dp(56));
        layout.topMargin = dp(20);
        return layout;
    }

    private int dp(int value) {
        return Math.round(getResources().getDisplayMetrics().density * value);
    }
}
