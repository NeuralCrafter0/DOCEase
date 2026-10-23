import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'jpeg_encoder.dart';

enum AttachmentError { unsupported, tooLarge, unreadable }

class AttachmentException implements Exception {
  final AttachmentError error;
  const AttachmentException(this.error);

  /// Text shown to the doctor. Nothing is attached when this is thrown.
  String get message => switch (error) {
        AttachmentError.unsupported =>
          "This file isn't a photo DOCEase can read, so it wasn't added. Use a JPEG, PNG, HEIC or WebP photo.",
        AttachmentError.tooLarge => "This photo is too large to add (over 50 MB), so it wasn't added.",
        AttachmentError.unreadable => "This photo couldn't be opened, so it wasn't added. Please try again.",
      };

  @override
  String toString() => 'AttachmentException($error)';
}

/// Turns any picked image into a JPEG file with a `.jpg` name, ready for the
/// visit's attachmentPaths. Every pick is decoded and re-encoded on the device,
/// whatever its original format, so only JPEG reaches the upload flow.
/// Anything that can't be decoded throws [AttachmentException] and produces
/// no file.
class AttachmentProcessor {
  AttachmentProcessor({Future<Directory> Function()? outputDirectory, this.maxEdge = 2048, this.quality = 85})
      : _outputDirectory = outputDirectory ?? _defaultDirectory;

  static const int maxInputBytes = 50 * 1024 * 1024;

  final Future<Directory> Function() _outputDirectory;

  /// Longest side of the stored photo, in pixels.
  final int maxEdge;
  final int quality;

  static Future<Directory> _defaultDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'attachments'));
  }

  Future<String> toJpegFile(XFile picked) async {
    final Uint8List bytes;
    try {
      if (await picked.length() > maxInputBytes) throw const AttachmentException(AttachmentError.tooLarge);
      bytes = await picked.readAsBytes();
    } on AttachmentException {
      rethrow;
    } catch (_) {
      throw const AttachmentException(AttachmentError.unreadable);
    }

    final jpeg = await encodeBytes(bytes);

    final dir = await _outputDirectory();
    await dir.create(recursive: true);
    final out = File(p.join(dir.path, '${const Uuid().v4()}.jpg'));
    try {
      await out.writeAsBytes(jpeg, flush: true);
    } catch (_) {
      if (await out.exists()) await out.delete();
      throw const AttachmentException(AttachmentError.unreadable);
    }
    return out.path;
  }

  /// Decodes [bytes] (any format the platform decoder supports), scales the
  /// longest side down to [maxEdge] and returns JPEG bytes.
  Future<Uint8List> encodeBytes(Uint8List bytes) async {
    final _Rgba rgba;
    try {
      rgba = await _decode(bytes);
    } catch (_) {
      throw const AttachmentException(AttachmentError.unsupported);
    }
    return compute(_encodeJpeg, _EncodeJob(rgba.pixels, rgba.width, rgba.height, quality));
  }

  Future<_Rgba> _decode(Uint8List bytes) async {
    if (bytes.isEmpty) throw const FormatException('empty');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      if (w <= 0 || h <= 0) throw const FormatException('no size');
      int? tw, th;
      if (w > maxEdge || h > maxEdge) {
        final scale = maxEdge / (w > h ? w : h);
        tw = (w * scale).round().clamp(1, maxEdge);
        th = (h * scale).round().clamp(1, maxEdge);
      }
      codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw const FormatException('no pixels');
      return _Rgba(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), image.width, image.height);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

class _Rgba {
  final Uint8List pixels;
  final int width;
  final int height;
  const _Rgba(this.pixels, this.width, this.height);
}

class _EncodeJob {
  final Uint8List pixels;
  final int width;
  final int height;
  final int quality;
  const _EncodeJob(this.pixels, this.width, this.height, this.quality);
}

Uint8List _encodeJpeg(_EncodeJob job) => JpegEncoder(quality: job.quality).encode(job.pixels, job.width, job.height);
