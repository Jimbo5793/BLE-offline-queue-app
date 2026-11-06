import 'dart:typed_data';

/// Splits messages into pieces small enough for Bluetooth, and puts them back
/// together.
///
/// Bluetooth won't do this for us. A single packet holds as little as 20 bytes
/// before the two devices negotiate something bigger, and the library we use
/// for hosting doesn't tell us when a long write is still arriving. Doing it
/// ourselves avoids both problems. A queue of 20 people is easily more than
/// one packet.
class Chunker {
  /// Each piece starts with: id length, piece number, total pieces, then the
  /// message id, then the data.
  static const int headerOverhead = 3;

  /// Bluetooth uses 3 bytes of each packet for its own headers.
  static int payloadForMtu(int mtu) => (mtu - 3).clamp(20, 512);

  static List<Uint8List> split({
    required String messageId,
    required Uint8List bytes,
    required int maxChunkSize,
  }) {
    final id = Uint8List.fromList(messageId.codeUnits);
    final bodyMax = maxChunkSize - headerOverhead - id.length;
    if (bodyMax <= 0) {
      throw ArgumentError('maxChunkSize $maxChunkSize too small for id');
    }
    final total = (bytes.length / bodyMax).ceil().clamp(1, 255);
    if ((bytes.length / bodyMax).ceil() > 255) {
      throw ArgumentError('payload needs more than 255 chunks');
    }

    return [
      for (var i = 0; i < total; i++)
        (BytesBuilder(copy: false)
              ..addByte(id.length)
              ..addByte(i)
              ..addByte(total)
              ..add(id)
              ..add(bytes.sublist(
                  i * bodyMax, ((i + 1) * bodyMax).clamp(0, bytes.length))))
            .toBytes(),
    ];
  }
}

/// Collects pieces until a whole message has arrived.
class Reassembler {
  final _partial = <String, List<Uint8List?>>{};

  /// Returns the full message once the last piece arrives, otherwise null.
  /// Throws [FormatException] on a piece that doesn't make sense.
  Uint8List? accept(Uint8List frame) {
    if (frame.length < Chunker.headerOverhead) {
      throw const FormatException('chunk too short');
    }
    final idLen = frame[0];
    final index = frame[1];
    final total = frame[2];
    if (total == 0 || index >= total) {
      throw FormatException('bad chunk index $index/$total');
    }
    if (frame.length < Chunker.headerOverhead + idLen) {
      throw const FormatException('chunk truncated');
    }
    final id = String.fromCharCodes(
        frame.sublist(Chunker.headerOverhead, Chunker.headerOverhead + idLen));
    final body =
        Uint8List.sublistView(frame, Chunker.headerOverhead + idLen);

    final slots = _partial.putIfAbsent(id, () => List.filled(total, null));
    if (slots.length != total) {
      // The sender started again with a different number of pieces.
      _partial[id] = List.filled(total, null)..[index] = body;
      return null;
    }
    slots[index] = body;
    if (slots.any((c) => c == null)) return null;

    _partial.remove(id);
    final out = BytesBuilder(copy: false);
    for (final c in slots) {
      out.add(c!);
    }
    return out.toBytes();
  }

  /// How many messages are still waiting for pieces.
  int get pending => _partial.length;
  void discard(String messageId) => _partial.remove(messageId);
  void clear() => _partial.clear();
}
