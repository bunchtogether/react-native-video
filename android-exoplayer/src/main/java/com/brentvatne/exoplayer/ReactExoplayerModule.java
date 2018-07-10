package com.brentvatne.exoplayer;

import android.util.Log;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

import java.io.IOException;
import java.net.URL;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

public class ReactExoplayerModule extends ReactContextBaseJavaModule {

    public ReactExoplayerModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "VideoManager";
    }

    private static Response getResponse(OkHttpClient httpClient, String url) throws IOException {
        return httpClient.newCall(new Request.Builder().get().url(url).build()).execute();
    }

    private static void getResponse(OkHttpClient httpClient, URL url) throws IOException {
        httpClient.newCall(new Request.Builder().get().url(url).build()).execute();
    }

    @ReactMethod
    public void prefetch(final String url, final String cacheKey, final Promise promise) {
        try {
            OkHttpClient httpClient = DataSourceUtil.getOkHttpClient();
            Response response = getResponse(httpClient, url);
            if (response.code() < 200 || response.code() >= 300) {
                promise.resolve(cacheKey);
                //promise.reject(cacheKey, "unable to retrieve playlist");
                return;
            }
            ResponseBody body = response.body();
            if (body == null) {
                promise.resolve(cacheKey);
                //promise.reject(cacheKey, "unable to read playlist");
                return;
            }
            String[] playlist = body.string().split("\n");
            for (String line : playlist) {
                if (line.charAt(0) == '#')
                    continue;
                //Log.d("ReactExoplayerModule", "fetching: " + new URL(new URL(url), line).toString());
                getResponse(httpClient, new URL(new URL(url), line));
            }
        } catch (IOException e) {
            promise.resolve(cacheKey);
            //promise.reject(cacheKey, "unable to prefetch", e);
            return;
        }

        promise.resolve(cacheKey);
    }

}
