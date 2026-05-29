import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:pdfx/pdfx.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const CupsPrintApp());
}

class CupsPrintApp extends StatelessWidget {
  const CupsPrintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CupsPrint',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const MainConsolePage(),
    );
  }
}

class MainConsolePage extends StatefulWidget {
  const MainConsolePage({super.key});

  @override
  State<MainConsolePage> createState() => _MainConsolePageState();
}

class _MainConsolePageState extends State<MainConsolePage> {
  // MethodChannel 原生双向通讯接口
  static const platform = MethodChannel('com.cups.print/ipp');

  // 配置持久化 key
  final String _keyIp = 'cups_ip';
  final String _keyPort = 'cups_port';
  final String _keyQueue = 'cups_queue';

  // 双向绑定输入控制器
  final TextEditingController _ipController = TextEditingController(text: '192.168.2.11');
  final TextEditingController _portController = TextEditingController(text: '631');
  final TextEditingController _queueController = TextEditingController(text: 'HP105W');

  int _copies = 1;
  bool _isDuplex = false;
  bool _isSubmitting = false;

  // 接收到的分享文件状态
  File? _pdfFile;
  String? _pdfName;
  String? _pdfSize;
  PdfController? _pdfController;

  // 动态解析的 PDF 页码裁剪控制状态
  int _totalPagesCount = 0;
  List<int> _selectedPages = []; // 存储勾选的页码 (1-based)

  // 跨网段服务器拉取的可用打印机列表（用于 SD-WAN 环境）
  List<String> _serverPrinters = [];
  bool _isFetchingPrinters = false;

  // 局域网 mDNS 自动发现的打印机列表状态
  List<Map<String, String>> _discoveredPrinters = [];

  // 实时监控打印设备硬件状态与排队进度
  String _printerState = '正在建立设备监视器连接...';
  String _printerReasons = '未检测到硬件异常';
  String _queueDepth = '0';
  String _activeJobName = '无活跃任务';
  Timer? _statusTimer;

  // 微信分享文件流监听订阅
  late StreamSubscription _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    _loadSavedPreferences();
    _initSharingIntent();
    _initNsdDiscovery(); // 初始化并启动局域网 mDNS 自动搜寻
    _startStatusMonitoring(); // 启动 IPP 硬件状态与排队定时侦听轮询
    _autoFetchIfCrossNetwork(); // 异地组网场景：mDNS 无结果时自动单播拉取
  }

  @override
  void dispose() {
    _intentDataStreamSubscription.cancel();
    _statusTimer?.cancel();
    _ipController.dispose();
    _portController.dispose();
    _queueController.dispose();
    _pdfController?.dispose();
    _stopNsdDiscovery(); // 优雅注销局域网自动探测
    super.dispose();
  }

  // 加载持久化配置
  Future<void> _loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString(_keyIp) ?? '192.168.2.11';
      _portController.text = prefs.getString(_keyPort) ?? '631';
      _queueController.text = prefs.getString(_keyQueue) ?? 'HP105W';
    });
  }

  // 保存持久化配置
  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyIp, _ipController.text);
    await prefs.setString(_keyPort, _portController.text);
    await prefs.setString(_keyQueue, _queueController.text);
  }

  // 判断文件是否是本App可接受的一键拉起类型 (PDF、常见图片、以及 Office 格式)
  bool _isAcceptableFile(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.pdf') || p.endsWith('.png') || p.endsWith('.jpg') || p.endsWith('.jpeg') ||
           p.endsWith('.docx') || p.endsWith('.xlsx') || p.endsWith('.xls');
  }

  // 分发处理分享进来的文件
  void _handleSharedFile(String filePath) {
    final p = filePath.toLowerCase();
    if (p.endsWith('.pdf')) {
      _loadPdfFile(filePath);
    } else if (p.endsWith('.png') || p.endsWith('.jpg') || p.endsWith('.jpeg')) {
      _convertImageToPdfAndLoad(filePath);
    } else if (p.endsWith('.docx') || p.endsWith('.xlsx') || p.endsWith('.xls')) {
      _convertOfficeToPdfAndLoad(filePath);
    }
  }

  // 初始化微信/QQ分享监听机制
  void _initSharingIntent() {
    // 1. 用于应用在后台运行被唤醒时的分享事件监听
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      if (value.isNotEmpty && _isAcceptableFile(value.first.path)) {
        _handleSharedFile(value.first.path);
      }
    }, onError: (err) {
      _showToast('分享接收异常: $err');
    });

    // 2. 用于应用进程彻底关闭时，被分享拉起那一刻的冷启动文件捕获
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty && _isAcceptableFile(value.first.path)) {
        _handleSharedFile(value.first.path);
      }
      ReceiveSharingIntent.instance.reset();
    });
  }

  // 开启 mDNS 局域网服务发现，并注册原生反向推流回调
  Future<void> _initNsdDiscovery() async {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onPrinterDiscovered') {
        final Map<dynamic, dynamic>? args = call.arguments;
        if (args != null) {
          final String name = args['name'] ?? '';
          final String ip = args['ip'] ?? '';
          final String port = args['port'] ?? '631';

          if (name.isNotEmpty && ip.isNotEmpty) {
            // 过滤重复发现的打印机
            final isDuplicate = _discoveredPrinters.any((p) => p['ip'] == ip && p['name'] == name);
            if (!isDuplicate) {
              setState(() {
                _discoveredPrinters.add({
                  'name': name,
                  'ip': ip,
                  'port': port,
                });
              });
            }
          }
        }
      }
    });

    try {
      await platform.invokeMethod('startNsdDiscovery');
    } catch (e) {
      debugPrint('启动局域网自动发现异常: $e');
    }
  }

  // 注销局域网服务发现
  Future<void> _stopNsdDiscovery() async {
    try {
      await platform.invokeMethod('stopNsdDiscovery');
    } catch (_) {}
  }

  // mDNS 发现延迟等待后自动触发单播拉取（解决异地组网 mDNS 不可达场景）
  Future<void> _autoFetchIfCrossNetwork() async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    if (_discoveredPrinters.isNotEmpty) return; // mDNS 已有结果，走局域网
    final ip = _ipController.text.trim();
    if (ip.isEmpty || ip == '192.168.2.11') return; // 未配置有效 IP
    // 静默拉取，只显示成功结果，不弹错误提示
    try {
      final List<dynamic>? printers = await platform.invokeMethod('fetchCupsPrinters', {
        'ip': ip,
        'port': _portController.text.trim(),
      });
      if (mounted && printers != null && printers.isNotEmpty) {
        setState(() {
          _serverPrinters = printers.cast<String>();
        });
      }
    } catch (_) {}
  }

  // 将图片在本地转换为 PDF 格式并加载至预览区
  Future<void> _convertImageToPdfAndLoad(String imagePath) async {
    setState(() {
      _isSubmitting = true;
    });
    _showToast('正在将图片转换为 PDF...');

    try {
      final imageFile = File(imagePath);
      if (!await imageFile.exists()) {
        throw Exception("图片物理文件不存在");
      }

      final imageBytes = await imageFile.readAsBytes();

      // 使用 pdf 库在本地绘制 A4 页面
      final pdf = pw.Document();
      final image = pw.MemoryImage(imageBytes);

      pdf.addPage(
        pw.Page(
          pageFormat: pw_pdf.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18), // 设定页面边距
          build: (pw.Context context) {
            return pw.Center(
              child: pw.Image(
                image,
                fit: pw.BoxFit.contain, // 等比例缩放，保证不变形
              ),
            );
          },
        ),
      );

      final tempDir = await getTemporaryDirectory();
      final outputName = '[已转码]_${imagePath.split('/').last.split('.').first}.pdf';
      final outputFile = File('${tempDir.path}/$outputName');

      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      await outputFile.writeAsBytes(await pdf.save());

      setState(() {
        _isSubmitting = false;
      });

      await _loadPdfFile(outputFile.path);
    } catch (e) {
      setState(() {
        _isSubmitting = false;
      });
      _showToast('图片转换失败: $e');
    }
  }

  // 调用原生 WebView 静默打印机制进行 Word/Excel 到 PDF 的本地转换
  Future<void> _convertOfficeToPdfAndLoad(String filePath) async {
    setState(() {
      _isSubmitting = true;
    });
    _showToast('正在进行本地 Word/Excel 转换...');

    try {
      final String? convertedPdfPath = await platform.invokeMethod('convertOfficeToPdf', {
        'filePath': filePath,
      });

      setState(() {
        _isSubmitting = false;
      });

      if (convertedPdfPath != null && convertedPdfPath.isNotEmpty) {
        await _loadPdfFile(convertedPdfPath);
      } else {
        _showToast('❌ 转换失败，请检查文档是否受损');
      }
    } catch (e) {
      setState(() {
        _isSubmitting = false;
      });
      _showToast('❌ 离线转码异常: $e');
    }
  }

  // 加载 PDF 并解析文件信息，用于预览与页码范围选择
  Future<void> _loadPdfFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final length = await file.length();
        final sizeMb = length / (1024 * 1024);
        final name = filePath.split('/').last;

        _pdfController?.dispose();
        final pdfController = PdfController(
          document: PdfDocument.openFile(filePath),
        );

        // 获取 PDF 的真实总页数并初始化页码勾选列表
        final document = await PdfDocument.openFile(filePath);
        final pagesCount = document.pagesCount;

        setState(() {
          _pdfFile = file;
          _pdfName = name;
          _pdfSize = '${sizeMb.toStringAsFixed(2)} MB';
          _pdfController = pdfController;
          _totalPagesCount = pagesCount;
          _selectedPages = List<int>.generate(pagesCount, (i) => i + 1); // 默认全选
        });
        _showToast('文档加载成功');
      }
    } catch (e) {
      _showToast('无法解析 PDF 文件: $e');
    }
  }

  // 定时轮询获取打印机硬件状态与队列任务
  void _startStatusMonitoring() {
    _statusTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      final ip = _ipController.text.trim();
      final port = _portController.text.trim();
      final queue = _queueController.text.trim();

      if (ip.isEmpty || queue.isEmpty) return;

      try {
        // A. 轮询获取打印机卡纸/缺纸/缺墨硬件状态
        final Map<dynamic, dynamic>? status = await platform.invokeMethod('fetchPrinterStatus', {
          'ip': ip,
          'port': port,
          'queue': queue,
        });
        
        // B. 轮询获取当前活跃任务与排队深度
        final Map<dynamic, dynamic>? jobStatus = await platform.invokeMethod('fetchJobStatus', {
          'ip': ip,
          'port': port,
          'queue': queue,
        });

        if (status != null && mounted) {
          setState(() {
            _printerState = status['state'] ?? '未知';
            _printerReasons = status['reasons'] ?? '无';
          });
        }

        if (jobStatus != null && mounted) {
          setState(() {
            _queueDepth = jobStatus['depth'] ?? '0';
            _activeJobName = jobStatus['activeJob'] ?? '无活跃任务';
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _printerState = '⚪ 离线 (连接失败)';
            _printerReasons = '请检查服务器网络或 CUPS 服务状态';
          });
        }
      }
    });
  }

  // 通过 HTTP / IPP 单播机制从服务器主动拉取打印机列表（解决 SD-WAN 无法使用 mDNS 组播的问题）
  Future<void> _fetchServerPrinters() async {
    if (_ipController.text.isEmpty || _portController.text.isEmpty) {
      _showToast('请先输入服务器 IP 与端口！');
      return;
    }

    setState(() {
      _isFetchingPrinters = true;
      _serverPrinters.clear();
    });

    try {
      final List<dynamic>? printers = await platform.invokeMethod('fetchCupsPrinters', {
        'ip': _ipController.text.trim(),
        'port': _portController.text.trim(),
      });

      setState(() {
        _isFetchingPrinters = false;
        if (printers != null && printers.isNotEmpty) {
          _serverPrinters = printers.cast<String>();
          _showToast('📡 成功拉取到 ${_serverPrinters.length} 台可用打印机');
        } else {
          _showToast('未拉取到打印机，请检查网络或服务端配置');
        }
      });
    } catch (e) {
      setState(() {
        _isFetchingPrinters = false;
      });
      _showToast('📡 列表拉取失败: ${e.toString()}');
    }
  }

  // 提交打印任务，支持按所选页码进行 PDF 页面裁剪
  Future<void> _submitPrintJob() async {
    if (_pdfFile == null) {
      _showToast('⚠️ 暂无任务。请先拉起 PDF 或转换 Office 文件！');
      return;
    }

    if (_selectedPages.isEmpty) {
      _showToast('⚠️ 请至少勾选一个需要打印的页码！');
      return;
    }

    await _savePreferences();

    setState(() {
      _isSubmitting = true;
    });

    try {
      // 将所选页码列表传递给原生端，由原生端执行 PDF 页面裁剪
      final bool success = await platform.invokeMethod('executeIppPrint', {
        'pdfPath': _pdfFile!.path,
        'ip': _ipController.text.trim(),
        'port': _portController.text.trim(),
        'queue': _queueController.text.trim(),
        'copies': _copies,
        'duplex': _isDuplex,
        'selectedPages': _selectedPages.length == _totalPagesCount ? null : _selectedPages, // 全选时无需裁剪
      });

      setState(() {
        _isSubmitting = false;
      });

      if (success) {
        _showSuccessDialog();
      } else {
        _showToast('❌ 提交失败，详情请看控制台日志或检查网络');
      }
    } on PlatformException catch (e) {
      setState(() {
        _isSubmitting = false;
      });
      _showToast('❌ 原生提交异常: ${e.message}');
    }
  }

  // 提示工具类
  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
        backgroundColor: const Color(0xFF2E2E3E),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedCornerShape(12),
      ),
    );
  }

  // 成功弹窗
  void _showSuccessDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2C),
        shape: RoundedCornerShape(20),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 28),
            SizedBox(width: 12),
            Text('任务提交成功', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'IPP 打印任务已成功提交至 CUPS 服务器。',
          style: TextStyle(color: Color(0xFFB3B3C3), height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好的', style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0A0A12), // 极深紫黑色
              Color(0xFF121226), // 深海藏青色
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 8),
                const Text(
                  'CupsPrint 云打印',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.5,
                    shadows: [
                      Shadow(color: Colors.cyan, offset: Offset(0, 0), blurRadius: 10),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Print Client',
                  style: TextStyle(fontSize: 12, color: Color(0x80FFFFFF), letterSpacing: 2),
                ),
                const SizedBox(height: 18),

                // 打印设备与队列状态监控面板
                _buildGlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.monitor_heart, color: Colors.cyanAccent, size: 18),
                              SizedBox(width: 8),
                              Text(
                                '设备状态监视器',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0x2600F2FE),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0x3300F2FE)),
                            ),
                            child: const Text('实时轮询中', style: TextStyle(color: Colors.cyanAccent, fontSize: 9)),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildStatusIndicator(
                              title: '打印机硬件状态',
                              value: _printerState,
                              subtitle: _printerReasons,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildStatusIndicator(
                              title: '树莓派排队任务',
                              value: '👥 待打印队列: $_queueDepth 页',
                              subtitle: '活跃中: $_activeJobName',
                            ),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 服务器连接配置面板
                _buildGlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.dns, color: Colors.cyan, size: 20),
                              SizedBox(width: 8),
                              Text(
                                '打印服务器配置',
                                style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ],
                          ),
                          _isFetchingPrinters
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyan),
                                )
                              : TextButton.icon(
                                  onPressed: _fetchServerPrinters,
                                  icon: const Icon(Icons.sync, size: 16, color: Colors.cyanAccent),
                                  label: const Text(
                                    '拉取列表',
                                    style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    minimumSize: Size.zero,
                                  ),
                                ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 显示 mDNS 自动发现的局域网打印机列表
                      if (_discoveredPrinters.isNotEmpty) ...[
                        const Text(
                          '自动发现局域网打印机 (点击可快速绑定):',
                          style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 46,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            itemCount: _discoveredPrinters.length,
                            itemBuilder: (context, index) {
                              final p = _discoveredPrinters[index];
                              return Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _ipController.text = p['ip']!;
                                      _portController.text = p['port']!;
                                      _queueController.text = p['name']!;
                                    });
                                    _showToast('已绑定局域网打印机: ${p['name']}');
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0x2600F2FE),
                                          Color(0x134FACFE),
                                        ],
                                      ),
                                      border: Border.all(color: const Color(0x6600F2FE), width: 1.2),
                                      borderRadius: BorderRadius.circular(14),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF00F2FE).withOpacity(0.1),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        )
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        const SpinKitDoubleBounce(color: Colors.cyanAccent, size: 14),
                                        const SizedBox(width: 8),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              p['name']!,
                                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                            Text(
                                              '${p['ip']}:${p['port']}',
                                              style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 9),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      _buildTextField(
                        controller: _ipController,
                        label: '树莓派 IP / 虚拟网段 IP (支持 SD-WAN)',
                        hint: '例如 192.168.2.11',
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 1,
                            child: _buildTextField(
                              controller: _portController,
                              label: '端口',
                              hint: '631',
                              keyboardType: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: _buildTextField(
                              controller: _queueController,
                              label: '打印机队列 (Queue)',
                              hint: 'HP105W',
                            ),
                          ),
                        ],
                      ),

                      if (_serverPrinters.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text(
                          '发现可用打印机 (点击快速绑定):',
                          style: TextStyle(color: Color(0xFF8C8CA3), fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 36,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            itemCount: _serverPrinters.length,
                            itemBuilder: (context, index) {
                              final name = _serverPrinters[index];
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _queueController.text = name;
                                    });
                                    _showToast('✅ 已绑定打印机队列: $name');
                                  },
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0x1AFFFFFF),
                                      border: Border.all(color: const Color(0x33FFFFFF), width: 1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.print_outlined, size: 14, color: Colors.cyan),
                                        const SizedBox(width: 6),
                                        Text(
                                          name,
                                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 待打印文档预览与页码选择面板
                _buildGlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.picture_as_pdf, color: Colors.greenAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            '待打印文档与页码选择',
                            style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (_pdfFile != null && _pdfController != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _pdfName ?? '未知文档',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text('大小: $_pdfSize | 共 $_totalPagesCount 页', style: const TextStyle(color: Color(0xFF8C8CA3), fontSize: 12)),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  _pdfFile = null;
                                  _pdfName = null;
                                  _pdfSize = null;
                                  _totalPagesCount = 0;
                                  _selectedPages.clear();
                                  _pdfController?.dispose();
                                  _pdfController = null;
                                });
                              },
                              icon: const Icon(Icons.close, color: Colors.redAccent),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          height: 260,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F0F1A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x1AFFFFFF)),
                          ),
                          child: PdfView(
                            controller: _pdfController!,
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Center(
                          child: Text(
                            '提示: 左右滑动可切换预览页面',
                            style: TextStyle(color: Color(0x66FFFFFF), fontSize: 11),
                          ),
                        ),

                        // 在屏 PDF 预览页码裁剪选择控制区
                        if (_totalPagesCount > 1) ...[
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                '选择打印页码范围:',
                                style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                              Row(
                                children: [
                                  _buildPageActionBtn(
                                    label: '全选',
                                    onTap: () {
                                      setState(() {
                                        _selectedPages = List<int>.generate(_totalPagesCount, (i) => i + 1);
                                      });
                                    },
                                  ),
                                  _buildPageActionBtn(
                                    label: '奇数页',
                                    onTap: () {
                                      setState(() {
                                        _selectedPages = List<int>.generate(_totalPagesCount, (i) => i + 1).where((p) => p % 2 != 0).toList();
                                      });
                                    },
                                  ),
                                  _buildPageActionBtn(
                                    label: '偶数页',
                                    onTap: () {
                                      setState(() {
                                        _selectedPages = List<int>.generate(_totalPagesCount, (i) => i + 1).where((p) => p % 2 == 0).toList();
                                      });
                                    },
                                  ),
                                ],
                              )
                            ],
                          ),
                          const SizedBox(height: 10),
                          // 横向滑动的多选按钮列表
                          SizedBox(
                            height: 38,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              physics: const BouncingScrollPhysics(),
                              itemCount: _totalPagesCount,
                              itemBuilder: (context, index) {
                                final pageNum = index + 1;
                                final isSelected = _selectedPages.contains(pageNum);
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: InkWell(
                                    onTap: () {
                                      setState(() {
                                        if (isSelected) {
                                          _selectedPages.remove(pageNum);
                                        } else {
                                          _selectedPages.add(pageNum);
                                          _selectedPages.sort();
                                        }
                                      });
                                    },
                                    borderRadius: BorderRadius.circular(10),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: isSelected ? const Color(0x3300F2FE) : const Color(0x0CFFFFFF),
                                        border: Border.all(
                                          color: isSelected ? Colors.cyan : const Color(0x1BFFFFFF),
                                          width: 1.2,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                                            size: 14,
                                            color: isSelected ? Colors.cyanAccent : Colors.grey,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '第 $pageNum 页',
                                            style: TextStyle(
                                              color: isSelected ? Colors.white : const Color(0x99FFFFFF),
                                              fontSize: 11,
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                            ),
                                          )
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          )
                        ]
                      ] else ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                          decoration: BoxDecoration(
                            color: const Color(0x0DFFFFFF),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x10FFFFFF)),
                          ),
                          child: const Column(
                            children: [
                              Icon(Icons.cloud_upload_outlined, color: Color(0xFFFFB300), size: 40),
                              SizedBox(height: 12),
                              Text(
                                '📥 暂无打印任务',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              SizedBox(height: 8),
                              Text(
                                '请在外部应用中分享 PDF/图片/Word/Excel 文件至「CupsPrint」，即可在此进行预览并提交打印。',
                                style: TextStyle(color: Color(0xFFFFB300), fontSize: 13, height: 1.5),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 打印参数配置面板
                _buildGlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune, color: Colors.purpleAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            '打印参数配置',
                            style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('打印份数', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                          Row(
                            children: [
                              _buildCounterButton(
                                icon: Icons.remove,
                                onTap: () {
                                  if (_copies > 1) {
                                    setState(() {
                                      _copies--;
                                    });
                                  }
                                },
                              ),
                              Container(
                                width: 40,
                                alignment: Alignment.center,
                                child: Text(
                                  '$_copies',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                              ),
                              _buildCounterButton(
                                icon: Icons.add,
                                onTap: () {
                                  setState(() {
                                    _copies++;
                                  });
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('双面打印 (长边翻页)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                          Switch(
                            value: _isDuplex,
                            activeColor: Colors.cyanAccent,
                            activeTrackColor: const Color(0x3300F2FE),
                            inactiveThumbColor: Colors.grey,
                            inactiveTrackColor: const Color(0x1AFFFFFF),
                            onChanged: (val) {
                              setState(() {
                                _isDuplex = val;
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                _isSubmitting
                    ? const Column(
                        children: [
                          SpinKitWave(color: Colors.cyan, size: 28),
                          SizedBox(height: 8),
                          Text('正在提交任务包...', style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.w600)),
                        ],
                      )
                    : InkWell(
                        onTap: _submitPrintJob,
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          width: double.infinity,
                          height: 56,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF00F2FE), // 青色
                                Color(0xFF4FACFE), // 蓝色
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF00F2FE).withOpacity(0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              )
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.print, color: Color(0xFF0A0A12), size: 20),
                              SizedBox(width: 10),
                              Text(
                                '提交至远程 CUPS 打印',
                                style: TextStyle(
                                  color: Color(0xFF0A0A12),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 统一的卡片底色装饰组件
  Widget _buildGlassCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0CFFFFFF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0x1BFFFFFF),
          width: 1,
        ),
      ),
      child: child,
    );
  }

  // 封装监视器状态提示卡片
  Widget _buildStatusIndicator({
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x15FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Color(0x80FFFFFF), fontSize: 10, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // 封装页码快捷按钮
  Widget _buildPageActionBtn({required String label, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          minimumSize: Size.zero,
          backgroundColor: const Color(0x15FFFFFF),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  // 封装输入框
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF8C8CA3), fontSize: 12),
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0x40FFFFFF), fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        filled: true,
        fillColor: const Color(0x08FFFFFF),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.cyan, width: 1.5),
        ),
      ),
    );
  }

  // 份数加减按钮
  Widget _buildCounterButton({required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x1AFFFFFF)),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}

class RoundedCornerShape extends RoundedRectangleBorder {
  RoundedCornerShape(double radius)
      : super(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
        );
}
