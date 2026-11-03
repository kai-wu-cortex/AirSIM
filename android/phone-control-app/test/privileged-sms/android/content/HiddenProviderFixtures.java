package android.content;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ICancellationSignal;

/** AOSP ContentProviderProxy is non-public, even though query is public. */
public final class HiddenProviderFixtures {
    public static Object provider(int api) {
        return api >= 31 ? new Modern() : api == 30 ? new R() : new Q();
    }
    private static final class Modern {
        public Cursor query(AttributionSource source, Uri uri, String[] projection,
                Bundle args, ICancellationSignal cancellation) { return null; }
    }
    private static final class R {
        public Cursor query(String pkg, String tag, Uri uri, String[] projection,
                Bundle args, ICancellationSignal cancellation) { return null; }
    }
    private static final class Q {
        public Cursor query(String pkg, Uri uri, String[] projection,
                Bundle args, ICancellationSignal cancellation) { return null; }
    }
}
