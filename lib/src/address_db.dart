import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'address_search.dart';
import 'models.dart';

/// The address database of Turkmenistan: settlements, streets, houses and
/// public places.
///
/// The file layout is described in `tool/address_db_format.py` — a paired
/// implementation, so a change belongs in both places, with [formatVersion]
/// raised together. The loader refuses a version it does not know rather
/// than reading garbage. A version 1 file (no public places) still opens.
///
/// The data sits as typed views over a single buffer and is never copied:
/// strings are assembled only when asked for.
class AddressDatabase {
  AddressDatabase._({
    required Int32List placeLat,
    required Int32List placeLon,
    required Uint32List placeName,
    required Uint8List placeType,
    required Int32List streetLat,
    required Int32List streetLon,
    required Uint32List streetName,
    required Uint32List streetPlace,
    required Int32List addressLat,
    required Int32List addressLon,
    required Uint32List addressStreet,
    required Uint32List numberOffset,
    required Uint8List numberBytes,
    required Uint8List streetExactBits,
    required Uint32List stringOffset,
    required Uint8List stringBytes,
    required Int32List poiLat,
    required Int32List poiLon,
    required Uint32List poiName,
    required Uint8List poiCategory,
    required Uint32List poiPlace,
  })  : _placeLat = placeLat,
        _placeLon = placeLon,
        _placeName = placeName,
        _placeType = placeType,
        _streetLat = streetLat,
        _streetLon = streetLon,
        _streetName = streetName,
        _streetPlace = streetPlace,
        _addressLat = addressLat,
        _addressLon = addressLon,
        _addressStreet = addressStreet,
        _numberOffset = numberOffset,
        _numberBytes = numberBytes,
        _streetExactBits = streetExactBits,
        _stringOffset = stringOffset,
        _stringBytes = stringBytes,
        _poiLat = poiLat,
        _poiLon = poiLon,
        _poiName = poiName,
        _poiCategory = poiCategory,
        _poiPlace = poiPlace,
        _places = List<Place?>.filled(placeLat.length, null),
        _streets = List<Street?>.filled(streetLat.length, null),
        _publicPlaces = List<PublicPlace?>.filled(poiLat.length, null);

  /// The version this package writes. Version 1 — before public places —
  /// is read too.
  static const int formatVersion = 2;

  /// 'TMAB' read as a little-endian uint32.
  static const int _magic = 0x42414D54;

  static const int _sPlaceLat = 0;
  static const int _sPlaceLon = 1;
  static const int _sPlaceName = 2;
  static const int _sPlaceType = 3;
  static const int _sStreetLat = 4;
  static const int _sStreetLon = 5;
  static const int _sStreetName = 6;
  static const int _sStreetPlace = 7;
  static const int _sAddressLat = 8;
  static const int _sAddressLon = 9;
  static const int _sAddressStreet = 10;
  static const int _sNumberOffset = 11;
  static const int _sNumber = 12;
  static const int _sStringOffset = 13;
  static const int _sString = 14;
  static const int _sStreetExact = 15;
  static const int _sPoiLat = 16;
  static const int _sPoiLon = 17;
  static const int _sPoiName = 18;
  static const int _sPoiCategory = 19;
  static const int _sPoiPlace = 20;

  /// Sections in a file of each version.
  static const Map<int, int> _sectionCounts = {1: 16, 2: 21};

  static const int _headerBytes = 32;

  /// A street with no settlement: NO_REF in `address_db_format.py`.
  static const int _noRef = 0xFFFFFFFF;

  final Int32List _placeLat;
  final Int32List _placeLon;
  final Uint32List _placeName;
  final Uint8List _placeType;

  final Int32List _streetLat;
  final Int32List _streetLon;
  final Uint32List _streetName;
  final Uint32List _streetPlace;

  final Int32List _addressLat;
  final Int32List _addressLon;
  final Uint32List _addressStreet;
  final Uint32List _numberOffset;
  final Uint8List _numberBytes;
  final Uint8List _streetExactBits;

  final Uint32List _stringOffset;
  final Uint8List _stringBytes;

  // Public places, sorted by category and then by name.
  final Int32List _poiLat;
  final Int32List _poiLon;
  final Uint32List _poiName;
  final Uint8List _poiCategory;
  final Uint32List _poiPlace;

  final List<Place?> _places;
  final List<Street?> _streets;
  final List<PublicPlace?> _publicPlaces;

  // Search keys are built on the first query, not at load time: whoever
  // opened the database for nearestAddress alone should not pay for them.
  List<String>? _placeKeys;
  List<String>? _streetKeys;
  Uint16List? _streetNameKeyLength;
  List<String>? _addressKeys;
  Uint16List? _addressNameKeyLength;
  List<String>? _poiKeys;
  Uint16List? _poiNameKeyLength;

  int get placeCount => _placeLat.length;
  int get streetCount => _streetLat.length;
  int get addressCount => _addressLat.length;
  int get publicPlaceCount => _poiLat.length;

  /// Parses the contents of an `.adb` file.
  factory AddressDatabase.parse(Uint8List bytes) {
    var source = bytes;
    // Typed views need 4-byte alignment, and rootBundle hands back a
    // slice of a shared buffer at an arbitrary offset.
    if (source.offsetInBytes % 4 != 0) {
      source = Uint8List.fromList(source);
    }
    final buffer = source.buffer;
    final base = source.offsetInBytes;

    if (source.length < _headerBytes) {
      throw const FormatException('the address database is truncated');
    }
    final header = ByteData.view(buffer, base, _headerBytes);
    if (header.getUint32(0, Endian.little) != _magic) {
      throw const FormatException('this is not an address database');
    }
    final version = header.getUint32(4, Endian.little);
    final sectionCount = _sectionCounts[version];
    if (sectionCount == null) {
      throw FormatException(
        'address database version $version, the package expects '
        '$formatVersion — rebuild the asset with tool/build_address_db.py',
      );
    }
    if (source.length < _headerBytes + sectionCount * 8) {
      throw const FormatException('the address database is truncated');
    }

    final table = ByteData.view(buffer, base + _headerBytes, sectionCount * 8);
    int start(int index) => table.getUint32(index * 8, Endian.little);
    int length(int index) => table.getUint32(index * 8 + 4, Endian.little);

    // A section past the end of the buffer means a cut-off file, not one
    // to read garbage from.
    void check(int section) {
      if (start(section) + length(section) > source.length) {
        throw const FormatException('the address database is truncated');
      }
    }

    for (var section = 0; section < sectionCount; section++) {
      check(section);
    }

    // A version 1 file has no public places: their sections are empty.
    Int32List int32(int section) => section >= sectionCount
        ? Int32List(0)
        : Int32List.view(buffer, base + start(section), length(section) ~/ 4);
    Uint32List uint32(int section) => section >= sectionCount
        ? Uint32List(0)
        : Uint32List.view(buffer, base + start(section), length(section) ~/ 4);
    Uint8List uint8(int section) => section >= sectionCount
        ? Uint8List(0)
        : Uint8List.view(buffer, base + start(section), length(section));

    return AddressDatabase._(
      placeLat: int32(_sPlaceLat),
      placeLon: int32(_sPlaceLon),
      placeName: uint32(_sPlaceName),
      placeType: uint8(_sPlaceType),
      streetLat: int32(_sStreetLat),
      streetLon: int32(_sStreetLon),
      streetName: uint32(_sStreetName),
      streetPlace: uint32(_sStreetPlace),
      addressLat: int32(_sAddressLat),
      addressLon: int32(_sAddressLon),
      addressStreet: uint32(_sAddressStreet),
      numberOffset: uint32(_sNumberOffset),
      numberBytes: uint8(_sNumber),
      streetExactBits: uint8(_sStreetExact),
      stringOffset: uint32(_sStringOffset),
      stringBytes: uint8(_sString),
      poiLat: int32(_sPoiLat),
      poiLon: int32(_sPoiLon),
      poiName: uint32(_sPoiName),
      poiCategory: uint8(_sPoiCategory),
      poiPlace: uint32(_sPoiPlace),
    );
  }

  String _string(int index) {
    final from = _stringOffset[index];
    final to = _stringOffset[index + 1];
    if (to <= from) return '';
    return utf8.decode(Uint8List.sublistView(_stringBytes, from, to));
  }

  Place placeAt(int index) {
    final cached = _places[index];
    if (cached != null) return cached;
    final raw = _placeType[index];
    final place = Place(
      id: index,
      name: _string(_placeName[index]),
      // A file built newer than this package may carry a type it does not
      // know — better to show it as a locality than to crash on it.
      type: raw < PlaceType.values.length
          ? PlaceType.values[raw]
          : PlaceType.locality,
      lat: _placeLat[index] / 1e7,
      lon: _placeLon[index] / 1e7,
    );
    _places[index] = place;
    return place;
  }

  Street streetAt(int index) {
    final cached = _streets[index];
    if (cached != null) return cached;
    final place = _streetPlace[index];
    final street = Street(
      id: index,
      name: _string(_streetName[index]),
      place: place == _noRef ? null : placeAt(place),
      lat: _streetLat[index] / 1e7,
      lon: _streetLon[index] / 1e7,
    );
    _streets[index] = street;
    return street;
  }

  PublicPlace publicPlaceAt(int index) {
    final cached = _publicPlaces[index];
    if (cached != null) return cached;
    final raw = _poiCategory[index];
    final place = _poiPlace[index];
    final poi = PublicPlace(
      id: index,
      name: _string(_poiName[index]),
      // A file built newer than this package may carry a category it does
      // not know — better a generic "attraction" than a crash.
      category: raw < PublicPlaceCategory.values.length
          ? PublicPlaceCategory.values[raw]
          : PublicPlaceCategory.attraction,
      place: place == _noRef ? null : placeAt(place),
      lat: _poiLat[index] / 1e7,
      lon: _poiLon[index] / 1e7,
    );
    _publicPlaces[index] = poi;
    return poi;
  }

  /// Every public place of the category — every airport, every station —
  /// by name. They are stored sorted by category, so this is one slice
  /// found by binary search.
  List<PublicPlace> publicPlacesOf(PublicPlaceCategory category) {
    int lowerBound(int code) {
      var low = 0;
      var high = publicPlaceCount;
      while (low < high) {
        final middle = (low + high) >> 1;
        if (_poiCategory[middle] < code) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      return low;
    }

    final from = lowerBound(category.index);
    final to = lowerBound(category.index + 1);
    return [for (var i = from; i < to; i++) publicPlaceAt(i)];
  }

  /// Public places around a point, nearest first; only of [categories] when
  /// given.
  List<PublicPlace> publicPlacesNear(
    double lat,
    double lon, {
    double radiusMeters = 500,
    int limit = 30,
    Set<PublicPlaceCategory>? categories,
  }) {
    final codes = categories?.map((category) => category.index).toSet();
    final found = <(double, int)>[];
    for (var i = 0; i < publicPlaceCount; i++) {
      if (codes != null && !codes.contains(_poiCategory[i])) continue;
      final distance =
          distanceMeters(lat, lon, _poiLat[i] / 1e7, _poiLon[i] / 1e7);
      if (distance <= radiusMeters) found.add((distance, i));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, index) in found.take(limit)) publicPlaceAt(index)];
  }

  String numberAt(int index) => utf8.decode(
        Uint8List.sublistView(
          _numberBytes,
          _numberOffset[index],
          _numberOffset[index + 1],
        ),
      );

  Address addressAt(int index) => Address(
        street: streetAt(_addressStreet[index]),
        number: numberAt(index),
        streetIsExact: (_streetExactBits[index >> 3] >> (index & 7)) & 1 == 1,
        lat: _addressLat[index] / 1e7,
        lon: _addressLon[index] / 1e7,
      );

  /// Every house on the street, in the order the database holds them.
  ///
  /// Houses are sorted by street at build time, so the ones asked for lie
  /// in one slice — its bounds are found by binary search, without a scan
  /// over seven thousand records.
  List<Address> housesOn(int streetId) {
    final from = _lowerBound(streetId);
    final to = _lowerBound(streetId + 1);
    return [for (var i = from; i < to; i++) addressAt(i)];
  }

  int _lowerBound(int streetId) {
    var low = 0;
    var high = addressCount;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_addressStreet[middle] < streetId) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// The nearest house to a point, within [maxMeters]. null if there is
  /// none.
  ///
  /// There is deliberately no spatial index: seven thousand points scan in
  /// a fraction of a millisecond, while a country-wide grid would outweigh
  /// the data itself.
  Address? nearestAddress(double lat, double lon, {double maxMeters = 200}) {
    var best = -1;
    var bestDistance = maxMeters;
    for (var i = 0; i < addressCount; i++) {
      final distance =
          distanceMeters(lat, lon, _addressLat[i] / 1e7, _addressLon[i] / 1e7);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best < 0 ? null : addressAt(best);
  }

  /// Houses around a point, nearest first.
  List<Address> addressesNear(
    double lat,
    double lon, {
    double radiusMeters = 200,
    int limit = 30,
  }) {
    final found = <(double, int)>[];
    for (var i = 0; i < addressCount; i++) {
      final distance =
          distanceMeters(lat, lon, _addressLat[i] / 1e7, _addressLon[i] / 1e7);
      if (distance <= radiusMeters) found.add((distance, i));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, index) in found.take(limit)) addressAt(index)];
  }

  /// Builds the search keys ahead of time.
  ///
  /// Otherwise the first [search] pays for them itself — thirty-odd
  /// milliseconds, two frames right under the first keystroke. Calling
  /// this straight after loading moves the delay somewhere nobody sees it.
  /// Calling it again is free.
  void warmUp() => _buildKeys();

  /// Searches settlements, streets and houses.
  ///
  /// Every word of the query must start some word in the entry, and their
  /// order does not matter: `par 2/4 1` finds `Parahat 2/4, 1`, and
  /// `gorogly 8 asgabat` finds house 8 on Görogly köçesi in Ashgabat.
  /// Matching from mid-word is not accepted: `rahat` will not find
  /// `Parahat`.
  ///
  /// Ranking: an exact prefix of the entry, then a match in the name
  /// versus a match in the settlement, then the weight of the entry
  /// (city → village → street → house), then shorter name before longer.
  List<SearchHit> search(String query, {int limit = 30}) {
    final needle = normalize(query);
    if (needle.isEmpty) return const [];
    final tokens = tokenize(needle);
    _buildKeys();

    final matches = <_Match>[];

    void scan(
      List<String> keys,
      Uint16List? nameLength,
      int Function(int) weightOf,
      int kind,
    ) {
      for (var i = 0; i < keys.length; i++) {
        final key = keys[i];
        final nameEnd = nameLength == null ? key.length : nameLength[i];
        var allInName = true;
        var matched = true;
        for (final token in tokens) {
          final at = wordPrefixAt(key, token);
          if (at < 0) {
            matched = false;
            break;
          }
          if (at >= nameEnd) allInName = false;
        }
        if (!matched) continue;
        final rank = key.startsWith(needle) ? 0 : (allInName ? 1 : 2);
        matches.add(_Match(kind, i, rank, weightOf(i), key.length));
      }
    }

    // Weight: a city (0) before a village (2), a village before a street
    // (10), a street before the two hundred houses on it (20).
    scan(_placeKeys!, null, (i) => _placeType[i], _kindPlace);
    scan(_streetKeys!, _streetNameKeyLength, (_) => 10, _kindStreet);
    scan(_addressKeys!, _addressNameKeyLength, (_) => 20, _kindAddress);

    matches.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      final byWeight = a.weight.compareTo(b.weight);
      if (byWeight != 0) return byWeight;
      return a.length.compareTo(b.length);
    });

    return [
      for (final match in matches.take(limit))
        switch (match.kind) {
          _kindPlace => PlaceHit(placeAt(match.index)),
          _kindStreet => StreetHit(streetAt(match.index)),
          _ => AddressHit(addressAt(match.index)),
        },
    ];
  }

  /// Searches public places by name: `howa menzili` finds the airports,
  /// `howa asgabat` the one in Ashgabat — the settlement is part of the
  /// key, as with streets.
  ///
  /// Kept apart from [search] so that its results stay what they were:
  /// a new kind of [SearchHit] would break every exhaustive `switch` over
  /// them. Show both lists, or merge them as your screen needs.
  ///
  /// Ranking as in [search]: an exact prefix, then a match in the name
  /// versus one in the settlement, then the category (an airport before a
  /// pharmacy, in [PublicPlaceCategory] order), then the shorter name.
  List<PublicPlace> searchPublicPlaces(
    String query, {
    int limit = 30,
    Set<PublicPlaceCategory>? categories,
  }) {
    final needle = normalize(query);
    if (needle.isEmpty) return const [];
    final tokens = tokenize(needle);
    _buildKeys();
    final keys = _poiKeys!;
    final nameLength = _poiNameKeyLength!;
    final codes = categories?.map((category) => category.index).toSet();

    final matches = <_Match>[];
    for (var i = 0; i < keys.length; i++) {
      if (codes != null && !codes.contains(_poiCategory[i])) continue;
      final key = keys[i];
      var allInName = true;
      var matched = true;
      for (final token in tokens) {
        final at = wordPrefixAt(key, token);
        if (at < 0) {
          matched = false;
          break;
        }
        if (at >= nameLength[i]) allInName = false;
      }
      if (!matched) continue;
      final rank = key.startsWith(needle) ? 0 : (allInName ? 1 : 2);
      matches.add(_Match(0, i, rank, _poiCategory[i], key.length));
    }
    matches.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      final byWeight = a.weight.compareTo(b.weight);
      if (byWeight != 0) return byWeight;
      return a.length.compareTo(b.length);
    });
    return [
      for (final match in matches.take(limit)) publicPlaceAt(match.index),
    ];
  }

  static const int _kindPlace = 0;
  static const int _kindStreet = 1;
  static const int _kindAddress = 2;

  /// Folds the names into search keys.
  ///
  /// A street's key carries its settlement too, so that `gorogly asgabat`
  /// tells the Ashgabat Görogly köçesi from the one in Mary. A house's key
  /// carries its street's key whole, so it gets the settlement for free.
  void _buildKeys() {
    if (_placeKeys != null) return;

    final places = List<String>.filled(placeCount, '');
    for (var i = 0; i < placeCount; i++) {
      places[i] = normalize(_string(_placeName[i]));
    }

    final streets = List<String>.filled(streetCount, '');
    final streetNameLength = Uint16List(streetCount);
    for (var i = 0; i < streetCount; i++) {
      final name = normalize(_string(_streetName[i]));
      streetNameLength[i] = math.min(name.length, 0xFFFF);
      final place = _streetPlace[i];
      streets[i] = place == _noRef ? name : '$name ${places[place]}';
    }

    final addresses = List<String>.filled(addressCount, '');
    final addressNameLength = Uint16List(addressCount);
    for (var i = 0; i < addressCount; i++) {
      final street = _addressStreet[i];
      final number = normalize(numberAt(i));
      // The number goes right after the street name and before the
      // settlement: it is as much part of a house's "name" as the street
      // is, while the settlement only narrows it down.
      final name = '${_nameOf(streets[street], streetNameLength[street])} '
          '$number';
      addressNameLength[i] = math.min(name.length, 0xFFFF);
      final place = _streetPlace[street];
      addresses[i] = place == _noRef ? name : '$name ${places[place]}';
    }

    final pois = List<String>.filled(publicPlaceCount, '');
    final poiNameLength = Uint16List(publicPlaceCount);
    for (var i = 0; i < publicPlaceCount; i++) {
      final name = normalize(_string(_poiName[i]));
      poiNameLength[i] = math.min(name.length, 0xFFFF);
      final place = _poiPlace[i];
      pois[i] = place == _noRef ? name : '$name ${places[place]}';
    }

    _poiKeys = pois;
    _poiNameKeyLength = poiNameLength;
    _placeKeys = places;
    _streetKeys = streets;
    _streetNameKeyLength = streetNameLength;
    _addressKeys = addresses;
    _addressNameKeyLength = addressNameLength;
  }

  static String _nameOf(String key, int nameLength) =>
      nameLength >= key.length ? key : key.substring(0, nameLength);
}

const double _earthRadiusMeters = 6371008.8;

/// Great-circle distance between two points.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = lat1 * math.pi / 180;
  final phi2 = lat2 * math.pi / 180;
  final dphi = phi2 - phi1;
  final dlambda = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dphi / 2), 2) +
      math.cos(phi1) * math.cos(phi2) * math.pow(math.sin(dlambda / 2), 2);
  return 2 * _earthRadiusMeters * math.asin(math.sqrt(a));
}

class _Match {
  const _Match(this.kind, this.index, this.rank, this.weight, this.length);
  final int kind;
  final int index;
  final int rank;
  final int weight;
  final int length;
}
