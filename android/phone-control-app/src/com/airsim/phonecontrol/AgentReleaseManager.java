package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

public final class AgentReleaseManager {
    private static final String LATEST_RELEASE_API =
            "https://api.github.com/repos/kai-wu-cortex/AirSIM/releases/latest";
    private static final int MAX_PACKAGE_BYTES = 64 * 1024 * 1024;

    private final InstallerClient installer;

    public AgentReleaseManager(Context context) {
        installer = new InstallerClient(context);
    }

    public String status() throws Exception {
        return installer.status();
    }

    public String installLatest() throws Exception {
        DownloadedRelease release = downloadLatest();
        return release.selection.packageName() + "\n" +
                installer.install(release.debianPackage, release.signature);
    }

    public String repairLatest() throws Exception {
        DownloadedRelease release = downloadLatest();
        return release.selection.packageName() + "\n" +
                installer.repair(release.debianPackage, release.signature);
    }

    public String rollback() throws Exception {
        return installer.rollback();
    }

    private DownloadedRelease downloadLatest() throws Exception {
        JSONObject release = new JSONObject(new String(
                download(LATEST_RELEASE_API, 1024 * 1024), StandardCharsets.UTF_8));
        JSONArray assets = release.getJSONArray("assets");
        Map<String, String> URLs = new LinkedHashMap<>();
        for (int index = 0; index < assets.length(); index++) {
            JSONObject asset = assets.getJSONObject(index);
            URLs.put(asset.getString("name"), asset.getString("browser_download_url"));
        }
        ReleaseAssetSelector.Selection selection = ReleaseAssetSelector.select(URLs);
        byte[] debianPackage = download(selection.packageURL(), MAX_PACKAGE_BYTES);
        String signature = new String(download(selection.signatureURL(), 4096), StandardCharsets.US_ASCII).trim();
        if (signature.isEmpty()) throw new IllegalStateException("Release 签名为空");
        return new DownloadedRelease(selection, debianPackage, signature);
    }

    private static byte[] download(String value, int maximumBytes) throws Exception {
        URI uri = URI.create(value);
        if (!"https".equals(uri.getScheme())) throw new IllegalArgumentException("Release 下载必须使用 HTTPS");
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(value).openConnection();
            connection.setConnectTimeout(8_000);
            connection.setReadTimeout(60_000);
            connection.setUseCaches(false);
            connection.setRequestProperty("Accept", "application/vnd.github+json");
            connection.setRequestProperty("User-Agent", "AirSIM-Android");
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                throw new IllegalStateException("Release HTTP " + status);
            }
            if (!"https".equals(connection.getURL().getProtocol())) {
                throw new IllegalStateException("Release 重定向离开 HTTPS");
            }
            int length = connection.getContentLength();
            if (length > maximumBytes) throw new IllegalStateException("Release 文件过大");
            try (InputStream input = connection.getInputStream();
                 ByteArrayOutputStream output = new ByteArrayOutputStream(Math.max(0, length))) {
                byte[] buffer = new byte[8192];
                int count;
                int total = 0;
                while ((count = input.read(buffer)) >= 0) {
                    total += count;
                    if (total > maximumBytes) throw new IllegalStateException("Release 文件过大");
                    output.write(buffer, 0, count);
                }
                return output.toByteArray();
            }
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private record DownloadedRelease(
            ReleaseAssetSelector.Selection selection, byte[] debianPackage, String signature) {}
}
