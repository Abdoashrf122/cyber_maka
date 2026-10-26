package com.cybermaka.maka_admin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** بعد إعادة تشغيل الموبايل أو تحديث التطبيق: الخدمة ترجع تشتغل لوحدها */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (MakaPrefs(ctx).ready) MakaService.start(ctx)
    }
}
