import 'package:flutter/material.dart';
import 'package:turkmenistan_addresses/turkmenistan_addresses.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Адреса Туркменистана',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF00857A),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF00857A),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const SearchScreen(),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  AddressDatabase? _db;
  Object? _error;
  List<SearchHit> _hits = const [];
  Duration _spent = Duration.zero;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final db = await loadTurkmenistanAddresses();
      // Ключи считаются один раз. Без прогрева за них платил бы первый
      // же набранный символ — тридцать миллисекунд под пальцем.
      db.warmUp();
      if (mounted) setState(() => _db = db);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _search(String query) {
    final db = _db;
    if (db == null) return;
    // Запрос стоит около миллисекунды, поэтому ищем на каждое нажатие:
    // отложенный поиск тут нечего экономить.
    final started = Stopwatch()..start();
    final hits = db.search(query, limit: 50);
    started.stop();
    setState(() {
      _hits = hits;
      _spent = started.elapsed;
    });
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Адреса Туркменистана'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SearchBar(
              controller: _field,
              hintText: 'Город, улица или дом',
              leading: const Icon(Icons.search),
              trailing: [
                if (_field.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _field.clear();
                      _search('');
                    },
                  ),
              ],
              onChanged: _search,
            ),
          ),
        ),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) {
      return _Centered(
        icon: Icons.error_outline,
        title: 'База не открылась',
        subtitle: '$_error',
      );
    }
    final db = _db;
    if (db == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_field.text.trim().isEmpty) {
      return _Welcome(db: db, onPick: (query) {
        _field.text = query;
        _search(query);
      });
    }
    if (_hits.isEmpty) {
      return const _Centered(
        icon: Icons.search_off,
        title: 'Ничего не нашлось',
        subtitle: 'Слово ищется с начала: «rahat» не найдёт «Parahat»',
      );
    }
    return Column(
      children: [
        _Stats(text: '${_hits.length} совпадений за '
            '${(_spent.inMicroseconds / 1000).toStringAsFixed(1)} мс'),
        Expanded(
          child: ListView.separated(
            itemCount: _hits.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) => _HitTile(db: db, hit: _hits[index]),
          ),
        ),
      ],
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.db, required this.hit});

  final AddressDatabase db;
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, tint, subtitle) = switch (hit) {
      PlaceHit(:final value) => (
          _placeIcon(value.type),
          colors.primary,
          _placeLabel(value.type),
        ),
      StreetHit(:final value) => (
          Icons.signpost_outlined,
          colors.tertiary,
          [
            'улица',
            if (value.place != null) value.place!.name,
            '${db.housesOn(value.id).length} домов',
          ].join(' · '),
        ),
      AddressHit(:final value) => (
          Icons.home_outlined,
          colors.secondary,
          [
            'дом',
            if (value.place != null) value.place!.name,
            if (!value.streetIsExact) 'улица подобрана',
          ].join(' · '),
        ),
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: tint.withValues(alpha: 0.15),
        child: Icon(icon, color: tint, size: 20),
      ),
      title: Text(hit.title),
      subtitle: Text(subtitle),
      trailing: hit is StreetHit ? const Icon(Icons.chevron_right) : null,
      onTap: () {
        if (hit case StreetHit(:final value)) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => StreetScreen(db: db, street: value),
          ));
        } else {
          _showDetails(context, db, hit);
        }
      },
    );
  }
}

IconData _placeIcon(PlaceType type) => switch (type) {
      PlaceType.city || PlaceType.town => Icons.location_city,
      PlaceType.village || PlaceType.hamlet => Icons.holiday_village_outlined,
      PlaceType.suburb || PlaceType.neighbourhood => Icons.apartment,
      PlaceType.locality => Icons.place_outlined,
    };

String _placeLabel(PlaceType type) => switch (type) {
      PlaceType.city => 'город',
      PlaceType.town => 'город',
      PlaceType.village => 'село',
      PlaceType.hamlet => 'посёлок',
      PlaceType.suburb => 'район',
      PlaceType.neighbourhood => 'микрорайон',
      PlaceType.locality => 'местность',
    };

void _showDetails(BuildContext context, AddressDatabase db, SearchHit hit) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final near = db.addressesNear(hit.lat, hit.lon, radiusMeters: 150, limit: 6);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(hit.title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              '${hit.lat.toStringAsFixed(6)}, ${hit.lon.toStringAsFixed(6)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (hit case AddressHit(:final value)) ...[
              const SizedBox(height: 16),
              _Fact(label: 'Улица', value: value.street.name),
              _Fact(
                label: 'Откуда улица',
                value: value.streetIsExact
                    ? 'из addr:street'
                    : 'подобрана по ближайшей дороге',
              ),
              if (value.place != null)
                _Fact(label: 'Населённый пункт', value: value.place!.name),
            ],
            const SizedBox(height: 16),
            Text('Рядом, в 150 м',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            if (near.isEmpty)
              const Text('— ничего')
            else
              for (final house in near)
                Text('${house.street.name}, ${house.number}  ·  '
                    '${distanceMeters(hit.lat, hit.lon, house.lat, house.lon).round()} м'),
          ],
        ),
      );
    },
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: TextStyle(color: Theme.of(context).hintColor)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class StreetScreen extends StatelessWidget {
  const StreetScreen({super.key, required this.db, required this.street});

  final AddressDatabase db;
  final Street street;

  @override
  Widget build(BuildContext context) {
    // Дома отсортированы по улице ещё при сборке, поэтому берутся одним
    // куском, а не перебором семи тысяч записей.
    final houses = db.housesOn(street.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(street.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              [
                if (street.place != null) street.place!.name,
                '${houses.length} домов',
              ].join(' · '),
            ),
          ),
        ),
      ),
      body: houses.isEmpty
          ? const _Centered(
              icon: Icons.home_outlined,
              title: 'Домов с номерами нет',
              subtitle: '95% зданий в OSM не несут addr:housenumber',
            )
          : ListView.separated(
              itemCount: houses.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final house = houses[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .secondary
                        .withValues(alpha: 0.15),
                    child: Text(house.number,
                        style: const TextStyle(fontSize: 12)),
                  ),
                  title: Text('${house.street.name}, ${house.number}'),
                  subtitle: Text(house.streetIsExact
                      ? '${house.lat.toStringAsFixed(5)}, '
                          '${house.lon.toStringAsFixed(5)}'
                      : 'улица подобрана · '
                          '${house.lat.toStringAsFixed(5)}, '
                          '${house.lon.toStringAsFixed(5)}'),
                  onTap: () => _showDetails(context, db, AddressHit(house)),
                );
              },
            ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.db, required this.onPick});

  final AddressDatabase db;
  final ValueChanged<String> onPick;

  static const _examples = <(String, String)>[
    ('par 2/4 1', 'слова с начала, в любом порядке'),
    ('gorogly', 'без диакритики: ö, ç, ň'),
    ('mary', 'город впереди улиц и домов'),
    ('gorogly kocesi gyzylarbat', 'город отделяет одноимённые улицы'),
  ];

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Оффлайн, целиком на устройстве', style: style.titleMedium),
        const SizedBox(height: 8),
        Text(
          '${db.placeCount} населённых пунктов, ${db.streetCount} улиц, '
          '${db.addressCount} домов — 292 КБ в ассете.',
          style: style.bodyMedium,
        ),
        const SizedBox(height: 24),
        Text('Попробуйте', style: style.titleMedium),
        const SizedBox(height: 8),
        for (final (query, hint) in _examples)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(query, style: const TextStyle(fontFamily: 'Menlo')),
              subtitle: Text(hint),
              onTap: () => onPick(query),
            ),
          ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
