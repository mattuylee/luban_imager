import Flutter
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var imageBridge: NativeImageBridge?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      let bridge = NativeImageBridge(controller: controller)
      imageBridge = bridge
      bridge.handleOpenURLContexts(connectionOptions.urlContexts, notifyFlutter: false)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    imageBridge?.handleOpenURLContexts(URLContexts, notifyFlutter: true)
  }
}

private final class NativeImageBridge: NSObject, UIDocumentPickerDelegate {
  private enum PendingOperation {
    case pick(FlutterResult)
  }

  private weak var controller: FlutterViewController?
  private var channel: FlutterMethodChannel?
  private var pendingOperation: PendingOperation?
  private var pendingShareResult: FlutterResult?
  private var pendingSharedImages: [[String: Any]] = []
  private var sources: [String: URL] = [:]

  init(controller: FlutterViewController) {
    self.controller = controller
    super.init()

    let channel = FlutterMethodChannel(
      name: "luban_imager/native_images",
      binaryMessenger: controller.binaryMessenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickImages":
      pickImages(result: result)
    case "takeSharedImages":
      takeSharedImages(result: result)
    case "compressImage":
      compressImage(arguments: call.arguments, result: result)
    case "overwriteOriginal":
      overwriteOriginal(arguments: call.arguments, result: result)
    case "saveToGallery":
      saveToGallery(arguments: call.arguments, result: result)
    case "shareImage":
      shareImage(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func handleOpenURLContexts(
    _ URLContexts: Set<UIOpenURLContext>,
    notifyFlutter: Bool
  ) {
    let payload = URLContexts.compactMap { context -> [String: Any]? in
      do {
        return try buildSharedImage(sourceURL: context.url)
      } catch {
        return nil
      }
    }

    guard !payload.isEmpty else {
      return
    }

    pendingSharedImages = payload
    if notifyFlutter {
      channel?.invokeMethod("sharedImages", arguments: payload)
    }
  }

  private func takeSharedImages(result: @escaping FlutterResult) {
    let images = pendingSharedImages
    pendingSharedImages.removeAll()
    result(images)
  }

  private func pickImages(result: @escaping FlutterResult) {
    guard pendingOperation == nil else {
      result(FlutterError(code: "busy", message: "正在选择图片", details: nil))
      return
    }

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [UTType.image],
        asCopy: false
      )
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.image"], in: .open)
    }
    picker.allowsMultipleSelection = false
    picker.delegate = self
    pendingOperation = .pick(result)
    controller?.present(picker, animated: true)
  }

  private func compressImage(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let args = arguments as? [String: Any],
      let sourceHandle = args["sourceHandle"] as? String,
      let sourceURL = sources[sourceHandle]
    else {
      result(FlutterError(code: "bad_args", message: "缺少 sourceHandle", details: nil))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let payload = try self.compress(sourceURL: sourceURL)
        DispatchQueue.main.async { result(payload) }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "compress_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func overwriteOriginal(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let args = arguments as? [String: Any],
      let sourceHandle = args["sourceHandle"] as? String,
      let compressedPath = args["compressedPath"] as? String,
      let sourceURL = sources[sourceHandle]
    else {
      result(FlutterError(code: "bad_args", message: "缺少覆盖参数", details: nil))
      return
    }

    let compressedURL = URL(fileURLWithPath: compressedPath)
    do {
      let data = try Data(contentsOf: compressedURL)
      let scoped = sourceURL.startAccessingSecurityScopedResource()
      defer {
        if scoped {
          sourceURL.stopAccessingSecurityScopedResource()
        }
      }
      try data.write(to: sourceURL)
      result(["overwritten": true, "target": sourceHandle])
    } catch {
      result(
        FlutterError(
          code: "overwrite_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func shareImage(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let args = arguments as? [String: Any],
      let compressedPath = args["compressedPath"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "缺少 compressedPath", details: nil))
      return
    }
    guard pendingShareResult == nil else {
      result(FlutterError(code: "busy", message: "正在分享", details: nil))
      return
    }
    guard let controller = controller else {
      result(FlutterError(code: "share_unavailable", message: "无法打开分享面板", details: nil))
      return
    }

    do {
      let sourceURL = URL(fileURLWithPath: compressedPath)
      let suggestedName = args["suggestedName"] as? String ?? sourceURL.lastPathComponent
      let exportURL = try makeExportCopy(sourceURL: sourceURL, suggestedName: suggestedName)

      let activityController = UIActivityViewController(
        activityItems: [exportURL],
        applicationActivities: nil
      )
      if let popover = activityController.popoverPresentationController,
        let view = controller.view
      {
        popover.sourceView = view
        popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      pendingShareResult = result
      activityController.completionWithItemsHandler = { [weak self] _, completed, _, error in
        guard let self = self else {
          return
        }
        let pendingResult = self.pendingShareResult
        self.pendingShareResult = nil
        if let error = error {
          pendingResult?(
            FlutterError(code: "share_failed", message: error.localizedDescription, details: nil)
          )
        } else {
          pendingResult?(["shared": completed])
        }
      }
      controller.present(activityController, animated: true)
    } catch {
      result(
        FlutterError(code: "share_failed", message: error.localizedDescription, details: nil)
      )
    }
  }

  private func saveToGallery(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let args = arguments as? [String: Any],
      let compressedPath = args["compressedPath"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "缺少 compressedPath", details: nil))
      return
    }

    let sourceURL = URL(fileURLWithPath: compressedPath)
    saveImageToPhotoLibrary(sourceURL: sourceURL, result: result)
  }

  private func saveImageToPhotoLibrary(
    sourceURL: URL,
    result: @escaping FlutterResult
  ) {
    let saveChanges = {
      PHPhotoLibrary.shared().performChanges({
        _ = PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: sourceURL)
      }) { success, error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
          } else if success {
            result(["saved": true])
          } else {
            result(FlutterError(code: "save_failed", message: "保存到相册失败", details: nil))
          }
        }
      }
    }

    if #available(iOS 14.0, *) {
      switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
      case .authorized, .limited:
        saveChanges()
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          if status == .authorized || status == .limited {
            saveChanges()
          } else {
            DispatchQueue.main.async {
              result(FlutterError(code: "photo_denied", message: "没有相册保存权限", details: nil))
            }
          }
        }
      default:
        result(FlutterError(code: "photo_denied", message: "没有相册保存权限", details: nil))
      }
    } else {
      switch PHPhotoLibrary.authorizationStatus() {
      case .authorized:
        saveChanges()
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization { status in
          if status == .authorized {
            saveChanges()
          } else {
            DispatchQueue.main.async {
              result(FlutterError(code: "photo_denied", message: "没有相册保存权限", details: nil))
            }
          }
        }
      default:
        result(FlutterError(code: "photo_denied", message: "没有相册保存权限", details: nil))
      }
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let operation = pendingOperation else {
      return
    }
    pendingOperation = nil

    switch operation {
    case .pick(let result):
      do {
        if let url = urls.first {
          result([try buildPickedImage(sourceURL: url)])
        } else {
          result([])
        }
      } catch {
        result(
          FlutterError(code: "pick_failed", message: error.localizedDescription, details: nil)
        )
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let operation = pendingOperation else {
      return
    }
    pendingOperation = nil

    switch operation {
    case .pick(let result):
      result([])
    }
  }

  private func buildPickedImage(sourceURL: URL) throws -> [String: Any] {
    let scoped = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let id = UUID().uuidString
    sources[id] = sourceURL

    let previewURL = try copyToCache(
      sourceURL: sourceURL,
      child: "originals",
      preferredName: sourceURL.lastPathComponent
    )
    let dimensions = imageDimensions(for: sourceURL) ?? imageDimensions(for: previewURL)
    let size = fileSize(sourceURL) ?? fileSize(previewURL) ?? 0

    return [
      "sourceHandle": id,
      "displayName": sourceURL.lastPathComponent.isEmpty
        ? "image"
        : sourceURL.lastPathComponent,
      "previewPath": previewURL.path,
      "originalSize": size,
      "width": dimensions?.width ?? 0,
      "height": dimensions?.height ?? 0,
      "canOverwrite": FileManager.default.isWritableFile(atPath: sourceURL.path),
    ]
  }

  private func buildSharedImage(sourceURL: URL) throws -> [String: Any] {
    let scoped = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let displayName = sourceURL.lastPathComponent.isEmpty
      ? "image"
      : sourceURL.lastPathComponent
    let previewURL = try copyToCache(
      sourceURL: sourceURL,
      child: "shared-originals",
      preferredName: displayName
    )
    let id = UUID().uuidString
    sources[id] = previewURL
    let dimensions = imageDimensions(for: previewURL)
    let size = fileSize(previewURL) ?? 0

    return [
      "sourceHandle": id,
      "displayName": displayName,
      "previewPath": previewURL.path,
      "originalSize": size,
      "width": dimensions?.width ?? 0,
      "height": dimensions?.height ?? 0,
      "canOverwrite": false,
    ]
  }

  private func compress(sourceURL: URL) throws -> [String: Any] {
    let scoped = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let originalData = try Data(contentsOf: sourceURL)
    guard let image = UIImage(data: originalData) else {
      throw NativeImageError.message("无法解码图片")
    }

    let originalDimensions = imageDimensions(for: sourceURL)
      ?? PixelSize(
        width: max(1, Int(image.size.width * image.scale)),
        height: max(1, Int(image.size.height * image.scale))
      )
    let targetDimensions = Self.targetSize(for: originalDimensions)
    let hasAlpha = Self.hasAlpha(image)
    let rendered = Self.render(image: image, target: targetDimensions, opaque: !hasAlpha)
    let preservePng = hasAlpha && originalData.count <= 1_500_000
    let quality = Self.jpegQuality(for: targetDimensions)

    let encodedData = preservePng
      ? rendered.pngData()
      : rendered.jpegData(compressionQuality: quality)
    guard let encoded = encodedData else {
      throw NativeImageError.message("无法生成压缩图片")
    }

    var outputData = encoded
    var outputDimensions = targetDimensions
    var outputExtension = preservePng ? "png" : "jpg"
    var passthrough = false

    if encoded.count >= originalData.count {
      outputData = originalData
      outputDimensions = originalDimensions
      outputExtension = sourceURL.pathExtension.isEmpty ? outputExtension : sourceURL.pathExtension
      passthrough = true
    }

    let outputURL = try makeCompressedURL(
      originalName: sourceURL.deletingPathExtension().lastPathComponent,
      extensionName: outputExtension
    )
    try outputData.write(to: outputURL, options: .atomic)

    return [
      "path": outputURL.path,
      "outputSize": outputData.count,
      "width": outputDimensions.width,
      "height": outputDimensions.height,
      "passthrough": passthrough,
    ]
  }

  private func copyToCache(
    sourceURL: URL,
    child: String,
    preferredName: String
  ) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      child,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let targetURL = directory.appendingPathComponent(
      "\(UUID().uuidString)-\(Self.sanitizeFileName(preferredName))"
    )

    do {
      try FileManager.default.copyItem(at: sourceURL, to: targetURL)
    } catch {
      let data = try Data(contentsOf: sourceURL)
      try data.write(to: targetURL, options: .atomic)
    }
    return targetURL
  }

  private func makeCompressedURL(originalName: String, extensionName: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "compressed",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let safeName = Self.sanitizeFileName(originalName.isEmpty ? "image" : originalName)
    return directory.appendingPathComponent("\(UUID().uuidString)-\(safeName).\(extensionName)")
  }

  private func makeExportCopy(sourceURL: URL, suggestedName: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "exports",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let targetURL = directory.appendingPathComponent(Self.sanitizeFileName(suggestedName))
    if FileManager.default.fileExists(atPath: targetURL.path) {
      try FileManager.default.removeItem(at: targetURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: targetURL)
    return targetURL
  }

  private func imageDimensions(for url: URL) -> PixelSize? {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, [
        kCGImageSourceShouldCache: false
      ] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }
    return PixelSize(width: width.intValue, height: height.intValue)
  }

  private func fileSize(_ url: URL) -> Int? {
    if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
      let size = values.fileSize
    {
      return size
    }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? NSNumber
    {
      return size.intValue
    }
    return nil
  }

  private static func targetSize(for source: PixelSize) -> PixelSize {
    let width = max(1, source.width)
    let height = max(1, source.height)
    let longSide = max(width, height)
    let shortSide = min(width, height)
    let aspect = Double(shortSide) / Double(longSide)
    var scale = 1.0

    if longSide > 10_800 && aspect > 0.25 {
      scale = min(scale, 1440.0 / Double(longSide))
    } else if shortSide > 1440 {
      scale = min(scale, 1440.0 / Double(shortSide))
    }

    let sourcePixels = Double(width) * Double(height)
    if sourcePixels > 40_960_000 {
      scale = min(scale, 0.5)
    }

    let scaledPixels = sourcePixels * scale * scale
    if scaledPixels > 10_240_000 {
      scale = min(scale, sqrt(10_240_000 / sourcePixels))
    }

    return PixelSize(
      width: max(1, Int((Double(width) * scale).rounded(.down))),
      height: max(1, Int((Double(height) * scale).rounded(.down)))
    )
  }

  private static func jpegQuality(for size: PixelSize) -> CGFloat {
    let megapixels = Double(size.width * size.height) / 1_000_000
    if megapixels < 0.5 {
      return 0.92
    }
    if megapixels < 1.0 {
      return 0.88
    }
    if megapixels < 3.0 {
      return 0.8
    }
    return 0.72
  }

  private static func render(image: UIImage, target: PixelSize, opaque: Bool) -> UIImage {
    let size = CGSize(width: CGFloat(target.width), height: CGFloat(target.height))
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = opaque
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }

  private static func hasAlpha(_ image: UIImage) -> Bool {
    guard let alpha = image.cgImage?.alphaInfo else {
      return false
    }
    switch alpha {
    case .first, .last, .premultipliedFirst, .premultipliedLast:
      return true
    default:
      return false
    }
  }

  private static func sanitizeFileName(_ name: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let sanitized = name.unicodeScalars
      .map { allowed.contains($0) ? String($0) : "_" }
      .joined()
    return sanitized.isEmpty ? "image.jpg" : sanitized
  }
}

private struct PixelSize {
  let width: Int
  let height: Int
}

private enum NativeImageError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }
}
