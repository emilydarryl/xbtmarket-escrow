package tech.xbtpulse.xbt_escrow_rehearsal

import io.flutter.embedding.android.FlutterActivity
import android.os.Bundle
import android.app.Activity
import android.content.Intent
import org.json.JSONObject
import android.view.WindowManager
import android.provider.Settings
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var incomingRequest: String? = null
    private var publicFilesChannel: MethodChannel? = null
    private val requestMime = "application/vnd.xbtmarket.signer-request+json"
    private fun readPublicRequest(uri: android.net.Uri): String {
        require(uri.scheme == "content")
        val bytes = contentResolver.openInputStream(uri)!!.use { input ->
            val buffer = ByteArray(100001)
            var size = 0
            while (size < buffer.size) {
                val count = input.read(buffer, size, buffer.size - size)
                if (count < 0) break
                size += count
            }
            buffer.copyOf(size)
        }
        require(bytes.size <= 100000)
        val text = bytes.toString(Charsets.UTF_8)
        require(JSONObject(text).optString("schema") == "xbt-signer-transfer-v1")
        return text
    }
    private fun receivePublicIntent(value: Intent?) {
        if (!applicationContext.packageName.startsWith("store.xbtmarket.signer.") || value == null) return
        try {
            if (value.action == Intent.ACTION_VIEW && value.data?.scheme == "xbtmarket-signer") {
                val uri = value.data!!
                val role = applicationContext.packageName.substringAfterLast('.')
                require(uri.host == "request" && uri.path == "/" + role && uri.query == null && uri.fragment == null && uri.port == -1 && uri.userInfo == null)
                val text = value.getStringExtra("request") ?: throw IllegalArgumentException()
                require(text.toByteArray(Charsets.UTF_8).size <= 100000)
                val envelope = JSONObject(text)
                require(envelope.optString("schema") == "xbt-signer-transfer-v1" && envelope.optString("origin") == "https://xbtmarket.store" && envelope.optString("role") == role)
                // Untrusted public input: Dart still checks the complete protocol and
                // identity; opening a link never reviews, approves or signs anything.
                incomingRequest = text
                publicFilesChannel?.invokeMethod("incomingAvailable", null)
                return
            }
            if (value.type != requestMime) return
            val uri: android.net.Uri? = when (value.action) {
                Intent.ACTION_VIEW -> value.data
                Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) value.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java) else @Suppress("DEPRECATION") value.getParcelableExtra(Intent.EXTRA_STREAM)
                else -> null
            }
            incomingRequest = if (uri != null) readPublicRequest(uri) else null
            if (incomingRequest != null) publicFilesChannel?.invokeMethod("incomingAvailable", null)
        } catch (_: Exception) { incomingRequest = null }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receivePublicIntent(intent)
    }
    private var fileResult: MethodChannel.Result? = null
    private var approvalContent: String? = null
    private val openRequest = 8061
    private val saveApproval = 8062
    private val publicSchemas = setOf("xbt-signer-selection-v1", "xbt-production-contract-proof-v1", "xbt-production-funding-proof-v1", "xbt-production-resolution-proof-v1", "xbt-production-spend-signed-v2", "xbt-order-withdrawal-signed-v1")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != openRequest && requestCode != saveApproval) return
        val callback = fileResult ?: return
        fileResult = null
        val content = approvalContent
        approvalContent = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            callback.success(if (requestCode == openRequest) null else false)
            return
        }
        try {
            val uri = data.data!!
            require(uri.scheme == "content")
            if (requestCode == openRequest) {
                val text = readPublicRequest(uri)
                callback.success(text)
            } else {
                require(content != null)
                contentResolver.openOutputStream(uri, "wt")!!.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                callback.success(true)
            }
        } catch (_: Exception) { callback.error("public_file", "Public file could not be processed", null) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (applicationContext.packageName.startsWith("store.xbtmarket.signer.")) {
            publicFilesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "store.xbtmarket/public-files")
            publicFilesChannel!!.setMethodCallHandler { call, result ->
                if (fileResult != null) { result.error("busy", "Finish the file picker first", null); return@setMethodCallHandler }
                try {
                    when (call.method) {
                        "takeIncoming" -> { val pending = incomingRequest; incomingRequest = null; result.success(pending) }
                        "open" -> {
                            fileResult = result
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "*/*"; putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", requestMime)); addCategory(Intent.CATEGORY_OPENABLE) }, openRequest)
                        }
                        "returnApproval" -> {
                            val content = call.argument<String>("content") ?: throw IllegalArgumentException()
                            require(content.toByteArray(Charsets.UTF_8).size <= 24000)
                            val envelope = JSONObject(content)
                            require(envelope.optString("schema") == "xbt-signer-return-v1" && envelope.getJSONObject("result").optString("schema") in publicSchemas)
                            val target = android.net.Uri.parse("https://xbtmarket.store/market/signer-return#" + android.net.Uri.encode(content))
                            require(target.toString().length <= 32000)
                            startActivity(Intent(Intent.ACTION_VIEW, target).addCategory(Intent.CATEGORY_BROWSABLE))
                            result.success(true)
                        }
                        "save" -> {
                            val content = call.argument<String>("content") ?: throw IllegalArgumentException()
                            require(content.toByteArray(Charsets.UTF_8).size <= 24000 && JSONObject(content).optString("schema") in publicSchemas)
                            approvalContent = content; fileResult = result
                            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply { type = "application/json"; addCategory(Intent.CATEGORY_OPENABLE); putExtra(Intent.EXTRA_TITLE, "xbt-public-approval.json") }, saveApproval)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { fileResult = null; approvalContent = null; result.error("public_file", "Public file operation unavailable", null) }
            }
        }
        if (applicationContext.packageName == "tech.xbtpulse.escrow_selftest") {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tech.xbtpulse.selftest/restart").setMethodCallHandler { call, result ->
                if (call.method != "bootCount") {
                    result.notImplemented()
                } else {
                    try {
                        val count = if (Build.VERSION.SDK_INT >= 24) Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, -1) else -1
                        result.success(if (count >= 0) count else null)
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }
            }
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        receivePublicIntent(intent)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (applicationContext.packageName == "tech.xbtpulse.escrow_selftest") {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
