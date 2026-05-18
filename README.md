# Luban Imager / 鲁班压图

Luban Imager 是一个基于 Flutter 的移动端图片压缩 App，目标是把优秀的 Luban 图片压缩能力包装成一个简单、直接、适合日常使用的小工具。

## 致谢

首先感谢上游 [Curzibn/Luban](https://github.com/Curzibn/Luban) 项目。Luban 提供了接近微信朋友圈压缩策略的 Android 图片压缩能力，本项目的 Android 端基于 `top.zibin:luban:2.0.1` 工作，并在此基础上补充了 Flutter 界面、系统图片选择/分享、压缩结果预览、覆盖原图等 App 侧能力。

本项目不是 Luban 官方 App。如果你需要压缩算法本身、Android 库接入方式或上游实现细节，请优先参考 Luban 原仓库。

## 主要功能

- 智能压缩：选择图片后自动执行 Luban 风格压缩，不需要手动填写质量、尺寸等参数。
- 多入口导入：支持从 App 内选择图片，也支持从系统分享菜单接收图片。
- 压缩结果预览：展示原图、压缩图、前后对比三种视图，并显示尺寸、文件大小和节省比例。
- 安全回退：如果压缩结果比原图更大，会自动使用原图，避免负优化。
- 分享导出：压缩完成后可通过系统分享面板导出压缩图片。
- 原位覆盖：对于系统授权可写入的图片来源，支持覆盖原图；覆盖前会进行两次确认。

## 平台支持

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| Android | 已支持 | 使用上游 Luban Android 库执行压缩，并已接入选择、分享、覆盖等能力。 |
| iOS | 理论支持，未实机测试 | iOS 端包含基于 ImageIO/UIKit 的 Luban 风格压缩实现，但作者目前没有 iPhone 设备，因此还没有经过真实设备验证。 |

## 技术实现

- UI 使用 Flutter / Material 3。
- Android 通过 `MethodChannel` 调用原生 Kotlin 代码，并使用 `top.zibin:luban:2.0.1` 压缩图片。
- iOS 通过 `MethodChannel` 调用 Swift 代码，使用 ImageIO/UIKit 读取、缩放和编码图片。
- 图片选择、分享和覆盖均尽量走系统能力，压缩过程在本地完成。

## 开发环境

建议使用 Flutter stable 版本。当前项目由 Flutter 模板生成，`pubspec.yaml` 中 Dart SDK 约束为：

```sh
sdk: ^3.11.5
```

准备依赖：

```sh
flutter pub get
```

运行测试：

```sh
flutter test
```

本地运行：

```sh
flutter run
```

## 编译

### Android

调试安装包：

```sh
flutter build apk --debug
```

发布安装包：

```sh
flutter build apk --release
```

按 CPU 架构拆分发布安装包：

```sh
flutter build apk --release --split-per-abi
```

发布 AAB：

```sh
flutter build appbundle --release
```

发布前建议修改 `android/app/build.gradle.kts` 中的 `applicationId`，并配置自己的 release 签名。当前工程为了方便本地运行，release 构建仍使用 debug signing config。

### iOS

iOS 构建需要 macOS、Xcode 和有效签名配置：

```sh
flutter build ios --release
```

注意：iOS 端目前只是理论支持，代码路径已经实现，但尚未在真实 iPhone 设备上验证。

## License

本项目采用 Apache-2.0 License，见 [LICENSE](./LICENSE)。

上游 Luban 项目同样采用 Apache-2.0 License。Android 端依赖 Luban 时，请保留并遵守上游项目许可证要求。
