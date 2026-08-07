import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

/// 端侧物体识别服务（基于 Google ML Kit Object Detection）。
///
/// 用途：视频通话模式下，把相机帧实时送入 ML Kit，识别出画面中的物体
/// （如 cup、person、chair…）及其置信度，叠加显示在本地预览上，
/// 实现「小智看到我这边的物体进行识别」。
///
/// 注意：识别完全在设备端完成，不依赖服务器；视频帧不会上传，仅用于本地识别。
class ObjectDetectionService {
  static const String _TAG = 'ObjectDetectionService';

  ObjectDetector? _detector;
  bool _initialized = false;
  bool _isBusy = false; // 防止同一时刻堆积多帧推理

  static final ObjectDetectionService _instance =
      ObjectDetectionService._internal();
  factory ObjectDetectionService() => _instance;
  ObjectDetectionService._internal();

  Future<void> init() async {
    if (_initialized) return;
    try {
      final options = ObjectDetectorOptions(
        mode: DetectionMode.stream, // 流式：每帧快速推理
        classifyObjects: true, // 输出类别标签 + 置信度
        multipleObjects: true, // 同时识别多个物体
      );
      _detector = ObjectDetector(options: options);
      _initialized = true;
      print('$_TAG: 物体识别引擎初始化成功');
    } catch (e) {
      print('$_TAG: 物体识别初始化失败: $e');
      _initialized = false;
    }
  }

  bool get isInitialized => _initialized;

  /// 处理一帧相机图像，返回识别到的物体（带标签、置信度、包围框）。
  /// [rotationDegrees] 为相机传感器朝向（0/90/180/270）。
  /// 单帧推理较重，内部用 [_isBusy] 节流：上一帧未处理完则直接跳过本帧。
  Future<List<DetectedObject>> processCameraImage(
    CameraImage image,
    int rotationDegrees,
  ) async {
    if (!_initialized || _detector == null) return const [];
    if (_isBusy) return const [];
    _isBusy = true;
    try {
      final input = _inputImageFromCameraImage(image, rotationDegrees);
      if (input == null) return const [];
      final objects = await _detector!.processImage(input);
      return objects;
    } catch (e) {
      // 单帧失败不应中断整条识别流
      print('$_TAG: 单帧识别失败(已跳过): $e');
      return const [];
    } finally {
      _isBusy = false;
    }
  }

  /// 把 CameraImage（Android YUV_420_888 三平面）转为 ML Kit 需要的 NV21 字节。
  /// 需正确处理行跨距(stride)与像素跨距，否则拼接出的 NV21 尺寸错位、识别失败。
  InputImage? _inputImageFromCameraImage(
    CameraImage image,
    int rotationDegrees,
  ) {
    try {
      // 仅支持 Android 默认的 YUV_420_888（3 平面）。iOS 为双平面，本构建仅面向 Android。
      if (image.planes.length < 3) {
        print('$_TAG: 不支持的图像格式（平面数=${image.planes.length}）');
        return null;
      }

      final int width = image.width;
      final int height = image.height;

      final planeY = image.planes[0];
      final planeU = image.planes[1];
      final planeV = image.planes[2];

      final int yRowStride = planeY.bytesPerRow;
      final int uvRowStride = planeU.bytesPerRow;
      final int uvPixelStride = planeU.bytesPerPixel ?? 1;

      // NV21 大小 = Y(宽×高) + VU 交错(宽×高/2)
      final Uint8List nv21 = Uint8List(width * height + width * height ~/ 2);

      // 1) 拷贝 Y 平面（逐行，跳过行 padding）
      int yIndex = 0;
      for (int y = 0; y < height; y++) {
        final rowStart = y * yRowStride;
        if (yRowStride == width) {
          nv21.setRange(yIndex, yIndex + width, planeY.bytes, rowStart);
          yIndex += width;
        } else {
          for (int x = 0; x < width; x++) {
            nv21[yIndex++] = planeY.bytes[rowStart + x];
          }
        }
      }

      // 2) 拷贝 V、U 交错（NV21 顺序为 V 在前、U 在后）
      int uvIndex = width * height;
      for (int y = 0; y < height ~/ 2; y++) {
        final uvRowStart = y * uvRowStride;
        for (int x = 0; x < width ~/ 2; x++) {
          final int uOffset = uvRowStart + x * uvPixelStride;
          final int vOffset = uvRowStart + x * uvPixelStride;
          nv21[uvIndex++] = planeV.bytes[vOffset]; // V
          nv21[uvIndex++] = planeU.bytes[uOffset]; // U
        }
      }

      final rotation = InputImageRotationValue.fromRawValue(rotationDegrees) ??
          InputImageRotation.rotation0deg;

      return InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: Size(width.toDouble(), height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: width, // NV21 紧密排列，每行 = 宽度
        ),
      );
    } catch (e) {
      print('$_TAG: 图像转换失败: $e');
      return null;
    }
  }

  /// 释放模型资源（进程退出时调用；单例一般生命周期随 App）。
  void dispose() {
    _detector?.close();
    _detector = null;
    _initialized = false;
  }
}
