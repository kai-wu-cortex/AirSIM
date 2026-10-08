package com.airsim.phonecontrol;

/** Keeps SMS commands out of the Telecom call-ID path. */
final class AgentCommandDispatcher {
    interface Executor {
        Result execute(AgentCommand command);
    }

    record Result(boolean success, String error, int segments) {
        static Result success(int segments) { return new Result(true, "", segments); }
        static Result failure(String error) { return new Result(false, error, 0); }
    }

    private AgentCommandDispatcher() {}

    static Result execute(AgentCommand command, boolean dialerRoleHeld,
                          Executor telecom, Executor sms) {
        if (!command.isSupported()) return Result.failure("unsupported action");
        if ("send_sms".equals(command.action)) return sms.execute(command);
        if (TelecomRolePolicy.requiresDialerRole(command.action) && !dialerRoleHeld) {
            return Result.failure("AirSIM 不是默认电话应用；请在三星默认应用设置中选择 AirSIM");
        }
        return telecom.execute(command);
    }
}
