package com.cups.print

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PageRange
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import com.hp.jipp.encoding.IppPacket
import com.hp.jipp.model.BinaryGroup
import com.hp.jipp.model.Operation
import com.hp.jipp.model.Types
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URI
import java.util.concurrent.TimeUnit
import java.util.concurrent.LinkedBlockingQueue

class MainActivity : FlutterActivity() {
    private val TAG = "MainActivityNSD"
    private val CHANNEL = "com.cups.print/ipp"
    private var channelInstance: MethodChannel? = null

    // NSD (mDNS/Bonjour) 服务搜索核心组件（同时扫描明文和加密两种 IPP 服务类型）
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val serviceTypes = listOf("_ipp._tcp", "_ipps._tcp")

    // 解决 Android 原生 NsdManager.resolveService 并发 Resolve 导致已经解析报错的“解析排队队列”
    private val resolveQueue = LinkedBlockingQueue<NsdServiceInfo>()
    private var isResolving = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channelInstance = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "executeIppPrint" -> {
                    val pdfPath = call.argument<String>("pdfPath")
                    val ip = call.argument<String>("ip")
                    val port = call.argument<String>("port")
                    val queue = call.argument<String>("queue")
                    val copies = call.argument<Int>("copies") ?: 1
                    val duplex = call.argument<Boolean>("duplex") ?: false
                    val selectedPages = call.argument<List<Int>>("selectedPages")

                    if (pdfPath == null || ip == null || port == null || queue == null) {
                        result.error("INVALID_ARGUMENTS", "核心打印参数缺失", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        var pdfFile = File(pdfPath)
                        // 如果用户进行了精细化预览页码裁剪，在本地极速生成一个高保真的临时 PDF 提交打印
                        if (selectedPages != null && selectedPages.isNotEmpty()) {
                            val croppedFile = File(cacheDir, "cropped_${System.currentTimeMillis()}.pdf")
                            if (cropPdf(pdfFile, croppedFile, selectedPages)) {
                                pdfFile = croppedFile
                            }
                        }
                        val printerUrl = "http://$ip:$port/printers/$queue"
                        val printResult = executeIppPrint(pdfFile, printerUrl, copies, duplex)
                        withContext(Dispatchers.Main) {
                            result.success(printResult.success)
                        }
                    }
                }
                "fetchCupsPrinters" -> {
                    val ip = call.argument<String>("ip")
                    val port = call.argument<String>("port")

                    if (ip == null || port == null) {
                        result.error("INVALID_ARGUMENTS", "服务器 IP 或端口为空", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val printerNames = fetchCupsPrinters(ip, port)
                            withContext(Dispatchers.Main) {
                                result.success(printerNames)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("FETCH_FAILED", e.localizedMessage ?: "拉取失败", null)
                            }
                        }
                    }
                }
                // 启动 mDNS/Bonjour 局域网服务发现自动探测
                "startNsdDiscovery" -> {
                    try {
                        startNsdDiscovery()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("NSD_START_FAILED", e.localizedMessage, null)
                    }
                }
                // 停止 mDNS/Bonjour 局域网服务发现自动探测
                "stopNsdDiscovery" -> {
                    stopNsdDiscovery()
                    result.success(true)
                }
                // 新功能：App 内部 100% 离线 Word/Excel 静默转码渲染引擎
                "convertOfficeToPdf" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_ARGUMENTS", "文档路径为空", null)
                        return@setMethodCallHandler
                    }

                    // 必须在 Android UI 主线程启动 WebView 渲染
                    runOnUiThread {
                        convertOfficeToPdf(filePath, result)
                    }
                }
                // 新功能：实时打印机状态与耗材（卡纸/缺纸/缺墨）单播探测
                "fetchPrinterStatus" -> {
                    val ip = call.argument<String>("ip")
                    val port = call.argument<String>("port")
                    val queue = call.argument<String>("queue")

                    if (ip == null || port == null || queue == null) {
                        result.error("INVALID_ARGUMENTS", "参数缺失", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val statusMap = fetchPrinterStatus(ip, port, queue)
                            withContext(Dispatchers.Main) {
                                result.success(statusMap)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("STATUS_FAILED", e.localizedMessage, null)
                            }
                        }
                    }
                }
                // 新功能：打印队列当前任务进度及排队深度追踪
                "fetchJobStatus" -> {
                    val ip = call.argument<String>("ip")
                    val port = call.argument<String>("port")
                    val queue = call.argument<String>("queue")

                    if (ip == null || port == null || queue == null) {
                        result.error("INVALID_ARGUMENTS", "参数缺失", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val jobDepthMap = fetchJobDepthStatus(ip, port, queue)
                            withContext(Dispatchers.Main) {
                                result.success(jobDepthMap)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("JOB_STATUS_FAILED", e.localizedMessage, null)
                            }
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        stopNsdDiscovery()
        super.onDestroy()
    }

    /**
     * 启动 mDNS / Bonjour 局域网广播搜寻（同时扫描 _ipp._tcp 和 _ipps._tcp）
     */
    private fun startNsdDiscovery() {
        if (nsdManager == null) {
            nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
        }

        if (discoveryListener != null) {
            stopNsdDiscovery()
        }

        resolveQueue.clear()
        isResolving = false

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "启动 $serviceType 发现失败，错误代码: $errorCode")
                // 不立即 stop，让其他服务类型继续
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "停止 $serviceType 发现失败，错误代码: $errorCode")
                nsdManager?.stopServiceDiscovery(this)
            }

            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "局域网 mDNS/Bonjour 自动探测已开启，正在搜索 $serviceType 类型的广播节点...")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "局域网 mDNS/Bonjour 自动探测已成功关闭 ($serviceType)")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "发现局域网服务节点: ${serviceInfo.serviceName} (${serviceInfo.serviceType})")
                if (serviceInfo.serviceType.contains("ipp")) {
                    resolveQueue.add(serviceInfo)
                    processNextResolve()
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.w(TAG, "服务节点已下线: ${serviceInfo.serviceName}")
            }
        }

        for (type in serviceTypes) {
            try {
                nsdManager?.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            } catch (e: Exception) {
                Log.e(TAG, "启动 $type 发现异常: ${e.message}")
            }
        }
    }

    private fun stopNsdDiscovery() {
        if (nsdManager != null && discoveryListener != null) {
            try {
                nsdManager?.stopServiceDiscovery(discoveryListener)
            } catch (e: Exception) {
                Log.w(TAG, "注销NSD监听异常: ${e.message}")
            }
            discoveryListener = null
        }
        resolveQueue.clear()
        isResolving = false
    }

    @Synchronized
    private fun processNextResolve() {
        if (isResolving) return
        val nextService = resolveQueue.poll() ?: return
        isResolving = true

        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "解析服务节点IP失败 -> 名称: ${serviceInfo.serviceName}, 错误码: $errorCode")
                isResolving = false
                processNextResolve()
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val hostIp = serviceInfo.host?.hostAddress
                val port = serviceInfo.port
                val queueName = serviceInfo.serviceName

                Log.d(TAG, "成功解析服务节点 -> 名称: $queueName, IP: $hostIp, 端口: $port")

                if (hostIp != null) {
                    runOnUiThread {
                        channelInstance?.invokeMethod("onPrinterDiscovered", mapOf(
                            "name" to queueName,
                            "ip" to hostIp,
                            "port" to port.toString()
                        ))
                    }
                }

                isResolving = false
                processNextResolve()
            }
        }

        try {
            nsdManager?.resolveService(nextService, resolveListener)
        } catch (e: Exception) {
            Log.e(TAG, "提交解析任务抛出异常: ${e.message}")
            isResolving = false
            processNextResolve()
        }
    }

    /**
     * 基于 WebView 离线渲染与 assets 资源，实现本地 Word/Excel 文档转码 PDF 的逻辑。
     */
    private fun convertOfficeToPdf(filePath: String, result: MethodChannel.Result) {
        val file = File(filePath)
        if (!file.exists()) {
            result.error("FILE_NOT_FOUND", "Office 物理文件不存在", null)
            return
        }

        val nameLower = file.name.toLowerCase()
        val isWord = nameLower.endsWith(".docx")
        val isExcel = nameLower.endsWith(".xlsx") || nameLower.endsWith(".xls")

        if (!isWord && !isExcel) {
            result.error("UNSUPPORTED_FORMAT", "仅支持本地转换 .docx 与 .xlsx 格式文件", null)
            return
        }

        try {
            // 1. 读取本地文档二进制流并序列化为 Base64 格式
            val fileBytes = file.readBytes()
            val base64Data = Base64.encodeToString(fileBytes, Base64.NO_WRAP)

            // 2. 实例化一个静默不可见的 WebView，确保 UI 无感
            val webView = WebView(this)
            webView.visibility = View.INVISIBLE
            
            val settings = webView.settings
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = true
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW

            // 3. 构造 JavaScript 交互接口，监听离线排版是否结束
            val bridge = object : Any() {
                @JavascriptInterface
                fun onRenderFinished() {
                    // 必须在 Android UI 主线程触发虚拟打印导出
                    runOnUiThread {
                        val outputPdfFile = File(cacheDir, "[已转码]_${file.nameWithoutExtension}.pdf")
                        if (outputPdfFile.exists()) outputPdfFile.delete()

                        saveWebViewToPdf(webView, outputPdfFile) { success ->
                            if (success) {
                                // 转码成功！将本地 PDF 物理文件路径安全抛回 Flutter 预览打印
                                result.success(outputPdfFile.absolutePath)
                            } else {
                                result.error("EXPORT_FAILED", "系统虚拟打印适配器静默写出 PDF 失败", null)
                            }
                            // 及时回收 webview 内存
                            webView.destroy()
                        }
                    }
                }

                @JavascriptInterface
                fun onRenderFailed(errorMsg: String) {
                    runOnUiThread {
                        result.error("RENDER_ERROR", "离线 JS 排版引擎报错: $errorMsg", null)
                        webView.destroy()
                    }
                }
            }

            webView.addJavascriptInterface(bridge, "AndroidConverterBridge")

            // 4. 设置 WebView 客户端回调，页面加载完毕后开始喂送数据流
            webView.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    super.onPageFinished(view, url)
                    if (isWord) {
                        webView.evaluateJavascript("javascript:convertWordToBase64('$base64Data')", null)
                    } else {
                        webView.evaluateJavascript("javascript:convertExcelToBase64('$base64Data')", null)
                    }
                }
            }

            // 5. 加载 assets 下打包好的离线 HTML5 转码模块
            if (isWord) {
                webView.loadUrl("file:///android_asset/word_converter.html")
            } else {
                webView.loadUrl("file:///android_asset/excel_converter.html")
            }

        } catch (e: Exception) {
            result.error("CONVERSION_FAILED", "本地 WebView 初始化转码失败: ${e.message}", null)
        }
    }

    /**
     * 调用系统打印适配器 PrintDocumentAdapter 的 onLayout 与 onWrite 回调，
     * 将 WebView 的网页排版结果输出保存为本地 PDF 物理文件。
     */
    private fun saveWebViewToPdf(webView: WebView, outputFile: File, onComplete: (Boolean) -> Unit) {
        val adapter = webView.createPrintDocumentAdapter("OfficeConvertJob")
        val attributes = PrintAttributes.Builder()
            .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
            .setResolution(PrintAttributes.Resolution("pdf", "pdf", 300, 300))
            .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
            .build()

        try {
            val descriptor = ParcelFileDescriptor.open(
                outputFile,
                ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE
            )

            // 发起虚拟静默 Layout 渲染排版请求
            adapter.onLayout(null, attributes, null, object : PrintDocumentAdapter.LayoutResultCallback() {
                override fun onLayoutFinished(info: PrintDocumentInfo?, changed: Boolean) {
                    // 排版成功，开始静默写入本地文件
                    adapter.onWrite(arrayOf(PageRange.ALL_PAGES), descriptor, null, object : PrintDocumentAdapter.WriteResultCallback() {
                        override fun onWriteFinished(pages: Array<out PageRange>?) {
                            try {
                                descriptor.close()
                            } catch (_: Exception) {}
                            onComplete(true)
                        }

                        override fun onWriteFailed(error: CharSequence?) {
                            try {
                                descriptor.close()
                            } catch (_: Exception) {}
                            onComplete(false)
                        }

                        override fun onWriteCancelled() {
                            try {
                                descriptor.close()
                            } catch (_: Exception) {}
                            onComplete(false)
                        }
                    })
                }

                override fun onLayoutFailed(error: CharSequence?) {
                    try {
                        descriptor.close()
                    } catch (_: Exception) {}
                    onComplete(false)
                }
            }, null)

        } catch (e: Exception) {
            Log.e(TAG, "静默虚拟打印抛出异常: ${e.message}")
            onComplete(false)
        }
    }

    /**
     * 原生 IPP 状态单播获取：通过 getPrinterAttributes 请求，提取缺纸/卡纸/缺墨硬件状态
     */
    private fun fetchPrinterStatus(ip: String, port: String, queue: String): Map<String, String> {
        val printerUrl = "http://$ip:$port/printers/$queue"
        
        // 1. 组装标准 IPP Get-Printer-Attributes 动作报文
        val packet = IppPacket.builder(Operation.getPrinterAttributes)
            .put(BinaryGroup.operationAttributes, Types.attributesCharset, "utf-8")
            .put(BinaryGroup.operationAttributes, Types.attributesNaturalLanguage, "en-us")
            .put(BinaryGroup.operationAttributes, Types.printerUri, URI.create(printerUrl))
            .build()

        val ippBytes = packet.write()

        // 2. 发送单播请求
        val client = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .build()

        val mediaType = "application/ipp".toMediaType()
        val requestBody = ippBytes.toRequestBody(mediaType)
        val request = Request.Builder().url(printerUrl).post(requestBody).build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw Exception("HTTP ${response.code}: ${response.message}")
            }
            val responseBytes = response.body?.bytes() ?: throw Exception("返回为空")
            val responsePacket = IppPacket.read(responseBytes)

            var state = "unknown"
            var reasons = "none"

            // 3. 解析 printer-state 和 printer-state-reasons 硬件诊断属性
            for (group in responsePacket.attributeGroups) {
                if (group.tag == BinaryGroup.printerAttributes) {
                    val stateAttr = group[Types.printerState]
                    if (stateAttr != null && stateAttr.isNotEmpty()) {
                        state = stateAttr.first().toString() // idle, processing, stopped
                    }
                    val reasonsAttr = group[Types.printerStateReasons]
                    if (reasonsAttr != null && reasonsAttr.isNotEmpty()) {
                        reasons = reasonsAttr.joinToString(",") { it.toString() } // media-empty-warning, media-jam-warning等
                    }
                }
            }

            return mapOf(
                "state" to translateState(state),
                "reasons" to translateReasons(reasons)
            )
        }
    }

    /**
     * 原生 IPP 队列深度获取：获取当前 pending / processing 状态的任务深度
     */
    private fun fetchJobDepthStatus(ip: String, port: String, queue: String): Map<String, String> {
        val printerUrl = "http://$ip:$port/printers/$queue"
        
        // 组装标准 IPP Get-Jobs 请求报文获取当前活跃任务
        val packet = IppPacket.builder(Operation.getJobs)
            .put(BinaryGroup.operationAttributes, Types.attributesCharset, "utf-8")
            .put(BinaryGroup.operationAttributes, Types.attributesNaturalLanguage, "en-us")
            .put(BinaryGroup.operationAttributes, Types.printerUri, URI.create(printerUrl))
            .put(BinaryGroup.operationAttributes, Types.whichJobs, "not-completed") // 只获取未完成的排队任务
            .build()

        val ippBytes = packet.write()

        val client = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .build()

        val mediaType = "application/ipp".toMediaType()
        val requestBody = ippBytes.toRequestBody(mediaType)
        val request = Request.Builder().url(printerUrl).post(requestBody).build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw Exception("HTTP ${response.code}: ${response.message}")
            }
            val responseBytes = response.body?.bytes() ?: throw Exception("返回为空")
            val responsePacket = IppPacket.read(responseBytes)

            var pendingJobsCount = 0
            var processingJobName = "无活跃任务"

            // 遍历属性组，计算排队中的 Job 数量并提取当前正在执行的任务名
            for (group in responsePacket.attributeGroups) {
                if (group.tag == BinaryGroup.jobAttributes) {
                    val jobStateAttr = group[Types.jobState]
                    val jobNameAttr = group[Types.jobName]
                    if (jobStateAttr != null && jobStateAttr.isNotEmpty()) {
                        val state = jobStateAttr.first().toString()
                        if (state == "processing" || state == "3") { // 3 代表 pending-held, 5 代表 processing
                            processingJobName = jobNameAttr?.first()?.toString() ?: "未知文档"
                        }
                        pendingJobsCount++
                    }
                }
            }

            return mapOf(
                "depth" to pendingJobsCount.toString(),
                "activeJob" to processingJobName
            )
        }
    }

    private fun translateState(state: String): String {
        return when (state) {
            "idle", "3" -> "🟢 空闲就绪"
            "processing", "4" -> "🔵 正在打印中..."
            "stopped", "5" -> "🔴 设备故障停止"
            else -> "⚪ 状态未知 ($state)"
        }
    }

    private fun translateReasons(reasons: String): String {
        if (reasons == "none" || reasons.isEmpty()) return "设备健康无异常"
        
        val list = reasons.split(",")
        val translated = mutableListOf<String>()
        for (r in list) {
            when {
                r.contains("media-empty") -> translated.add("⚠️ 打印纸已耗尽")
                r.contains("media-jam") -> translated.add("⚠️ 打印机卡纸")
                r.contains("marker-supply-empty") -> translated.add("⚠️ 碳粉/墨水已耗尽")
                r.contains("marker-supply-low") -> translated.add("💡 墨水/碳粉即将耗尽警告")
                r.contains("cover-open") -> translated.add("⚠️ 打印机前盖或舱门未关好")
                r.contains("offline") -> translated.add("⚠️ 打印机脱机或未连接")
                else -> translated.add(r)
            }
        }
        return translated.joinToString(" | ")
    }

    private fun executeIppPrint(pdfFile: File, printerUrl: String, copiesNum: Int, duplex: Boolean): PrintResult {
        return try {
            val packetBuilder = IppPacket.builder(Operation.printJob)
                .put(BinaryGroup.operationAttributes, Types.attributesCharset, "utf-8")
                .put(BinaryGroup.operationAttributes, Types.attributesNaturalLanguage, "en-us")
                .put(BinaryGroup.operationAttributes, Types.printerUri, URI.create(printerUrl))
                .put(BinaryGroup.operationAttributes, Types.jobName, pdfFile.name)
                .put(BinaryGroup.jobAttributes, Types.copies, copiesNum)
            
            if (duplex) {
                packetBuilder.put(BinaryGroup.jobAttributes, Types.sides, "two-sided-long-edge")
            } else {
                packetBuilder.put(BinaryGroup.jobAttributes, Types.sides, "one-sided")
            }

            val ippHeaderBytes = packetBuilder.build().write()

            val pdfBytes = pdfFile.readBytes()
            val payload = ByteArray(ippHeaderBytes.size + pdfBytes.size)
            System.arraycopy(ippHeaderBytes, 0, payload, 0, ippHeaderBytes.size)
            System.arraycopy(pdfBytes, 0, payload, ippHeaderBytes.size, pdfBytes.size)

            val client = OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .writeTimeout(60, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .build()

            val mediaType = "application/ipp".toMediaType()
            val requestBody = payload.toRequestBody(mediaType)
            val request = Request.Builder()
                .url(printerUrl)
                .post(requestBody)
                .build()

            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    PrintResult(true)
                } else {
                    PrintResult(false, "HTTP ${response.code}: ${response.message}")
                }
            }
        } catch (e: Exception) {
            PrintResult(false, e.localizedMessage ?: "未知网络/协议错误")
        }
    }

    private fun fetchCupsPrinters(ip: String, port: String): List<String> {
        val serverUrl = "http://$ip:$port/"
        
        val packet = IppPacket.builder(Operation.getPrinters)
            .put(BinaryGroup.operationAttributes, Types.attributesCharset, "utf-8")
            .put(BinaryGroup.operationAttributes, Types.attributesNaturalLanguage, "en-us")
            .put(BinaryGroup.operationAttributes, Types.printerUri, URI.create(serverUrl))
            .build()

        val ippBytes = packet.write()

        val client = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()

        val mediaType = "application/ipp".toMediaType()
        val requestBody = ippBytes.toRequestBody(mediaType)
        val request = Request.Builder()
            .url(serverUrl)
            .post(requestBody)
            .build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw Exception("HTTP ${response.code}: ${response.message}")
            }
            val responseBytes = response.body?.bytes() ?: throw Exception("响应正文为空")
            
            val responsePacket = IppPacket.read(responseBytes)
            val printers = mutableListOf<String>()
            
            for (group in responsePacket.attributeGroups) {
                if (group.tag == BinaryGroup.printerAttributes) {
                    val nameAttr = group[Types.printerName]
                    if (nameAttr != null && nameAttr.isNotEmpty()) {
                        printers.add(nameAttr.first().toString())
                    }
                }
            }
            return printers
        }
    }

    /**
     * 利用系统原生 PdfRenderer 解析源文件指定页码，并绘制到新生成的 PdfDocument 中导出，
     * 以实现 PDF 文档指定页码裁剪过滤输出。
     */
    private fun cropPdf(source: File, dest: File, pages: List<Int>): Boolean {
        return try {
            val fileDescriptor = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = android.graphics.pdf.PdfRenderer(fileDescriptor)
            val pdfDoc = android.graphics.pdf.PdfDocument()

            for (pageIndex in pages) {
                val zeroIndex = pageIndex - 1 // Flutter 传入的是以 1 开始的页码
                if (zeroIndex in 0 until renderer.pageCount) {
                    val page = renderer.openPage(zeroIndex)
                    // 创建等比例的 PdfPage
                    val pageInfo = android.graphics.pdf.PdfDocument.PageInfo.Builder(page.width, page.height, pageIndex).create()
                    val docPage = pdfDoc.startPage(pageInfo)
                    
                    // 矢量级重画 Canvas 图像
                    page.render(docPage.canvas, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                    pdfDoc.finishPage(docPage)
                    page.close()
                }
            }
            
            dest.outputStream().use { out ->
                pdfDoc.writeTo(out)
            }
            pdfDoc.close()
            renderer.close()
            fileDescriptor.close()
            true
        } catch (e: Exception) {
            Log.e("CropPdf", "本地高保真 PDF 页码裁剪异常: ${e.message}")
            false
        }
    }
}
