package com.airsim.phonecontrol;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class InstallerClient {
    private static final String DEBIAN_CONTENT_TYPE = "application/vnd.debian.binary-package";
    private static final int MAX_PACKAGE_BYTES = 64 * 1024 * 1024;

    private final String endpoint;
    private final String token;

    public InstallerClient(Context context) {
        Context appContext = context.getApplicationContext();
        endpoint = AppConfig.installerEndpoint(appContext);
        token = AppConfig.token(appContext);
    }

    InstallerClient(String endpoint, String token) {
        this.endpoint = endpoint;
        this.token = token;
    }

    public String status() throws Exception {
		return request("GET", "/v1/status", null, null, null, 5_000);
    }

    public String install(byte[] debianPackage, String signatureBase64) throws Exception {
		return installWithMode(debianPackage, signatureBase64, "normal");
	}

	public String repair(byte[] debianPackage, String signatureBase64) throws Exception {
		return installWithMode(debianPackage, signatureBase64, "repair");
	}

	private String installWithMode(byte[] debianPackage, String signatureBase64, String mode) throws Exception {
        if (debianPackage == null || debianPackage.length == 0 || debianPackage.length > MAX_PACKAGE_BYTES) {
            throw new IllegalArgumentException("Debian 安装包为空或超过 64 MiB");
        }
        String signature = signatureBase64 == null ? "" : signatureBase64.trim();
        if (signature.isEmpty()) {
            throw new IllegalArgumentException("缺少安装包签名");
        }
		return request("POST", "/v1/packages/install", debianPackage, signature, mode, 120_000);
    }

    public String rollback() throws Exception {
		return request("POST", "/v1/packages/rollback", new byte[0], null, null, 120_000);
    }

	private String request(String method, String path, byte[] body, String signature, String mode, int timeout) throws Exception {
        if (endpoint == null || endpoint.isEmpty() || token == null || token.length() < 24) {
            throw new IllegalStateException("AirSIM installer 尚未配对");
        }
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(endpoint + path).openConnection();
            connection.setRequestMethod(method);
            connection.setConnectTimeout(3_000);
            connection.setReadTimeout(timeout);
            connection.setUseCaches(false);
            connection.setRequestProperty("Authorization", "Bearer " + token);
            if (body != null) {
                connection.setDoOutput(true);
                if (signature != null) {
                    connection.setRequestProperty("Content-Type", DEBIAN_CONTENT_TYPE);
                    connection.setRequestProperty("X-AirSIM-Signature", signature);
					connection.setRequestProperty("X-AirSIM-Install-Mode", mode);
                }
                try (OutputStream output = connection.getOutputStream()) {
                    output.write(body);
                }
            }
            int status = connection.getResponseCode();
            InputStream stream = status >= 200 && status < 300
                    ? connection.getInputStream() : connection.getErrorStream();
            String payload = read(stream);
            if (status < 200 || status >= 300) {
                throw new IllegalStateException("Installer HTTP " + status + ": " + payload);
            }
            return payload;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private static String read(InputStream input) throws Exception {
        if (input == null) return "";
        try (input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return output.toString(StandardCharsets.UTF_8);
        }
    }
}
