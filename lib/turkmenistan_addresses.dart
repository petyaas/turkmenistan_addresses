/// Offline address search for Turkmenistan.
///
/// ```dart
/// final db = await loadTurkmenistanAddresses();
/// for (final hit in db.search('par 2/4 1')) {
///   print('${hit.title} — ${hit.lat}, ${hit.lon}');
/// }
/// ```
///
/// The database is built from an OpenStreetMap extract by
/// `tool/build_address_db.py` and ships inside the package: no network is
/// used at load time or at query time.
library;

import 'package:flutter/services.dart' show rootBundle;

import 'src/address_db.dart';

export 'src/address_db.dart' show AddressDatabase, distanceMeters;
export 'src/address_search.dart' show normalize;
export 'src/models.dart';

/// Path to the bundled database. Useful when reading the asset yourself —
/// to hand the bytes to an isolate, for instance.
const String turkmenistanAddressesAsset =
    'packages/turkmenistan_addresses/assets/turkmenistan.adb';

/// Opens the bundled database.
///
/// Parsing copies nothing — the sections stay views over the loaded buffer
/// — so the call is cheap and needs no isolate of its own. Search keys are
/// built on the first [AddressDatabase.search]; [AddressDatabase.warmUp]
/// moves that work to load time.
Future<AddressDatabase> loadTurkmenistanAddresses() async {
  final data = await rootBundle.load(turkmenistanAddressesAsset);
  return AddressDatabase.parse(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}
