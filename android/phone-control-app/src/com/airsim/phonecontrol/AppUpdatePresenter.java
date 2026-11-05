package com.airsim.phonecontrol;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.widget.Toast;
import java.lang.ref.WeakReference;
import java.util.concurrent.Executors;
import java.util.function.BooleanSupplier;

/** Activity-owned dialogs, process-wide single-flight networking on a worker thread. */
final class AppUpdatePresenter {
    private static final AppUpdateSession SESSION = new AppUpdateSession();
    private static WeakReference<AppUpdatePresenter> foregroundOwner = new WeakReference<>(null);
    private static final java.util.concurrent.ExecutorService WORKER = Executors.newSingleThreadExecutor();
    private static final String NOTES_SEEN = "notes_seen", ATTEMPT = "attempt", NOTIFIED = "notified";
    private final WeakReference<Activity> owner;
    private final SharedPreferences preferences;
    private final BooleanSupplier idle;
    private final String version;
    private final long build;
    private final boolean standalone;
    private AlertDialog dialog;

    AppUpdatePresenter(Activity activity, BooleanSupplier idle) {
        owner = new WeakReference<>(activity);
        preferences = activity.getSharedPreferences("airsim-app-updates", Activity.MODE_PRIVATE);
        this.idle = idle;
        String name = ""; long code = 0;
        try {
            var info = activity.getPackageManager().getPackageInfo(activity.getPackageName(), 0);
            name = info.versionName == null ? "" : info.versionName; code = info.getLongVersionCode();
        } catch (Exception ignored) { /* Unknown versions must not offer upgrades. */ }
        version = name; build = code; standalone = RuntimeMode.isStandalone(activity);
    }

    String status() { return SESSION.status(); }

    boolean showStartupNotes(Runnable after) {
        Activity activity = liveOwner();
        if ("MU3356".equals(android.os.Build.MODEL)) {
            preferences.edit().putString(NOTES_SEEN, version + "#" + build).apply();
            return false;
        }
        if (activity == null || !AppUpdatePolicy.needsNotes(version + "#" + build,
                preferences.getString(NOTES_SEEN, ""))) return false;
        if (dialog != null) return true;
        showNotes(after);
        return true;
    }

    void showNotes(Runnable after) {
        Activity activity = liveOwner();
        if (activity == null || dialog != null) return;
        String notes = "• 修复 Android 10 的 SIM 订阅监听兼容性，避免启动 Service 时调用高版本接口崩溃。\n\n"
                + "• 上报设备电量，供兼容的 iPhone 小组件显示；无有效采样时不会伪造电量。\n\n"
                + "• 配套 iPhone build 162 新增小组件、未读短信／未接来电标记与试验性 TLS 公网配对教程。\n\n"
                + "• 改善 Shizuku 短信收件箱兼容性；首次追平只补转近 15 分钟短信，旧短信仅推进游标。\n\n"
                + "• U30Air 客户端与通话收尾改进需要兼容设备端；本 APK 不安装或更新 U30Air 固件。\n\n"
                + "• 反馈仍由用户手动上传；配对和已有数据保留。";
        AlertDialog next = new AlertDialog.Builder(activity).setTitle("当前版本更新内容 · " + version + "（" + build + "）")
                .setMessage(notes).setPositiveButton("知道了", (ignored, which) -> {
                    preferences.edit().putString(NOTES_SEEN, version + "#" + build).apply();
                }).create();
        next.setCancelable(false);
        next.setOnDismissListener(ignored -> { dialog = null; if (liveOwner() != null) after.run(); });
        dialog = next; next.show();
    }

    void foreground() {
        foregroundOwner = new WeakReference<>(this);
        if (liveOwner() == null || !idle.getAsBoolean() || dialog != null) return;
        if (SESSION.pending(preferences.getString(NOTIFIED, "")) != null) presentPending();
        else check(false);
    }

    void check(boolean manual) {
        Activity activity = liveOwner();
        if (activity == null || !SESSION.begin(preferences.getLong(ATTEMPT, 0), System.currentTimeMillis(), manual)) return;
        foregroundOwner = new WeakReference<>(this);
        preferences.edit().putLong(ATTEMPT, System.currentTimeMillis()).apply();
        if (manual) Toast.makeText(activity, "正在检查应用更新…", Toast.LENGTH_SHORT).show();
        WORKER.execute(() -> {
            AppUpdatePolicy.Candidate candidate = null;
            String message;
            try {
                candidate = AppUpdatePolicy.select(AppReleaseClient.fetch(), version, build, standalone);
                message = candidate == null ? "未发现比当前更新的公开应用版本" : "发现应用新版 " + candidate.version();
            } catch (Exception ignored) {
                message = "检查失败，请检查网络或稍后重试；这不表示当前已是最新版。";
            }
            SESSION.finish(new AppUpdateSession.Result(candidate, message, manual));
            new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
                AppUpdatePresenter current = foregroundOwner.get();
                if (current != null) current.presentPending();
            });
        });
    }

    private void presentPending() {
        Activity activity = liveOwner();
        AppUpdateSession.Result result = SESSION.pending(preferences.getString(NOTIFIED, ""));
        if (activity == null || !idle.getAsBoolean() || dialog != null || result == null) return;
        AppUpdatePolicy.Candidate candidate = result.candidate();
        String message = result.message();
        if (candidate != null) message += "\n\n" + candidate.notes()
                + "\n\n将打开此应用的发布页，请选择 " + (standalone ? "Standalone APK" : "AVF Bridge APK")
                + "。同包名、同签名才能保留数据覆盖升级；Debug／第三方重签包可能不能直接覆盖，请勿为绕过签名错误先卸载。不会自动下载或安装。";
        AlertDialog.Builder builder = new AlertDialog.Builder(activity).setTitle("应用更新").setMessage(message)
                .setNegativeButton("关闭", null);
        if (candidate != null) builder.setPositiveButton("查看发布页", (ignored, which) -> {
            try { activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(candidate.page()))); }
            catch (android.content.ActivityNotFoundException ignoredError) {
                Toast.makeText(activity, "没有可打开网页的浏览器", Toast.LENGTH_LONG).show();
            }
        });
        AlertDialog next = builder.create();
        next.setOnDismissListener(ignored -> { dialog = null; });
        dialog = next; next.show();
        if (candidate != null) preferences.edit().putString(NOTIFIED, candidate.identity()).apply();
        SESSION.consumed(result);
    }

    void pause() {
        if (foregroundOwner.get() == this) foregroundOwner.clear();
        if (dialog != null) dialog.dismiss();
    }

    void destroy() {
        if (foregroundOwner.get() == this) foregroundOwner.clear();
        owner.clear();
        if (dialog != null) { dialog.setOnDismissListener(null); dialog.dismiss(); dialog = null; }
    }

    private Activity liveOwner() {
        Activity activity = owner.get();
        return activity == null || activity.isFinishing() || activity.isDestroyed() ? null : activity;
    }
}
