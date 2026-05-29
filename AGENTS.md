# AGENTS.md — CupsPrintClient

## 项目概要

Flutter 3.19 + Kotlin 1.9 的 CUPS 移动打印客户端。单一 Dart 入口 + 两个 Android 原生类。

## 目录结构

- `lib/main.dart` — 全部 Dart UI/逻辑（无路由、无状态管理库、无代码生成）
- `android/app/src/main/java/com/cups/print/MainActivity.kt` — MethodChannel 桥接、IPP 协议、mDNS 发现、WebView 转码、PDF 裁剪
- `android/app/src/main/java/com/cups/print/CupsPrintService.kt` — 系统级 PrintService（跨应用桥接）
- `android/app/src/main/assets/` — `word_converter.html` / `excel_converter.html` + 离线 JS 引擎

## 构建与运行

```bash
# JS 转码引擎不在仓库中，首次构建需手动下载：
curl -o android/app/src/main/assets/docx-preview.min.js https://unpkg.com/docx-preview@0.1.15/dist/docx-preview.min.js
curl -o android/app/src/main/assets/xlsx.full.min.js https://unpkg.com/xlsx@0.18.5/dist/xlsx.full.min.js

flutter pub get
flutter build apk --debug    # 仅调试版，release 未配置签名
```

仓库**不含** `gradlew`、`gradle-wrapper.jar`、`local.properties`。本地构建需先 `flutter create --platforms=android` 补齐或手动生成 Gradle wrapper。

## CI（`.github/workflows/build-apk.yml`）

- **触发条件**：仅推送 `v*` 标签
- 自动下载 JS 引擎、修复 Gradle wrapper、构建 debug APK
- 产物：`build/app/outputs/flutter-apk/app-debug.apk`
- 成功且带标签时自动创建 GitHub Release

## 关键架构细节

- **MethodChannel**: `com.cups.print/ipp`，方法列表：`executeIppPrint`, `fetchCupsPrinters`, `fetchPrinterStatus`, `fetchJobStatus`, `startNsdDiscovery`, `stopNsdDiscovery`, `convertOfficeToPdf`
- **NSD 发现**: 扫描 `_ipp._tcp` 服务，原生端通过 `LinkedBlockingQueue` 串行化 Resolve（防并发崩溃）
- **Office 转码**: WebView 不可见加载 HTML 模板 + JS 引擎，通过 `PrintDocumentAdapter.onLayout/onWrite` 静默导出 PDF
- **状态轮询**: Dart 端 `Timer.periodic(4s)` 轮流调用 `fetchPrinterStatus` 和 `fetchJobStatus`

## 无测试

`test/` 目录不存在，无任何测试文件或测试命令。

## 样式约定

- Material 3 暗色主题，`Brightness.dark` + `useMaterial3: true`
- 深色科幻风格 UI，全在 `main.dart` 内联定义，无独立 widget 文件
- Kotlin 使用 `kotlin.code.style=official`

## Android 配置

| 项目 | 值 |
|---|---|
| namespace | `com.cups.print` |
| minSdk | 26 |
| targetSdk / compileSdk | 34 |
| AGP | 8.1.4 |
| Kotlin | 1.9.22 |
| JDK | 17 |

依赖：OkHttp 4.12.0、jipp-core 0.7.15、core-ktx 1.12.0。
