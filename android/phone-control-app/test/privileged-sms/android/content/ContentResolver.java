package android.content;

import android.database.Cursor;
import android.net.Uri;

/** What a ContentResolver query gets inside the Shizuku user service on a real device (issue #22). */
public class ContentResolver {
    public final Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs,
            String sortOrder) {
        throw new SecurityException("Given calling package android does not match caller's uid 2000");
    }
}
