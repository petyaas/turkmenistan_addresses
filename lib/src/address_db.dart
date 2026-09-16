import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'address_search.dart';
import 'models.dart';

/// Адресная база Туркменистана: населённые пункты, улицы и дома.
///
/// Layout файла описан в `tool/address_db_format.py` — парная реализация,
/// правки нужны в обоих местах с подъёмом [formatVersion]. Загрузчик
/// отказывается читать чужую версию, а не разбирает мусор.
///
/// Данные лежат типизированными представлениями над одним буфером и не
/// копируются: строки собираются только тогда, когда их спросили.
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
        _places = List<Place?>.filled(placeLat.length, null),
        _streets = List<Street?>.filled(streetLat.length, null);

  static const int formatVersion = 1;

  /// 'TMAB', прочитанные как uint32 little-endian.
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
  static const int _sectionCount = 16;

  static const int _headerBytes = 32;

  /// Улица без населённого пункта: NO_REF в `address_db_format.py`.
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

  final List<Place?> _places;
  final List<Street?> _streets;

  // Ключи поиска считаются при первом запросе, а не при загрузке: тому,
  // кто открыл базу ради nearestAddress, платить за них незачем.
  List<String>? _placeKeys;
  List<String>? _streetKeys;
  Uint16List? _streetNameKeyLength;
  List<String>? _addressKeys;
  Uint16List? _addressNameKeyLength;

  int get placeCount => _placeLat.length;
  int get streetCount => _streetLat.length;
  int get addressCount => _addressLat.length;

  /// Разбирает содержимое `.adb`.
  factory AddressDatabase.parse(Uint8List bytes) {
    var source = bytes;
    // Представления над буфером требуют выравнивания на 4 байта, а
    // rootBundle отдаёт срез общего буфера с произвольным смещением.
    if (source.offsetInBytes % 4 != 0) {
      source = Uint8List.fromList(source);
    }
    final buffer = source.buffer;
    final base = source.offsetInBytes;

    if (source.length < _headerBytes + _sectionCount * 8) {
      throw const FormatException('адресная база обрезана');
    }

    final header = ByteData.view(buffer, base, _headerBytes);
    if (header.getUint32(0, Endian.little) != _magic) {
      throw const FormatException('это не адресная база');
    }
    final version = header.getUint32(4, Endian.little);
    if (version != formatVersion) {
      throw FormatException(
        'адресная база версии $version, пакет ожидает $formatVersion — '
        'пересоберите ассет через tool/build_address_db.py',
      );
    }

    final table = ByteData.view(buffer, base + _headerBytes, _sectionCount * 8);
    int start(int index) => table.getUint32(index * 8, Endian.little);
    int length(int index) => table.getUint32(index * 8 + 4, Endian.little);

    Int32List int32(int section) =>
        Int32List.view(buffer, base + start(section), length(section) ~/ 4);
    Uint32List uint32(int section) =>
        Uint32List.view(buffer, base + start(section), length(section) ~/ 4);
    Uint8List uint8(int section) =>
        Uint8List.view(buffer, base + start(section), length(section));

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
      // Значение из файла может опередить пакет, если база собрана новее —
      // лучше показать местностью, чем упасть на неизвестном типе.
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

  /// Все дома на улице, в том порядке, в каком они лежат в базе.
  ///
  /// Дома отсортированы по улице ещё при сборке, поэтому нужные лежат
  /// одним куском — его границы находятся двоичным поиском, без перебора
  /// семи тысяч записей.
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

  /// Ближайший дом к точке, не дальше [maxMeters]. null, если такого нет.
  ///
  /// Пространственного индекса нет намеренно: семь тысяч точек
  /// перебираются за доли миллисекунды, а сетка на всю страну заняла бы
  /// больше самих данных.
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

  /// Дома вокруг точки, ближние первыми.
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

  /// Считает ключи поиска заранее.
  ///
  /// Первый [search] иначе платит за них сам — тридцать с лишним
  /// миллисекунд, то есть два кадра прямо под первым нажатием. Вызов
  /// сразу после загрузки убирает эту задержку туда, где её никто не
  /// видит. Повторный вызов бесплатен.
  void warmUp() => _buildKeys();

  /// Ищет по населённым пунктам, улицам и домам.
  ///
  /// Каждое слово запроса должно быть началом какого-нибудь слова в
  /// записи, порядок не важен: «par 2/4 1» находит «Parahat 2/4, 1», а
  /// «gorogly 8 asgabat» — дом 8 по Görogly köçesi в Ашхабаде. Совпадение
  /// с середины слова не принимается: «rahat» не найдёт «Parahat».
  ///
  /// Порядок выдачи: точное начало записи, затем совпадение в названии
  /// против совпадения в городе, затем вес записи (город → село → улица →
  /// дом), затем короткое название вперёд длинного.
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

    // Вес: город (0) впереди села (2), село впереди улицы (10), улица
    // впереди двухсот домов на ней (20).
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

  static const int _kindPlace = 0;
  static const int _kindStreet = 1;
  static const int _kindAddress = 2;

  /// Свёртывает названия в ключи поиска.
  ///
  /// Ключ улицы несёт и её город, чтобы «gorogly asgabat» отделяло
  /// ашхабадскую Görogly köçesi от марыйской, а ключ дома — ключ его
  /// улицы целиком, поэтому город достаётся дому даром.
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
      // Номер идёт сразу за названием улицы и до города: он такая же
      // часть «названия» дома, как и улица, а вот город — уточнение.
      final name = '${_nameOf(streets[street], streetNameLength[street])} '
          '$number';
      addressNameLength[i] = math.min(name.length, 0xFFFF);
      final place = _streetPlace[street];
      addresses[i] = place == _noRef ? name : '$name ${places[place]}';
    }

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

/// Расстояние между двумя точками по большому кругу.
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
