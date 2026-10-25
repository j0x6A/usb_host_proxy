import 'dart:typed_data';

/// Validates a public Dart slice before allocation or narrowing to JNI's int.
/// A null buffer denotes an empty transfer, not an implicit allocation.
int transferLength(Uint8List? buffer, int offset, int? length) {
  final size = buffer?.length ?? 0;
  RangeError.checkValueInInterval(offset, 0, size, 'offset');
  final count = length ?? size - offset;
  RangeError.checkValueInInterval(count, 0, size - offset, 'length');
  jniInt(count, 'length');
  return count;
}

/// Rejects values JNI would otherwise silently truncate. Does not impose USB limits.
int jniInt(int value, String name) =>
    RangeError.checkValueInInterval(value, -0x80000000, 0x7fffffff, name);

/// Writes only the completed IN prefix; bytes outside that prefix stay untouched.
void receiveBytes(Uint8List? target, int offset, List<int> bytes, int count) {
  if (count <= 0) return;
  if (target == null ||
      count > bytes.length ||
      count > target.length - offset) {
    throw StateError('Android returned an invalid USB transfer length: $count');
  }
  target.setRange(offset, offset + count, bytes);
}
