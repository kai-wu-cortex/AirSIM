package com.airsim.phonecontrol;

/** Only a proven pre-dispatch failure permits trying another sender. */
final class SMSPrivilegedResult {
    private SMSPrivilegedResult() {}
    static String confirmed(SMSConfirmation.Outcome outcome, int segments) {
        if (!outcome.complete()) return "error:send_unknown:callback_timeout";
        if (!outcome.success()) return "error:sent:" + outcome.errorCode();
        return "ok:" + segments;
    }

    static String failureMessage(String result) {
        if (result != null && result.startsWith("error:sent:")) {
            try { return "系统短信发送失败（" + SMSResultCode.describe(Integer.parseInt(result.substring(11))) + "）"; }
            catch (NumberFormatException ignored) { }
        }
        return "短信发送结果尚未确认；为避免重复发送，已停止重试，请先检查收件方";
    }
    static boolean mayFallback(String result) {
        return "unavailable".equals(result) || "error:no_context".equals(result)
                || "error:invalid".equals(result) || "error:no_service".equals(result)
                || "error:divide".equals(result)
                || (result != null && result.startsWith("error:prepare:"));
    }
}
