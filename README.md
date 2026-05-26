# CupsPrintClient
> 基于 Android + Flutter 跨平台架构的 CUPS 移动端打印客户端。实现移动设备与局域网或广域网 CUPS 打印服务器的对接，支持文档预览、本地格式转码、打印机状态追踪以及系统级打印服务集成。

---

## ⚙️ 核心功能与技术设计

### 1. 网络打印协议 (IPP 协议)
- **协议实现**：利用 `com.hp.jipp:jipp-core` 库，在客户端构建符合 RFC 2911 / RFC 8011 标准的 IPP (Internet Printing Protocol) 二进制报文。支持配置打印份数、单双面打印（长边翻页/单面）等参数属性。
- **传输控制**：基于 OkHttp 网络库，配置连接与写入超时（最大 60 秒），支持大容量 PDF 文件流的安全递送，降低弱网环境下的传输失败率。

### 2. 智能打印机发现与添加机制 (混合模式)
- **mDNS 自动探测**：基于 Android 原生的网络服务发现 (NSD, `NsdManager`) 机制，监听局域网内活跃的 `_ipp._tcp` / `_ipps._tcp` 服务广播，解析 IP、端口及队列名，推送到 UI 端实现一键绑定。
- **HTTP/IPP 单播主动拉取**：针对 SD-WAN、跨网段 VPN 等无法穿透多播组播的复杂网络环境，提供单播 IP 查询接口。客户端直接向指定 IP 服务端发送 `Get-Printers` IPP 请求，从响应报文中提取可用的打印机 Queue 列表，实现跨网段的手动精确绑定。

### 3. 多格式文档 100% 本地离线转码
本系统不依赖任何外部转码云服务，文档转换完全在安卓本地运行，确保数据隐私：
- **图片转码**：基于纯 Dart 的 `pdf` 库，在本地将 `PNG` / `JPG` / `JPEG` 图片按照 A4 比例等比缩放，无损绘制于 PDF 虚拟页面上并导出。
- **Office 文档转码 (App 内部转换)**：当用户在 App 内部打开 `.docx` 或 `.xlsx` 文件时，系统在后台启动不可见的 `WebView` 加载本地 HTML5 模板，利用离线 JS 引擎完成排版，然后通过系统的 `PrintDocumentAdapter` 将网页内容静默导出为 PDF 缓存文件，供预览和打印。
- **系统打印服务桥接 (跨应用协同转码)**：注册为标准的 Android `PrintService` (系统级虚拟打印机)。当用户在 **WPS Office** 等专业办公软件中点击“系统打印”并选择 **CupsPrint** 时，WPS 会在本地将文档高保真地渲染为 PDF 数据流分发给本服务，本服务在后台拦截字节流并直接提交给 CUPS。

### 4. 高保真在屏预览与矢量级裁剪
- **高清预览**：集成了 `pdfx` 渲染器，支持 PDF 逐页高清滑屏预览和双指手势缩放。
- **矢量级物理裁剪**：在预览界面支持用户自由勾选需要打印的页码（或一键奇偶过滤）。提交时，Android 原生端利用 `PdfRenderer` 和 `PdfDocument` 对原始 PDF 页面在 Canvas 层执行重画，矢量级无损输出过滤后的 PDF 临时文件发送给服务端，实现精确的指定页码打印。

### 5. 打印设备与排队进度实时监视器
- **设备状态监视**：每隔 4 秒向 CUPS 服务端发送单播的 `Get-Printer-Attributes` 报文，提取 `printer-state` 与 `printer-state-reasons` 诊断属性，实时追踪打印机空闲、打印中、脱机，以及卡纸、缺纸、缺墨、盖门未关等硬件异常。
- **队列进度监视**：发送 `Get-Jobs` 请求获取排队中的未完成任务，实时展示队列等待任务深度以及当前正在打印的文档名称。

---

## 🏗️ 项目技术栈

- **UI 框架**：Flutter 3.19.x (使用 Material 3 风格设计)
- **开发语言**：Kotlin 1.9.0 (Android 原生宿主与服务) + Dart (UI 与交互)
- **网络传输与协议**：[HP JIPP](https://github.com/hpimaging/jipp) (IPP 标准解析) + OkHttp 4.12.0
- **PDF 渲染与处理**：[pdfx](https://pub.dev/packages/pdfx) + Android 原生 `PdfRenderer`
- **构建工具**：Gradle 8.1.4 (JDK 17)

---

## 🚀 GitHub Actions 自动编译与部署说明

本项目已完美集成 GitHub Actions 持续集成工作流。

### 云端编译及下载流程：
1. **推送代码**：将本项目推送到您个人的 GitHub 仓库中。
2. **下载依赖并编译**：工作流（`Build Android APK`）在被触发后，会自动配置 JDK 17 及 Flutter 3.19.x 编译环境。
3. **拉取 Office 离线解析引擎**：工作流在编译前会自动通过 `curl` 从官方 CDN 节点获取 `docx-preview.min.js` 与 `xlsx.full.min.js` 写入 assets 目录，打包进入 APK，免去了用户在本地寻找和下载 JS 资源的麻烦。
4. **归档产物**：构建成功后，将在详情页的 **Artifacts** 区域输出最新的调试版安装包 **`CupsPrintClient-Debug-APK`** 供一键下载。

---

## 🔧 服务端部署建议 (CUPS 配置参考)

以树莓派/Linux 为例，您需要确保 CUPS 允许单播通信，以便跨网段手动拉取功能正常工作：

### 1. 修改 CUPS 配置文件：
```bash
sudo nano /etc/cups/cupsd.conf
```
确保配置中包含以下允许单播访问的声明：
```text
# 监听 631 端口
Port 631

# 允许外部局域网网段访问
<Location />
  Order allow,deny
  Allow @LOCAL
</Location>

# 允许外部网段管理打印机
<Location /admin>
  Order allow,deny
  Allow @LOCAL
</Location>
```

### 2. 重启服务：
```bash
sudo systemctl restart cups
```
在网页管理端 `http://<IP>:631` 添加您的打印机，并记下队列名称（Queue Name），即可开始测试。
