import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:turkmenistan_addresses/turkmenistan_addresses.dart';

/// The tests read the asset straight from disk: rootBundle needs a live
/// binding, and what matters here is the data and the parsing, not Flutter.
late final AddressDatabase db;

void main() {
  setUpAll(() {
    final bytes = File('assets/turkmenistan.adb').readAsBytesSync();
    db = AddressDatabase.parse(bytes);
  });

  group('format', () {
    test('the database parses and is not empty', () {
      expect(db.placeCount, greaterThan(1000));
      expect(db.streetCount, greaterThan(3000));
      expect(db.addressCount, greaterThan(6000));
    });

    test('a foreign file is refused, not read as garbage', () {
      expect(
        () => AddressDatabase.parse(Uint8List(200)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a truncated file is refused', () {
      final bytes = File('assets/turkmenistan.adb').readAsBytesSync();
      expect(
        () => AddressDatabase.parse(Uint8List.sublistView(bytes, 0, 100)),
        throwsA(isA<FormatException>()),
      );
    });

    test('the format version is checked', () {
      final bytes =
          Uint8List.fromList(File('assets/turkmenistan.adb').readAsBytesSync());
      ByteData.view(bytes.buffer).setUint32(4, 99, Endian.little);
      expect(
        () => AddressDatabase.parse(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('99'), contains('build_address_db.py')),
          ),
        ),
      );
    });

    test('an unaligned slice is readable', () {
      // rootBundle hands back a view on a shared buffer at an arbitrary
      // offset.
      final bytes = File('assets/turkmenistan.adb').readAsBytesSync();
      final shifted = Uint8List(bytes.length + 1)..setRange(1, bytes.length + 1, bytes);
      final copy = AddressDatabase.parse(Uint8List.sublistView(shifted, 1));
      expect(copy.addressCount, db.addressCount);
    });
  });

  group('data integrity', () {
    test('every house points at a street that exists', () {
      for (var i = 0; i < db.addressCount; i++) {
        final address = db.addressAt(i);
        expect(address.street.id, inInclusiveRange(0, db.streetCount - 1));
        expect(address.street.name, isNotEmpty);
        expect(address.number, isNotEmpty);
      }
    });

    test('a house number always contains a digit', () {
      // "?", "&" and "Gül Zemin" are filtered out at build time: they
      // cannot label a house and there is nothing to search for in them.
      final digit = RegExp(r'\d');
      for (var i = 0; i < db.addressCount; i++) {
        expect(digit.hasMatch(db.numberAt(i)), isTrue,
            reason: 'the number "${db.numberAt(i)}" has no digit');
      }
    });

    test('everything lies inside the country', () {
      // The extract reaches across the border, and Makhachkala has no
      // business in a database of Turkmenistan.
      for (var i = 0; i < db.addressCount; i++) {
        final address = db.addressAt(i);
        expect(address.lat, inInclusiveRange(35.0, 43.0));
        expect(address.lon, inInclusiveRange(51.0, 67.0));
      }
    });

    test('the vast majority of streets have a settlement', () {
      var without = 0;
      for (var i = 0; i < db.streetCount; i++) {
        if (db.streetAt(i).place == null) without++;
      }
      // What is left are highways and desert roads: the nearest town is
      // tens of kilometres away.
      expect(without, lessThan(db.streetCount ~/ 100));
    });

    test('no duplicate houses are left', () {
      // A house is routinely mapped twice - as a building outline and as
      // an address node inside it. The same number on the same street
      // within twenty-five metres is the same house.
      final seen = <int, List<Address>>{};
      for (var i = 0; i < db.addressCount; i++) {
        final address = db.addressAt(i);
        for (final other in seen[address.street.id] ?? const <Address>[]) {
          if (other.number != address.number) continue;
          final apart = distanceMeters(
              address.lat, address.lon, other.lat, other.lon);
          expect(apart, greaterThan(25),
              reason: 'two "${address.number}" on ${address.street.name} '
                  '${apart.round()} m apart');
        }
        (seen[address.street.id] ??= []).add(address);
      }
    });

    test('identical numbers on different houses are kept', () {
      // The opposite hazard: collapsing every house that shares a number
      // is what loses half the addresses in a district.
      final numbers = <String>{};
      var repeated = 0;
      for (var i = 0; i < db.addressCount; i++) {
        if (!numbers.add(db.numberAt(i))) repeated++;
      }
      expect(repeated, greaterThan(db.addressCount ~/ 2));
    });
  });

  group('search', () {
    test('words match from their start, in any order', () {
      // Demanding the comma and the exact spelling is no good: people type
      // from memory.
      final hits = db.search('par 2/4 1');
      expect(hits.first, isA<AddressHit>());
      expect(hits.first.title, 'Parahat 2/4, 1');
      expect(hits.first.place?.name, 'Aşgabat');
    });

    test('a match from mid-word is not accepted', () {
      // Otherwise the results fill up with accidental hits.
      final hits = db.search('rahat');
      expect(hits.where((hit) => hit.title.contains('Parahat')), isEmpty);
    });

    test('diacritics are folded', () {
      // Nobody is going to type ä, ç, ň, ö, ş, ü, ý on a keyboard.
      final hits = db.search('gorogly');
      expect(hits.any((hit) => hit.title.startsWith('Görogly')), isTrue);
    });

    test('the settlement separates streets of the same name', () {
      final all = db.search('gorogly kocesi', limit: 100);
      final cities = {
        for (final hit in all)
          if (hit is StreetHit) hit.place?.name,
      };
      expect(cities.length, greaterThan(3),
          reason: 'the street exists in several settlements');

      final narrowed = db.search('gorogly kocesi gyzylarbat');
      expect(narrowed.first, isA<StreetHit>());
      expect(narrowed.first.place?.name, 'Gyzylarbat');
    });

    test('a settlement comes before streets and houses', () {
      // Driving to another town is the commonest long trip, and "Mary"
      // must not drown in houses on a street named Mary.
      final hits = db.search('mary');
      expect(hits.first, isA<PlaceHit>());
      expect(hits.first.title, 'Mary');
    });

    test('a street comes before its houses, a place before the street', () {
      // "Parahat 4" is three things in OSM at once: a neighbourhood, a
      // street and fifty houses on it. The results have to come in that
      // order: a street is more useful than any single house, and a
      // neighbourhood more than the street.
      final hits = db.search('parahat 4', limit: 100);
      final place = hits.indexWhere((hit) => hit is PlaceHit);
      final street = hits.indexWhere((hit) => hit is StreetHit);
      final house = hits.indexWhere((hit) => hit is AddressHit);
      expect(place, isNonNegative);
      expect(street, greaterThan(place));
      expect(house, greaterThan(street));
      expect(hits[street].title, 'Parahat 4');
    });

    test('an empty query searches nothing', () {
      expect(db.search(''), isEmpty);
      expect(db.search('   ,.  '), isEmpty);
    });

    test('the limit is respected', () {
      expect(db.search('a', limit: 5).length, 5);
    });

    test('obvious nonsense finds nothing', () {
      expect(db.search('zzzqqq'), isEmpty);
    });

    test('a query fits inside one frame', () {
      db.search('warm up'); // the keys are built on the first query
      final started = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        db.search('par 2/4 1');
      }
      final perQuery = started.elapsedMicroseconds / 20 / 1000;
      expect(perQuery, lessThan(16),
          reason: 'a query takes ${perQuery.toStringAsFixed(1)} ms — '
              'more than a frame');
    });
  });

  group('geometry', () {
    test('the houses on a street lie in one slice', () {
      final street = db.search('parahat 2/4').whereType<StreetHit>().first.value;
      final houses = db.housesOn(street.id);
      expect(houses, isNotEmpty);
      expect(houses.every((house) => house.street.id == street.id), isTrue);

      var total = 0;
      for (var i = 0; i < db.addressCount; i++) {
        if (db.addressAt(i).street.id == street.id) total++;
      }
      expect(houses.length, total,
          reason: 'the binary search lost some houses');
    });

    test('houses on a street are ordered by number, not by string', () {
      // By string "48" falls between "4" and "5", and "10" right after
      // "1" — the list is read by eye, and that order looks like a bug
      // in it.
      final street = db.search('parahat 2/4').whereType<StreetHit>().first.value;
      final numbers = db.housesOn(street.id).map((house) => house.number);
      final plain = numbers.where((number) => int.tryParse(number) != null);
      final asNumbers = plain.map(int.parse).toList();
      expect(asNumbers, List.of(asNumbers)..sort());
      expect(asNumbers.length, greaterThan(5));
    });

    test('a street that does not exist has no houses', () {
      expect(db.housesOn(db.streetCount + 10), isEmpty);
    });

    test('the nearest house to a house is itself', () {
      final address = db.addressAt(db.addressCount ~/ 2);
      final nearest = db.nearestAddress(address.lat, address.lon);
      expect(nearest, isNotNull);
      expect(nearest!.number, address.number);
      expect(nearest.street.id, address.street.id);
    });

    test('there are no houses in the desert', () {
      expect(db.nearestAddress(40.5, 58.0), isNull);
    });

    test('houses around a point come nearest first', () {
      final address = db.addressAt(db.addressCount ~/ 2);
      final near = db.addressesNear(address.lat, address.lon,
          radiusMeters: 500, limit: 10);
      expect(near.length, greaterThan(1));
      var previous = -1.0;
      for (final house in near) {
        final distance =
            distanceMeters(address.lat, address.lon, house.lat, house.lon);
        expect(distance, greaterThanOrEqualTo(previous));
        expect(distance, lessThanOrEqualTo(500));
        previous = distance;
      }
    });
  });

  group('where the street came from', () {
    test('the origin of the street is recorded', () {
      var exact = 0;
      for (var i = 0; i < db.addressCount; i++) {
        if (db.addressAt(i).streetIsExact) exact++;
      }
      // Not every house carries addr:street; the rest had their street
      // inferred from the nearest road, and the caller must be able to
      // tell the two apart.
      expect(exact, greaterThan(db.addressCount ~/ 2));
      expect(exact, lessThan(db.addressCount));
    });
  });

  group('normalization', () {
    test('matches the reference from address_db_format.py', () {
      // These pairs were produced by the Python search_key: let them drift
      // apart and typed text stops meeting the names, silently and
      // completely.
      expect(normalize('Görogly (2009) köçesi'), 'gorogly 2009 kocesi');
      expect(normalize('Parahat 2/4, 1'), 'parahat 2/4 1');
      expect(normalize('12-а'), '12-а');
      expect(normalize('Şaja Batyrow'), 'saja batyrow');
      expect(normalize('  Ýolöten   '), 'yoloten');
      expect(normalize('Ёлка'), 'елка');
    });

    test('the slash and the hyphen survive — they are part of a number', () {
      expect(normalize('2/4'), '2/4');
      expect(normalize('12-a'), '12-a');
    });
  });
}
