import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:turkmenistan_addresses/turkmenistan_addresses.dart';

/// Тесты читают ассет с диска напрямую: rootBundle требует поднятого
/// биндинга, а проверять тут нужно данные и разбор, а не Flutter.
late final AddressDatabase db;

void main() {
  setUpAll(() {
    final bytes = File('assets/turkmenistan.adb').readAsBytesSync();
    db = AddressDatabase.parse(bytes);
  });

  group('формат', () {
    test('база разбирается и не пуста', () {
      expect(db.placeCount, greaterThan(1000));
      expect(db.streetCount, greaterThan(3000));
      expect(db.addressCount, greaterThan(6000));
    });

    test('чужой файл отвергается, а не читается как мусор', () {
      expect(
        () => AddressDatabase.parse(Uint8List(200)),
        throwsA(isA<FormatException>()),
      );
    });

    test('обрезанный файл отвергается', () {
      final bytes = File('assets/turkmenistan.adb').readAsBytesSync();
      expect(
        () => AddressDatabase.parse(Uint8List.sublistView(bytes, 0, 100)),
        throwsA(isA<FormatException>()),
      );
    });

    test('версия формата проверяется', () {
      final bytes =
          Uint8List.fromList(File('assets/turkmenistan.adb').readAsBytesSync());
      ByteData.view(bytes.buffer).setUint32(4, 99, Endian.little);
      expect(
        () => AddressDatabase.parse(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'сообщение',
            allOf(contains('99'), contains('build_address_db.py')),
          ),
        ),
      );
    });

    test('невыровненный срез читается', () {
      // rootBundle отдаёт вид на общий буфер с произвольным смещением.
      final bytes = File('assets/turkmenistan.adb').readAsBytesSync();
      final shifted = Uint8List(bytes.length + 1)..setRange(1, bytes.length + 1, bytes);
      final copy = AddressDatabase.parse(Uint8List.sublistView(shifted, 1));
      expect(copy.addressCount, db.addressCount);
    });
  });

  group('целостность данных', () {
    test('каждый дом ссылается на существующую улицу', () {
      for (var i = 0; i < db.addressCount; i++) {
        final address = db.addressAt(i);
        expect(address.street.id, inInclusiveRange(0, db.streetCount - 1));
        expect(address.street.name, isNotEmpty);
        expect(address.number, isNotEmpty);
      }
    });

    test('в номере дома всегда есть цифра', () {
      // «?», «&» и «Gül Zemin» отсеиваются при сборке: подписать ими дом
      // нельзя, а искать по ним нечего.
      final digit = RegExp(r'\d');
      for (var i = 0; i < db.addressCount; i++) {
        expect(digit.hasMatch(db.numberAt(i)), isTrue,
            reason: 'номер «${db.numberAt(i)}» без цифры');
      }
    });

    test('всё лежит внутри страны', () {
      // Экстракт захватывает объекты за границей — в базе по Туркменистану
      // Махачкале и Астрахани делать нечего.
      for (var i = 0; i < db.addressCount; i++) {
        final address = db.addressAt(i);
        expect(address.lat, inInclusiveRange(35.0, 43.0));
        expect(address.lon, inInclusiveRange(51.0, 67.0));
      }
    });

    test('у подавляющего большинства улиц есть населённый пункт', () {
      var without = 0;
      for (var i = 0; i < db.streetCount; i++) {
        if (db.streetAt(i).place == null) without++;
      }
      // Остаются трассы и пустынные дороги: ближайшего города нет на
      // десятки километров.
      expect(without, lessThan(db.streetCount ~/ 100));
    });

    test('дублей дома не осталось', () {
      // Дом сплошь и рядом размечен дважды — контуром здания и адресной
      // точкой внутри него. Один и тот же номер на одной улице в двадцати
      // пяти метрах — это он же.
      final seen = <int, List<Address>>{};
      for (var i = 0; i < db.addressCount; i++) {
        final address = db.addressAt(i);
        for (final other in seen[address.street.id] ?? const <Address>[]) {
          if (other.number != address.number) continue;
          final apart = distanceMeters(
              address.lat, address.lon, other.lat, other.lon);
          expect(apart, greaterThan(25),
              reason: 'два «${address.number}» на ${address.street.name} '
                  'в ${apart.round()} м');
        }
        (seen[address.street.id] ??= []).add(address);
      }
    });

    test('одинаковые номера разных домов сохранены', () {
      // Обратная опасность: тайлы схлопывали все дома с одним номером в
      // пределах тайла, и в Parahat 4 из 306 адресов осталось 126.
      final numbers = <String>{};
      var repeated = 0;
      for (var i = 0; i < db.addressCount; i++) {
        if (!numbers.add(db.numberAt(i))) repeated++;
      }
      expect(repeated, greaterThan(db.addressCount ~/ 2));
    });
  });

  group('поиск', () {
    test('слова ищутся с начала, в любом порядке', () {
      // Требовать запятую и точное написание нельзя: набирают по памяти.
      final hits = db.search('par 2/4 1');
      expect(hits.first, isA<AddressHit>());
      expect(hits.first.title, 'Parahat 2/4, 1');
      expect(hits.first.place?.name, 'Aşgabat');
    });

    test('совпадение с середины слова не принимается', () {
      // Иначе выдача заполняется случайными попаданиями.
      final hits = db.search('rahat');
      expect(hits.where((hit) => hit.title.contains('Parahat')), isEmpty);
    });

    test('диакритика свёрнута', () {
      // ä, ç, ň, ö, ş, ü, ý на клавиатуре никто набирать не станет.
      final hits = db.search('gorogly');
      expect(hits.any((hit) => hit.title.startsWith('Görogly')), isTrue);
    });

    test('город отделяет одноимённые улицы', () {
      final all = db.search('gorogly kocesi', limit: 100);
      final cities = {
        for (final hit in all)
          if (hit is StreetHit) hit.place?.name,
      };
      expect(cities.length, greaterThan(3), reason: 'улица есть в разных сёлах');

      final narrowed = db.search('gorogly kocesi gyzylarbat');
      expect(narrowed.first, isA<StreetHit>());
      expect(narrowed.first.place?.name, 'Gyzylarbat');
    });

    test('населённый пункт впереди улиц и домов', () {
      // Поездка в другой город — самый частый длинный маршрут, и «Mary»
      // не должно тонуть в домах на улице Мары.
      final hits = db.search('mary');
      expect(hits.first, isA<PlaceHit>());
      expect(hits.first.title, 'Mary');
    });

    test('улица впереди домов на ней, а место впереди улицы', () {
      // «Parahat 4» в OSM — сразу три вещи: микрорайон, улица и полсотни
      // домов на ней. Выдача обязана идти именно в этом порядке: улица
      // полезнее любого отдельного дома, а микрорайон — улицы.
      final hits = db.search('parahat 4', limit: 100);
      final place = hits.indexWhere((hit) => hit is PlaceHit);
      final street = hits.indexWhere((hit) => hit is StreetHit);
      final house = hits.indexWhere((hit) => hit is AddressHit);
      expect(place, isNonNegative);
      expect(street, greaterThan(place));
      expect(house, greaterThan(street));
      expect(hits[street].title, 'Parahat 4');
    });

    test('пустой запрос не ищет', () {
      expect(db.search(''), isEmpty);
      expect(db.search('   ,.  '), isEmpty);
    });

    test('лимит соблюдается', () {
      expect(db.search('a', limit: 5).length, 5);
    });

    test('ничего не находится на заведомой чепухе', () {
      expect(db.search('zzzqqq'), isEmpty);
    });

    test('запрос укладывается в кадр', () {
      db.search('прогрев'); // ключи считаются при первом запросе
      final started = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        db.search('par 2/4 1');
      }
      final perQuery = started.elapsedMicroseconds / 20 / 1000;
      expect(perQuery, lessThan(16),
          reason: 'запрос ${perQuery.toStringAsFixed(1)} мс — дороже кадра');
    });
  });

  group('геометрия', () {
    test('дома на улице лежат одним куском', () {
      final street = db.search('parahat 2/4').whereType<StreetHit>().first.value;
      final houses = db.housesOn(street.id);
      expect(houses, isNotEmpty);
      expect(houses.every((house) => house.street.id == street.id), isTrue);

      var total = 0;
      for (var i = 0; i < db.addressCount; i++) {
        if (db.addressAt(i).street.id == street.id) total++;
      }
      expect(houses.length, total, reason: 'двоичный поиск потерял дома');
    });

    test('дома на улице идут по номеру, а не по строке', () {
      // По строке «48» встаёт между «4» и «5», а «10» сразу за «1» —
      // список домов читают глазами, и такой порядок в нём выглядит
      // поломкой.
      final street = db.search('parahat 2/4').whereType<StreetHit>().first.value;
      final numbers = db.housesOn(street.id).map((house) => house.number);
      final plain = numbers.where((number) => int.tryParse(number) != null);
      final asNumbers = plain.map(int.parse).toList();
      expect(asNumbers, List.of(asNumbers)..sort());
      expect(asNumbers.length, greaterThan(5));
    });

    test('у несуществующей улицы домов нет', () {
      expect(db.housesOn(db.streetCount + 10), isEmpty);
    });

    test('ближайший дом к самому дому — он сам', () {
      final address = db.addressAt(db.addressCount ~/ 2);
      final nearest = db.nearestAddress(address.lat, address.lon);
      expect(nearest, isNotNull);
      expect(nearest!.number, address.number);
      expect(nearest.street.id, address.street.id);
    });

    test('в пустыне домов нет', () {
      expect(db.nearestAddress(40.5, 58.0), isNull);
    });

    test('дома вокруг точки идут ближними вперёд', () {
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

  group('происхождение улицы', () {
    test('помечено, откуда взялась улица', () {
      var exact = 0;
      for (var i = 0; i < db.addressCount; i++) {
        if (db.addressAt(i).streetIsExact) exact++;
      }
      // addr:street есть не у всех домов; остальным улица подобрана по
      // ближайшей дороге, и вызывающий обязан уметь их различить.
      expect(exact, greaterThan(db.addressCount ~/ 2));
      expect(exact, lessThan(db.addressCount));
    });
  });

  group('нормализация', () {
    test('совпадает с эталоном из address_db_format.py', () {
      // Эти пары посчитаны питоновской search_key: разойдутся — набранный
      // текст перестанет встречаться с названиями, молча и целиком.
      expect(normalize('Görogly (2009) köçesi'), 'gorogly 2009 kocesi');
      expect(normalize('Parahat 2/4, 1'), 'parahat 2/4 1');
      expect(normalize('12-а'), '12-а');
      expect(normalize('Şaja Batyrow'), 'saja batyrow');
      expect(normalize('  Ýolöten   '), 'yoloten');
      expect(normalize('Ёлка'), 'елка');
    });

    test('дробь и дефис остаются — это часть номера дома', () {
      expect(normalize('2/4'), '2/4');
      expect(normalize('12-a'), '12-a');
    });
  });
}
