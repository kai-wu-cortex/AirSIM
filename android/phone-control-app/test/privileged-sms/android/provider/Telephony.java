package android.provider;

import android.net.Uri;

public final class Telephony {
    public static final class Sms {
        public static final class Inbox {
            public static final Uri CONTENT_URI = Uri.parse("content://sms/inbox");
        }
    }
}
