package com.brentvatne.exoplayer;

import android.content.Context;

import com.google.android.exoplayer2.ext.okhttp.OkHttpDataSourceFactory;
import com.google.android.exoplayer2.upstream.DataSource;
import com.google.android.exoplayer2.upstream.DefaultBandwidthMeter;
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory;
import com.google.android.exoplayer2.upstream.HttpDataSource;
import com.google.android.exoplayer2.util.Util;

import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;

public class DataSourceUtil {

    private DataSourceUtil() {
    }

    private static DataSource.Factory rawDataSourceFactory = null;
    private static DataSource.Factory defaultDataSourceFactory = null;
    private static String userAgent = null;

    public static void setUserAgent(String userAgent) {
        DataSourceUtil.userAgent = userAgent;
    }

    public static String getUserAgent(Context context) {
        if (userAgent == null) {
            userAgent = Util.getUserAgent(context.getApplicationContext(), "ReactNativeVideo");
        }
        return userAgent;
    }

    public static DataSource.Factory getRawDataSourceFactory(Context context) {
        if (rawDataSourceFactory == null) {
            rawDataSourceFactory = buildRawDataSourceFactory(context);
        }
        return rawDataSourceFactory;
    }

    public static void setRawDataSourceFactory(DataSource.Factory factory) {
        DataSourceUtil.rawDataSourceFactory = factory;
    }

    public static DataSource.Factory getDefaultDataSourceFactory(Context context, DefaultBandwidthMeter bandwidthMeter) {
        if (defaultDataSourceFactory == null) {
            defaultDataSourceFactory = buildDataSourceFactory(context, bandwidthMeter);
        }
        return defaultDataSourceFactory;
    }

    public static void setDefaultDataSourceFactory(DataSource.Factory factory) {
        DataSourceUtil.defaultDataSourceFactory = factory;
    }

    private static DataSource.Factory buildRawDataSourceFactory(Context context) {
        return new RawResourceDataSourceFactory(context.getApplicationContext());
    }

    private static DataSource.Factory buildDataSourceFactory(Context context, DefaultBandwidthMeter bandwidthMeter) {
        Context appContext = context.getApplicationContext();
        return new DefaultDataSourceFactory(appContext, bandwidthMeter,
                buildHttpDataSourceFactory(appContext, bandwidthMeter));
    }

    private static OkHttpClient sClient;
    public static OkHttpClient getOkHttpClient() {
        if (sClient == null) {
            sClient = new OkHttpClient.Builder()
                    .connectTimeout(0, TimeUnit.MILLISECONDS)
                    .readTimeout(0, TimeUnit.MILLISECONDS)
                    .writeTimeout(0, TimeUnit.MILLISECONDS)
                    /*
                    .addInterceptor(new Interceptor() {
                        @Override
                        public Response intercept(@NonNull Chain chain) throws IOException {
                            Request request = chain.request();
                            Log.d("ReactExoplayer", "request to " + request.url().toString());
                            return chain.proceed(request);
                        }
                    })
                    */
                    .build();
        }
        return sClient;
    }

    private static HttpDataSource.Factory buildHttpDataSourceFactory(Context context, DefaultBandwidthMeter bandwidthMeter) {
        return new OkHttpDataSourceFactory(getOkHttpClient(), getUserAgent(context), bandwidthMeter);
    }

}
