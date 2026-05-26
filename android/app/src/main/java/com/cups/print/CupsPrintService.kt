package com.cups.print

import android.content.Context
import android.print.PrintAttributes
import android.print.PrinterCapabilitiesInfo
import android.print.PrinterId
import android.print.PrinterInfo
import android.print.PageRange
import android.printservice.PrintJob
import android.printservice.PrintService
import android.printservice.PrinterDiscoverySession
import android.util.Log
import com.hp.jipp.encoding.IppPacket
import com.hp.jipp.model.BinaryGroup
import com.hp.jipp.model.Operation
import com.hp.jipp.model.Types
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URI
import java.util.concurrent.TimeUnit

class CupsPrintService : PrintService() {

    private val TAG = "CupsPrintService"

    override fun onCreatePrinterDiscoverySession(): PrinterDiscoverySession {
        Log.d(TAG, "onCreatePrinterDiscoverySession被调用，创建自定义会话")
        return CupsPrinterDiscoverySession(this)
    }

    override fun onPrintJobQueued(printJob: PrintJob) {
        Log.d(TAG, "监听到来自系统（如WPS）分发的打印任务: ${printJob.info.label}")
        
        // 1. 标记任务状态为“正在打印”
        printJob.start()

        // 2. 异步启动协程，在后台 IO 线程中处理数据并上传，避免阻塞系统打印服务主进程
        CoroutineScope(Dispatchers.IO).launch {
            try {
                // 读取持久化保存的 CUPS 打印机配置
                val prefs = getSharedPreferences("cups_print_prefs", Context.MODE_PRIVATE)
                val ip = prefs.getString("ip", "192.168.2.11") ?: "192.168.2.11"
                val port = prefs.getString("port", "631") ?: "631"
                val queue = prefs.getString("queue", "HP105W") ?: "HP105W"

                // 3. 动态拦截用户在 WPS 打印预览界面设置的“打印参数”
                val copies = printJob.info.copies // 获取打印份数
                val duplexMode = printJob.info.attributes.duplexMode
                val isDuplex = (duplexMode == PrintAttributes.DUPLEX_MODE_LONG_EDGE || 
                                duplexMode == PrintAttributes.DUPLEX_MODE_SHORT_EDGE)

                Log.d(TAG, "拦截到打印参数 -> 份数: $copies, 是否双面: $isDuplex")

                // 4. 提取 WPS 在手机本地高保真渲染好的 PDF 二进制流
                val inputStream: InputStream = printJob.document.data ?: throw Exception("WPS排版渲染流为空")
                val pdfBytes = readInputStreamToByteArray(inputStream)

                // 5. 执行 IPP 字节流的打包与上传
                val printerUrl = "http://$ip:$port/printers/$queue"
                val printSuccess = executeIppStreamPrint(pdfBytes, printJob.info.label ?: "wps_job.pdf", printerUrl, copies, isDuplex)

                if (printSuccess) {
                    Log.d(TAG, "系统打印任务顺利完成，出纸中")
                    // 6. 标记任务成功，系统会提示用户打印完毕
                    printJob.complete()
                } else {
                    throw Exception("CUPS 服务器响应失败")
                }
            } catch (e: Exception) {
                Log.e(TAG, "打印任务提交失败: ${e.message}")
                // 7. 标记任务失败并提供详细报错原因，用户在手机通知栏能清晰看到失败提示
                printJob.fail("打印失败: ${e.localizedMessage}")
            }
        }
    }

    override fun onRequestCancelPrintJob(printJob: PrintJob) {
        Log.d(TAG, "用户取消了打印任务")
        printJob.cancel()
    }

    /**
     * 将输入流转换为 ByteArray
     */
    private fun readInputStreamToByteArray(inputStream: InputStream): ByteArray {
        val buffer = ByteArray(4 * 1024)
        val outputStream = ByteArrayOutputStream()
        var read: Int
        inputStream.use { input ->
            while (input.read(buffer).also { read = it } != -1) {
                outputStream.write(buffer, 0, read)
            }
        }
        return outputStream.toByteArray()
    }

    /**
     * 核心传输：拼装 JIPP 包并利用 OkHttp 递送
     */
    private fun executeIppStreamPrint(pdfBytes: ByteArray, jobName: String, printerUrl: String, copiesNum: Int, duplex: Boolean): Boolean {
        return try {
            // A. 构建 RFC 规范标准的 IPP 二进制控制头
            val packetBuilder = IppPacket.builder(Operation.printJob)
                .put(BinaryGroup.operationAttributes, Types.attributesCharset, "utf-8")
                .put(BinaryGroup.operationAttributes, Types.attributesNaturalLanguage, "en-us")
                .put(BinaryGroup.operationAttributes, Types.printerUri, URI.create(printerUrl))
                .put(BinaryGroup.operationAttributes, Types.jobName, jobName)
                .put(BinaryGroup.jobAttributes, Types.copies, copiesNum)
            
            if (duplex) {
                packetBuilder.put(BinaryGroup.jobAttributes, Types.sides, "two-sided-long-edge")
            } else {
                packetBuilder.put(BinaryGroup.jobAttributes, Types.sides, "one-sided")
            }

            val ippHeaderBytes = packetBuilder.build().write()

            // B. 合并控制头和 WPS 渲染的高清 PDF 数据体
            val payload = ByteArray(ippHeaderBytes.size + pdfBytes.size)
            System.arraycopy(ippHeaderBytes, 0, payload, 0, ippHeaderBytes.size)
            System.arraycopy(pdfBytes, 0, payload, ippHeaderBytes.size, pdfBytes.size)

            // C. OkHttp 高防灾网络传输
            val client = OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .writeTimeout(90, TimeUnit.SECONDS) // 系统打印可能有大文档，写入超时延长至 90 秒
                .readTimeout(30, TimeUnit.SECONDS)
                .build()

            val mediaType = "application/ipp".toMediaType()
            val requestBody = payload.toRequestBody(mediaType)
            val request = Request.Builder()
                .url(printerUrl)
                .post(requestBody)
                .build()

            client.newCall(request).execute().use { response ->
                response.isSuccessful
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 自定义打印机发现会话类，用于控制向 Android 系统注册与上报可用的单播打印机实例。
     */
    private class CupsPrinterDiscoverySession(private val service: PrintService) : PrinterDiscoverySession() {

        private val TAG_SESSION = "CupsPrinterDiscoverySession"

        override fun onStartPrinterDiscovery(priorityList: List<PrinterId>) {
            Log.d(TAG_SESSION, "发现会话启动 -> 绕过局域网 mDNS 多播组播扫描限制！")

            // 1. 直接从共享沙盒 SharedPreferences 中读取用户之前保存的持久化单播打印机
            val prefs = service.getSharedPreferences("cups_print_prefs", Context.MODE_PRIVATE)
            val ip = prefs.getString("ip", null)
            val port = prefs.getString("port", "631")
            val queue = prefs.getString("queue", null)

            if (ip != null && queue != null) {
                Log.d(TAG_SESSION, "成功读取到持久化单播打印机配置: $queue @ $ip")

                // 2. 为打印机生成唯一 ID
                val printerId = service.generatePrinterId(queue)

                // 3. 构造虚拟打印机信息（STATUS_IDLE 标记为活跃就绪状态）
                val builder = PrinterInfo.Builder(printerId, "CupsPrint: $queue", PrinterInfo.STATUS_IDLE)
                    
                // 4. 声明该打印机具备的打印能力（纸张尺寸、单双面等），告知 WPS 以便其按此规范排版
                val capBuilder = PrinterCapabilitiesInfo.Builder(printerId)
                    .addMediaSize(PrintAttributes.MediaSize.ISO_A4, true) // 默认 A4
                    .addResolution(PrintAttributes.Resolution("200", "200dpi", 200, 200), true)
                    .setColorModes(PrintAttributes.COLOR_MODE_COLOR or PrintAttributes.COLOR_MODE_MONOCHROME, PrintAttributes.COLOR_MODE_COLOR)
                    .setDuplexModes(PrintAttributes.DUPLEX_MODE_NONE or PrintAttributes.DUPLEX_MODE_LONG_EDGE, PrintAttributes.DUPLEX_MODE_NONE)

                builder.setCapabilities(capBuilder.build())
                builder.setDescription("手动/单播绑定: $ip:$port")

                // 5. 强制上报给系统！
                val printers = ArrayList<PrinterInfo>()
                printers.add(builder.build())
                addPrinters(printers)

                Log.d(TAG_SESSION, "已将持久化单播打印机上报系统打印列表！")
            } else {
                Log.w(TAG_SESSION, "本地暂无持久化配置，请先在 App 内绑定一台打印机！")
            }
        }

        override fun onStopPrinterDiscovery() {
            Log.d(TAG_SESSION, "发现会话停止")
        }

        override fun onValidatePrinters(printerIds: List<PrinterId>) {
            Log.d(TAG_SESSION, "校验打印机状态")
        }

        override fun onStartPrinterStateTracking(printerId: PrinterId) {
            Log.d(TAG_SESSION, "开始追踪打印机状态")
        }

        override fun onStopPrinterStateTracking(printerId: PrinterId) {
            Log.d(TAG_SESSION, "停止追踪打印机状态")
        }

        override fun onDestroy() {
            Log.d(TAG_SESSION, "会话销毁")
        }
    }
}
