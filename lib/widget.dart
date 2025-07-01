import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:apple_vision_recognize_text/apple_vision_recognize_text.dart'
    as apple;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'clipper.dart';
import 'credit_card.dart';
import 'helpers.dart';
import 'process.dart';

/// A widget that displays a live camera preview and scans for credit card information.
///
/// This version allows you to pass in your own [CameraController] if desired,
/// and exposes the controller via [onControllerCreated].
class CameraScannerWidget extends StatefulWidget {
  /// Callback function called when a credit card is successfully scanned.
  final void Function(BuildContext, CreditCardModel?) onScan;

  /// Widget to display while the camera is initializing.
  final Widget loadingHolder;

  /// Callback function called when no camera is available on the device.
  final void Function() onNoCamera;

  /// Optional external camera controller.
  /// If provided, it will be used instead of creating a new one.
  final CameraController? externalController;

  /// Callback to receive the initialized controller.
  final void Function(CameraController controller)? onControllerCreated;

  /// Aspect ratio for the camera preview. If null, uses the device's screen aspect ratio.
  final double? aspectRatio;

  /// Whether to scan for the card number. Defaults to true.
  final bool cardNumber;

  /// Whether to scan for the card holder's name. Defaults to true.
  final bool cardHolder;

  /// Whether to scan for the card's expiry date. Defaults to true.
  final bool cardExpiryDate;

  /// The color of the overlay that highlights the credit card scanning area.
  final Color? colorOverlay;

  /// The shape of the border surrounding the credit card scanning area.
  final ShapeBorder? shapeBorder;

  /// Force Luhn validation of the card number. Defaults to true.
  final bool useLuhnValidation;

  /// Enable debug logging. Defaults to [kDebugMode].
  final bool debug;

  /// Duration to wait before processing the next frame.
  final Duration? durationOfNextFrame;

  /// Resolution preset for the camera.
  final ResolutionPreset? resolutionPreset;

  const CameraScannerWidget({
    super.key,
    required this.onScan,
    required this.loadingHolder,
    required this.onNoCamera,
    this.externalController,
    this.onControllerCreated,
    this.aspectRatio,
    this.cardNumber = true,
    this.cardHolder = true,
    this.cardExpiryDate = true,
    this.colorOverlay,
    this.shapeBorder,
    this.useLuhnValidation = true,
    this.debug = kDebugMode,
    this.durationOfNextFrame,
    this.resolutionPreset,
  });

  @override
  State<CameraScannerWidget> createState() => _CameraScannerWidgetState();
}

class _CameraScannerWidgetState extends State<CameraScannerWidget>
    with WidgetsBindingObserver {
  final apple.AppleVisionRecognizeTextController appleVisionController =
      apple.AppleVisionRecognizeTextController();
  CameraController? controller;
  final TextRecognizer mlTextRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final ValueNotifier<bool> valueLoading = ValueNotifier<bool>(true);
  bool scanning = false;

  late final ProccessCreditCard _process = ProccessCreditCard(
    useLuhnValidation: widget.useLuhnValidation,
    checkCreditCardNumber: widget.cardNumber,
    checkCreditCardName: widget.cardHolder,
    checkCreditCardExpiryDate: widget.cardExpiryDate,
  );

  Color get colorOverlay =>
      widget.colorOverlay ?? Colors.black.withOpacity(0.8);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.externalController != null) {
      // Use external controller directly
      controller = widget.externalController;
      // Expose it immediately
      widget.onControllerCreated?.call(controller!);
      _startStreamWithController(controller!);
    } else {
      // Create our own controller
      availableCameras().then((cameras) async {
        if (cameras.isEmpty) {
          widget.onNoCamera();
          return;
        }
        final back = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
            orElse: () => cameras.first);
        await _initializeInternalController(back);
      }).onError((_, __) {
        widget.onNoCamera();
      });
    }
  }

  Future<void> _startStreamWithController(CameraController ctrl) async {
    if (ctrl.value.isInitialized) {
      valueLoading.value = false;
      await ctrl.startImageStream((image) {
        process(image, ctrl.description);
      });
    } else {
      ctrl.initialize().then((_) async {
        if (!mounted) return;
        valueLoading.value = false;
        await ctrl.startImageStream((image) {
          process(image, ctrl.description);
        });
      }).catchError((_) {
        widget.onNoCamera();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return ValueListenableBuilder<bool>(
      valueListenable: valueLoading,
      builder: (context, isLoading, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: isLoading
              ? widget.loadingHolder
              : Stack(
                  children: [
                    Container(color: Colors.black),
                    Center(child: CameraPreview(controller!)),
                    Container(
                      decoration: ShapeDecoration(
                        shape: widget.shapeBorder ??
                            OverlayShape(
                              cutOutHeight: size.height * 0.3,
                              cutOutWidth: size.width * 0.95,
                              overlayColor: colorOverlay,
                              borderRadius: 20,
                            ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.externalController == null) {
      controller?.dispose();
    }
    mlTextRecognizer.close();
    super.dispose();
  }

  Future<void> _initializeInternalController(
      CameraDescription description) async {
    final camController = CameraController(
      description,
      widget.resolutionPreset ?? ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    controller = camController;
    await camController.initialize();
    // Expose the new controller
    widget.onControllerCreated?.call(camController);
    valueLoading.value = false;
    await camController.startImageStream((image) {
      process(image, description);
    });
  }

  void process(CameraImage image, CameraDescription description) async {
    if (scanning) return;
    scanning = true;
    final rotation =
        InputImageRotationValue.fromRawValue(description.sensorOrientation) ??
            InputImageRotation.rotation0deg;
    final bytes = image.planes.expand((p) => p.bytes).toList();
    try {
      if (Platform.isIOS) {
        final textR = await appleVisionController.processImage(
          apple.RecognizeTextData(
            automaticallyDetectsLanguage: false,
            languages: [const Locale('en', 'US')],
            recognitionLevel: apple.RecognitionLevel.accurate,
            image: Uint8List.fromList(bytes),
            orientation: rotation.appleRotation,
            imageSize: Size(
              image.width.toDouble(),
              image.height.toDouble(),
            ),
          ),
        );
        if (textR?.isNotEmpty == true) onScanApple(textR!);
      } else {
        final inputImage = InputImage.fromBytes(
          bytes: Uint8List.fromList(bytes),
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.yv12,
            bytesPerRow: image.planes[0].bytesPerRow,
          ),
        );
        final textR = await mlTextRecognizer.processImage(inputImage);
        if (textR.text.isNotEmpty) onScanTextML(textR);
      }
    } catch (e) {
      if (widget.debug) rethrow;
    } finally {
      if (widget.durationOfNextFrame != null) {
        Future.delayed(widget.durationOfNextFrame!, () {
          scanning = false;
        });
      } else {
        scanning = false;
      }
    }
  }

  void onScanApple(List<apple.RecognizedText> list) {
    for (var item in list) {
      for (var element in item.listText) {
        _process.processNumber(element);
        _process.processName(element);
        _process.processDate(element);
      }
    }
    final model = _process.getCreditCardModel();
    if (model != null) widget.onScan(context, model);
  }

  void onScanTextML(RecognizedText readText) {
    for (final block in readText.blocks) {
      for (final line in block.lines) {
        if (widget.debug) log(line.text);
        _process.processNumber(line.text);
        _process.processName(line.text);
        _process.processDate(line.text);
      }
    }
    final model = _process.getCreditCardModel();
    if (model != null) {
      if (widget.debug) log('Scanned card: $model');
      widget.onScan(context, model);
    }
  }
}
