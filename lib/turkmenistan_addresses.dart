/// Оффлайновый поиск адресов Туркменистана.
///
/// ```dart
/// final db = await loadTurkmenistanAddresses();
/// for (final hit in db.search('par 2/4 1')) {
///   print('${hit.title} — ${hit.lat}, ${hit.lon}');
/// }
/// ```
///
/// База собрана из экстракта OpenStreetMap скриптом
/// `tool/build_address_db.py` и лежит внутри пакета: сеть не нужна ни при
/// загрузке, ни при запросе.
library;

import 'package:flutter/services.dart' show rootBundle;

import 'src/address_db.dart';

export 'src/address_db.dart' show AddressDatabase, distanceMeters;
export 'src/address_search.dart' show normalize;
export 'src/models.dart';

/// Путь к встроенной базе. Пригодится тому, кто читает ассет сам —
/// например, чтобы передать байты в изолят.
const String turkmenistanAddressesAsset =
    'packages/turkmenistan_addresses/assets/turkmenistan.adb';

/// Открывает встроенную базу.
///
/// Разбор ничего не копирует — секции остаются представлениями над
/// загруженным буфером, — поэтому вызов дешёвый и отдельный изолят ему не
/// нужен. Ключи поиска считаются при первом [AddressDatabase.search] —
/// [AddressDatabase.warmUp] переносит эту работу на момент загрузки.
Future<AddressDatabase> loadTurkmenistanAddresses() async {
  final data = await rootBundle.load(turkmenistanAddressesAsset);
  return AddressDatabase.parse(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}
