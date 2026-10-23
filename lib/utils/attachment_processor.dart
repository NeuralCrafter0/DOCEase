import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'attachment_storage.dart';
import 'jpeg_encoder.dart';
import 'picker_hygiene.dart';

enum AttachmentError { unsupported, tooLarge, unreadable }

class AttachmentException implements Exception {
  final AttachmentError error;
  const AttachmentException(this.error);

  /// Text shown to the doctor. Nothing is attached when this is thrown.
  String get message => switch (error) {
        AttachmentError.unsupported =>
          "This file isn't a photo DOCEase can read, so it wasn't added. Use a JPEG, PNG, HEIC or WebP photo.",
        AttachmentError.tooLarge => "This photo is too large to add, so it wasn't added.",
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
///
/// There is no default output folder: use [AttachmentProcessor.forStorage]
/// (one owner's folder) or pass [outputDirectory].
class AttachmentProcessor {
  AttachmentProcessor({
    required Future<Directory> Function() outputDirectory,
    this.maxEdge = 2048,
    this.quality = 85,
    this.maxOutputBytes = defaultMaxOutputBytes,
    Future<void> Function(String path)? discardSource,
  })  : _outputDirectory = outputDirectory,
        _discardSource = discardSource ?? _discardPickerCopy;

  /// Photos for [storage]'s owner, in that owner's folder.
  factory AttachmentProcessor.forStorage(AttachmentStorage storage) => AttachmentProcessor(outputDirectory: storage.directory);

  static const int maxInputBytes = 50 * 1024 * 1024;

  /// Refused before decoding (a small PNG can declare 20000x20000).
  static const int maxPixels = 100 * 1000 * 1000;

  /// Storage rules (PR #2) accept at most 10 MiB per photo.
  static const int defaultMaxOutputBytes = 10 * 1024 * 1024;

  final Future<Directory> Function() _outputDirectory;
  final Future<void> Function(String path) _discardSource;

  /// Longest side of the stored photo, in pixels.
  final int maxEdge;
  final int quality;
  final int maxOutputBytes;

  static Future<void> _discardPickerCopy(String path) async {
    await PickerHygiene().discardPickedSource(path);
  }

  /// Converts [picked] and returns the new file's path. The picker's own
  /// copy of the photo (original bytes and EXIF) is deleted afterwards when
  /// it is in a temp folder, whether or not the conversion worked.
  Future<String> toJpegFile(XFile picked) async {
    final Uint8List bytes;
    try {
      try {
        if (await picked.length() > maxInputBytes) throw const AttachmentException(AttachmentError.tooLarge);
        bytes = await picked.readAsBytes();
      } on AttachmentException {
        rethrow;
      } catch (_) {
        throw const AttachmentException(AttachmentError.unreadable);
      }
    } finally {
      try {
        await _discardSource(picked.path);
      } catch (_) {}
    }

    var jpeg = await encodeBytes(bytes);
    if (jpeg.length > maxOutputBytes && quality > 50) {
      // One retry at a lower quality before giving up.
      jpeg = await encodeBytes(bytes, quality: quality - 25 < 50 ? 50 : quality - 25);
    }
    if (jpeg.length > maxOutputBytes) throw const AttachmentException(AttachmentError.tooLarge);

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
  /// longest side down to [maxEdge] and returns JPEG bytes. Images over
  /// [maxPixels] are refused before any pixels are decoded.
  Future<Uint8List> encodeBytes(Uint8List bytes, {int? quality}) async {
    final _Rgba rgba;
    try {
      rgba = await _decode(bytes);
    } on AttachmentException {
      rethrow;
    } catch (_) {
      throw const AttachmentException(AttachmentError.unsupported);
    }
    return compute(_encodeJpeg, _EncodeJob(rgba.pixels, rgba.width, rgba.height, quality ?? this.quality));
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
      if (w * h > maxPixels) throw const AttachmentException(AttachmentError.tooLarge);
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
