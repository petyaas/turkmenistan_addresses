/// Тип населённого пункта. Порядок задаёт вес в выдаче и обязан совпадать
/// с PLACE_* в `tool/address_db_format.py`: город важнее села, село важнее
/// безымянной местности.
enum PlaceType {
  city,
  town,
  village,
  suburb,
  neighbourhood,
  hamlet,
  locality,
}

/// Населённый пункт: город, село, посёлок, микрорайон.
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.type,
    required this.lat,
    required this.lon,
  });

  /// Позиция в базе. Постоянна для собранного файла и меняется при
  /// пересборке — хранить её на диске нельзя, а сравнивать и передавать
  /// обратно в базу можно.
  final int id;

  final String name;
  final PlaceType type;
  final double lat;
  final double lon;

  @override
  String toString() => name;
}

/// Улица. Одноимённые улицы в разных городах — это разные [Street]:
/// в базе они разведены по расстоянию, иначе адрес уводит в другой город.
class Street {
  const Street({
    required this.id,
    required this.name,
    required this.place,
    required this.lat,
    required this.lon,
  });

  /// Позиция в базе: её принимает [AddressDatabase.housesOn].
  final int id;

  final String name;

  /// Город или село, в котором лежит улица. null у трасс и пустынных
  /// дорог — ближайшего населённого пункта там нет на десятки километров.
  final Place? place;

  /// Середина улицы, а не её начало.
  final double lat;
  final double lon;

  @override
  String toString() => place == null ? name : '$name, ${place!.name}';
}

/// Дом с номером.
class Address {
  const Address({
    required this.street,
    required this.number,
    required this.streetIsExact,
    required this.lat,
    required this.lon,
  });

  final Street street;

  /// Номер как он записан в OSM: «12», «2/4», «111(A)», «1A».
  final String number;

  /// Улица взята из тега `addr:street` дома (true) или подобрана по
  /// ближайшей дороге (false).
  ///
  /// Тег есть у 76% домов. Остальным улица определена геометрически и
  /// может быть не той — показывать адрес можно, а вот утверждать, что
  /// так записано в OSM, нельзя.
  final bool streetIsExact;

  final double lat;
  final double lon;

  Place? get place => street.place;

  @override
  String toString() => '${street.name}, $number';
}

/// Строка выдачи. Разбирается через `switch`:
///
/// ```dart
/// switch (hit) {
///   case PlaceHit(:final place): ...
///   case StreetHit(:final street): ...
///   case AddressHit(:final address): ...
/// }
/// ```
sealed class SearchHit {
  const SearchHit();

  /// Что показать строкой: «Aşgabat», «Görogly köçesi», «Görogly köçesi, 8».
  String get title;

  /// Населённый пункт, к которому относится находка. У самого населённого
  /// пункта — он сам.
  Place? get place;

  double get lat;
  double get lon;
}

class PlaceHit extends SearchHit {
  const PlaceHit(this.value);

  final Place value;

  @override
  String get title => value.name;
  @override
  Place? get place => value;
  @override
  double get lat => value.lat;
  @override
  double get lon => value.lon;
}

class StreetHit extends SearchHit {
  const StreetHit(this.value);

  final Street value;

  @override
  String get title => value.name;
  @override
  Place? get place => value.place;
  @override
  double get lat => value.lat;
  @override
  double get lon => value.lon;
}

class AddressHit extends SearchHit {
  const AddressHit(this.value);

  final Address value;

  @override
  String get title => '${value.street.name}, ${value.number}';
  @override
  Place? get place => value.place;
  @override
  double get lat => value.lat;
  @override
  double get lon => value.lon;
}
