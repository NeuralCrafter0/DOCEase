package com.medhistory.app.medhistory

import android.os.Bundle
import android.view.WindowManager.LayoutParams
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity: FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Re-enabling screenshot blocking and recent apps black-out
        window.setFlags(LayoutParams.FLAG_SECURE, LayoutParams.FLAG_SECURE)
    }
}
