package com.brentvatne.exoplayer;

import android.util.Log;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableArray;

import java.io.IOException;
import java.net.URL;
import java.util.List;

import javax.annotation.Nullable;

import okhttp3.Cookie;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

import static com.brentvatne.exoplayer.ReactExoplayerViewManager.toCookies;

public class ReactExoplayerModule extends ReactContextBaseJavaModule {

    public ReactExoplayerModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "VideoManager";
    }

    private static Response getResponse(OkHttpClient httpClient, URL url, @Nullable List<Cookie> cookies) throws IOException {
        Request.Builder builder = new Request.Builder().get().url(url);
        if (cookies != null)
            for (Cookie c : cookies)
                builder.addHeader("Set-Cookie", c.toString());
        return httpClient.newCall(builder.build()).execute();
    }

    @ReactMethod
    public void prefetch(String url, String cacheKey, ReadableArray cookies, Promise promise) {
        try {
            List<Cookie> cookieList = toCookies(cookies);
            OkHttpClient httpClient = DataSourceUtil.getOkHttpClient();

            Response response = getResponse(httpClient, new URL(url), cookieList);
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
                getResponse(httpClient, new URL(new URL(url), line), cookieList);
            }
        } catch (IOException e) {
            promise.resolve(cacheKey);
            //promise.reject(cacheKey, "unable to prefetch", e);
            return;
        }

        promise.resolve(cacheKey);
    }

}
