package ninja.rotten.rpodcast

import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val saveRequest = 4711
    private var saving: Pair<String, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The name shown on the server's Devices page, so sign-in needn't ask for one.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rpodcasts/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "name" -> {
                    val set = if (Build.VERSION.SDK_INT >= 25) Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) else null
                    result.success(if (set.isNullOrBlank()) "${Build.MANUFACTURER} ${Build.MODEL}" else set)
                }
                // Whether the phone has a working internet connection, whatever the server is doing.
                "online" -> {
                    val cm = getSystemService(ConnectivityManager::class.java)
                    val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
                    result.success(caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
                }
                else -> result.notImplemented()
            }
        }
        // Saves text through the system "save to" picker, so the user chooses where the file goes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rpodcasts/files").setMethodCallHandler { call, result ->
            val text = call.argument<String>("text")
            if (call.method != "save" || text == null) return@setMethodCallHandler result.notImplemented()
            saving?.second?.success(false)
            saving = Pair(text, result)
            val pick = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("text/x-opml").putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
            try {
                startActivityForResult(pick, saveRequest)
            } catch (e: Exception) {
                saving = null
                result.error("save", "This device has no file picker", null)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveRequest) return
        val (text, result) = saving ?: return
        saving = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) return result.success(false)
        try {
            val out = contentResolver.openOutputStream(uri, "wt") ?: return result.error("save", "Could not open the chosen file", null)
            out.use { it.write(text.toByteArray()) }
            result.success(true)
        } catch (e: Exception) {
            result.error("save", e.message, null)
        }
    }
}
