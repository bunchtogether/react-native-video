package com.brentvatne.react;

import android.util.Log;

import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

public class ReactVideoModule extends ReactContextBaseJavaModule {

    public ReactVideoModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "VideoManager";
    }

    @ReactMethod
    public void prefetch(String uri, String cacheKey) {
        Log.d("ReactNative", "bottom prefetch to " + uri);
    }
}