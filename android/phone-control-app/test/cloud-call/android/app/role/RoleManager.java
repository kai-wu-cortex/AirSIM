package android.app.role;
public final class RoleManager {
    public static final String ROLE_DIALER = "android.app.role.DIALER";
    public boolean isRoleHeld(String role) { return ROLE_DIALER.equals(role); }
}
