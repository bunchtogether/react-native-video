package com.brentvatne.exoplayer;

import android.content.Context;
import android.content.ContextWrapper;
import android.util.Log;

import com.facebook.react.bridge.ReactContext;
import com.facebook.react.modules.network.CookieJarContainer;
import com.facebook.react.modules.network.ForwardingCookieHandler;
import com.facebook.react.modules.network.OkHttpClientProvider;
import com.google.android.exoplayer2.ext.okhttp.OkHttpDataSourceFactory;
import com.google.android.exoplayer2.upstream.DataSource;
import com.google.android.exoplayer2.upstream.DefaultBandwidthMeter;
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory;
import com.google.android.exoplayer2.upstream.HttpDataSource;
import com.google.android.exoplayer2.util.Util;

import okhttp3.Cookie;
import okhttp3.JavaNetCookieJar;
import okhttp3.OkHttpClient;

import java.io.IOException;
import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class DataSourceUtil {

    private DataSourceUtil() {
    }

    private static DataSource.Factory rawDataSourceFactory = null;
    private static DataSource.Factory defaultDataSourceFactory = null;
    private static String userAgent = null;

    public static void setUserAgent(String userAgent) {
        DataSourceUtil.userAgent = userAgent;
    }

    public static String getUserAgent(ReactContext context) {
        if (userAgent == null) {
            userAgent = Util.getUserAgent(context, "ReactNativeVideo");
        }
        return userAgent;
    }

    public static DataSource.Factory getRawDataSourceFactory(ReactContext context) {
        if (rawDataSourceFactory == null) {
            rawDataSourceFactory = buildRawDataSourceFactory(context);
        }
        return rawDataSourceFactory;
    }

    public static void setRawDataSourceFactory(DataSource.Factory factory) {
        DataSourceUtil.rawDataSourceFactory = factory;
    }


    public static DataSource.Factory getDefaultDataSourceFactory(ReactContext context, DefaultBandwidthMeter bandwidthMeter, Map<String, String> requestHeaders, List<Cookie> cookies) {
        if (defaultDataSourceFactory == null || (requestHeaders != null && !requestHeaders.isEmpty()) || (cookies != null && cookies.size() > 0)) {
            defaultDataSourceFactory = buildDataSourceFactory(context, bandwidthMeter, requestHeaders, cookies);
        }
        return defaultDataSourceFactory;
    }

    public static void setDefaultDataSourceFactory(DataSource.Factory factory) {
        DataSourceUtil.defaultDataSourceFactory = factory;
    }

    private static DataSource.Factory buildRawDataSourceFactory(ReactContext context) {
        return new RawResourceDataSourceFactory(context.getApplicationContext());
    }

    private static DataSource.Factory buildDataSourceFactory(ReactContext context, DefaultBandwidthMeter bandwidthMeter, Map<String, String> requestHeaders, List<Cookie> cookies) {
        return new DefaultDataSourceFactory(context, bandwidthMeter,
                buildHttpDataSourceFactory(context, bandwidthMeter, requestHeaders, cookies));
    }

    public static OkHttpClient getOkHttpClient() {
        return OkHttpClientProvider.getOkHttpClient();
    }

    private static HttpDataSource.Factory buildHttpDataSourceFactory(ReactContext context, DefaultBandwidthMeter bandwidthMeter, Map<String, String> requestHeaders, List<Cookie> cookies) {
        OkHttpClient client = OkHttpClientProvider.getOkHttpClient();
        CookieJarContainer container = (CookieJarContainer) client.cookieJar();
        ForwardingCookieHandler handler = new ForwardingCookieHandler(context);
        container.setCookieJar(new JavaNetCookieJar(handler));
        OkHttpDataSourceFactory okHttpDataSourceFactory = new OkHttpDataSourceFactory(client, getUserAgent(context), bandwidthMeter);

        // add in cookies
        if (cookies != null) {
            for (Cookie cookie : cookies) {
                try {
                    Map<String, List<String>> map = new HashMap<>(1);
                    ArrayList<String> cookieStr = new ArrayList<>(1);
                    cookieStr.add(cookie.toString());
                    map.put("Set-Cookie", cookieStr);
                    Log.e("Cookies","video cookie " + cookie.toString() + " for " + cookie.domain());
                    handler.put(URI.create("https://" + cookie.domain()), map);
                } catch (IOException e) {
                    Log.e("DataSourceUtil", "unable to add cookie", e);
                }
            }
        }

        if (requestHeaders != null)
            okHttpDataSourceFactory.getDefaultRequestProperties().set(requestHeaders);

        return okHttpDataSourceFactory;
    }
}
