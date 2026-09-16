/// The kind of a settlement. The order sets its weight in the results and
/// must match PLACE_* in `tool/address_db_format.py`: a city outranks a
/// village, a village outranks a nameless locality.
enum PlaceType {
  city,
  town,
  village,
  suburb,
  neighbourhood,
  hamlet,
  locality,
}

/// A settlement: a city, a village, a neighbourhood.
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.type,
    required this.lat,
    required this.lon,
  });

  /// Position in the database. Stable for a given file and different after
  /// a rebuild — so it must not be persisted, but it can be compared and
  /// handed back to the database.
  final int id;

  final String name;
  final PlaceType type;
  final double lat;
  final double lon;

  @override
  String toString() => name;
}

/// A street. Streets of the same name in different towns are separate
/// [Street]s: the database keeps them apart by distance, otherwise an
/// address sends you to the wrong town.
class Street {
  const Street({
    required this.id,
    required this.name,
    required this.place,
    required this.lat,
    required this.lon,
  });

  /// Position in the database; [AddressDatabase.housesOn] takes it.
  final int id;

  final String name;

  /// The city or village the street lies in. null for highways and desert
  /// roads — there is no settlement within tens of kilometres.
  final Place? place;

  /// The middle of the street, not its start.
  final double lat;
  final double lon;

  @override
  String toString() => place == null ? name : '$name, ${place!.name}';
}

/// A numbered house.
class Address {
  const Address({
    required this.street,
    required this.number,
    required this.streetIsExact,
    required this.lat,
    required this.lon,
  });

  final Street street;

  /// The number as OSM records it: "12", "2/4", "111(A)", "1A".
  final String number;

  /// Whether the street came from the house's own `addr:street` tag (true)
  /// or was inferred from the nearest road (false).
  ///
  /// The tag is present on 76% of houses. The rest had their street
  /// determined geometrically and it may be the wrong one — fine to show
  /// either way, not fine to claim OSM says so.
  final bool streetIsExact;

  final double lat;
  final double lon;

  Place? get place => street.place;

  @override
  String toString() => '${street.name}, $number';
}

/// A row of results. Destructure it with `switch`:
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

  /// What to show as the line: "Aşgabat", "Görogly köçesi",
  /// "Görogly köçesi, 8".
  String get title;

  /// The settlement this hit belongs to. For a settlement, itself.
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
