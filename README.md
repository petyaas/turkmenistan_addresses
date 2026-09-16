# turkmenistan_addresses

**English** · [Русский](README.ru.md)

[![pub package](https://img.shields.io/pub/v/turkmenistan_addresses.svg)](https://pub.dev/packages/turkmenistan_addresses)

Offline address search for Turkmenistan: 2,039 settlements (52 of them
cities), 3,555 streets and 6,993 houses. The database is built from
OpenStreetMap and ships inside the package — no network is used at load
time or at query time.

The asset is **292 KB**.

## Usage

```dart
import 'package:turkmenistan_addresses/turkmenistan_addresses.dart';

final db = await loadTurkmenistanAddresses();
db.warmUp(); // optional; moves 30 ms off the first query

for (final hit in db.search('par 2/4 1')) {
  print('${hit.title} — ${hit.place?.name}  ${hit.lat}, ${hit.lon}');
}
// Parahat 2/4, 1 — Aşgabat  37.8981436, 58.385109
```

A result is destructured by kind:

```dart
switch (hit) {
  case PlaceHit(:final value):   // city, village, neighbourhood
    print('${value.name}, ${value.type}');
  case StreetHit(:final value):  // street
    print(db.housesOn(value.id).length);
  case AddressHit(:final value): // house
    print('${value.street.name}, ${value.number}');
}
```

There is also `nearestAddress(lat, lon)`, `addressesNear(lat, lon)` and
`housesOn(streetId)`.

A working example lives in `example/`: search as you type, the list of
houses on a street, and a house card showing where its street came from.

```bash
cd example && flutter run
```

## How the search works

Every word of the query must be **the start of some word** in the entry,
and their order does not matter. That is why `par 2/4 1` finds
`Parahat 2/4, 1`: demanding the comma and the exact spelling is no good
when people type from memory, on the move.

Matching from mid-word is rejected on purpose — `rahat` will not find
`Parahat`, or the results fill up with accidental hits.

Diacritics are folded: Turkmen names use ä, ç, ň, ö, ş, ü, ý and nobody
is going to type them, so `gorogly` finds `Görogly köçesi`. The slash and
the hyphen survive folding — they are part of house numbers: `2/4`,
`12-а`.

A street's search key carries its settlement, so
`gorogly kocesi gyzylarbat` separates one `Görogly köçesi` from the nine
others in different towns and villages.

Ranking, in order: an exact prefix of the whole entry → a match in the
name versus a match in the settlement → the weight of the entry (city →
village → street → house) → shorter name before longer. That is why
`mary` gives you the city of Mary first, not houses on a street named
Mary in Ashgabat.

There is deliberately no spatial or prefix index: with thirteen thousand
entries a full scan takes about a millisecond — less than one frame.
Loading copies nothing; the sections stay views over the asset's buffer.

Measured under `flutter test` (JIT; release is faster):

| | |
|---|---|
| parsing the file | 4 ms |
| first query (builds the keys) | 33 ms, removed by `warmUp()` |
| query | 0.8–1.4 ms |
| `nearestAddress` | 0.2 ms |

## What to expect from the data

The data is OSM, with everything that implies.

**For 24% of houses the street was inferred, not recorded.**
`addr:street` is present on 5,327 houses out of 6,993; the rest got their
street from the nearest road within 150 m. The flag is
`Address.streetIsExact` — showing the address is fine either way, but
claiming that OSM says so is only fine in the first case.

**Houses whose street could not be determined were dropped** — 416 of
them. A bare number is unsearchable: "house 12" exists in every block.

**The country has far more houses than this.** The extract holds 160,149
buildings and 95% of them carry no `addr:housenumber` at all. No amount
of processing will show a number that is not in OSM.

**Identical numbers on different houses are kept** — they are more than
half the database. Collapsing them would be wrong: Parahat 4 has seven
different buildings numbered "2". What *is* collapsed is a single house
mapped twice — a building outline plus an address node inside it —
otherwise every such house appears in the results twice.

## Rebuilding

The finished database is in `assets/`; you only need to rebuild it to
pick up fresher OSM data. You will need a Turkmenistan extract in `.pbf`
format (from [download.geofabrik.de](https://download.geofabrik.de/asia/turkmenistan.html),
for instance). It is not kept in the repository: 23 MB of input against
292 KB of output.

```bash
python3 -m venv tool/.venv && tool/.venv/bin/pip install osmium   # once
tool/.venv/bin/python tool/build_address_db.py turkmenistan.pbf \
    assets/turkmenistan.adb
```

The build takes about twelve seconds and prints exactly what it dropped
and why.

The format is described in `tool/address_db_format.py`;
`lib/src/address_db.dart` is a paired implementation of the same layout.
**Change one and you must change the other**, raising `FORMAT_VERSION` /
`AddressDatabase.formatVersion` together: the loader refuses a version it
does not know rather than reading garbage. The same goes for diacritic
folding and the kept-punctuation set — let them drift apart and typed
text stops meeting the stored names, silently and completely.

## License

Code — MIT, see `LICENSE`.

The data in `assets/turkmenistan.adb` comes from OpenStreetMap and is
distributed under the **ODbL** — see `NOTICE`. An application using it
must credit © OpenStreetMap contributors.
