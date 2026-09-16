#!/usr/bin/env python3
"""Собирает адресную базу Туркменистана из OSM PBF.

    tool/.venv/bin/python tool/build_address_db.py \
        assets/turkmenistan.pbf assets/turkmenistan.adb

Внутрь идёт только то, по чему ищут адрес:
  * населённые пункты — города, сёла, микрорайоны;
  * улицы — названные дороги, разведённые по городам;
  * дома — всё с addr:housenumber, у каждого своя улица.

Заведения, реки и памятники сюда не попадают: они есть в .search и
адресному поиску не нужны.

Три вещи отличают эту сборку от build_search.py, и все три видны в выдаче:

  * дома дедуплицируются. Дом сплошь и рядом размечен дважды — контуром
    здания и адресной точкой внутри него, — и в .search оба лежат рядом
    двумя одинаковыми строками;
  * улица хранится один раз, а не переписывается в каждый дом;
  * у дома помечено, откуда взялась улица: из addr:street или подобрана
    по ближайшей дороге.

Формат выходного файла описан в address_db_format.py.
"""

import argparse
import math
import re
import struct
import sys
import time
from array import array

import osmium

import address_db_format as fmt

EARTH_RADIUS_M = 6371008.8

# Одна и та же улица есть в разных городах. Названия дальше этого
# расстояния — разные улицы, сливать их нельзя: водителя увезёт в другой
# город к дому с тем же номером.
STREET_CLUSTER_M = 6000

# Дальше этого дом уже не «на этой улице» — лучше оставить без неё.
STREET_SNAP_M = 150

# Два дома с одним номером ближе этого — один дом, размеченный дважды.
# Радиус мал намеренно: разные дома с одинаковым номером в соседних
# кварталах встречаются, и склеивать их нельзя.
NEARBY_RADIUS_M = 25

# Один населённый пункт ближе этого расстояния к другому с тем же
# названием — это он же, размеченный дважды: точкой в центре и полигоном
# границы. Радиус щедрый, потому что центр полигона и табличка в центре
# города расходятся на километры, а два разных села с одним названием в
# десяти километрах друг от друга не встречаются.
PLACE_DUPLICATE_M = 10000

# Дальше этого улица уже не принадлежит населённому пункту. Сёла в
# Туркменистане стоят редко, поэтому радиус щедрый.
PLACE_SNAP_M = 25000

# Насколько далеко «дотягивается» населённый пункт своего типа. Голое
# расстояние тут не работает: микрорайоны Ашхабада — Parahat 7/2, Gurtly —
# лежат ближе к пригородным сёлам (Gämi, Nurly zaman), чем к точке центра
# города, и по чистой близости весь спальный район уезжает в село.
# Поэтому расстояние делится на вес: город виден с пятнадцати километров,
# село — с двух.
PLACE_REACH = {
    fmt.PLACE_CITY: 6.0,
    fmt.PLACE_TOWN: 3.0,
    fmt.PLACE_VILLAGE: 1.0,
    fmt.PLACE_HAMLET: 0.7,
}

# Размер ячейки поисковых сеток, в градусах (~550 м).
LOOKUP_CELL_DEG = 0.005

# Шаг, с которым дорога раскладывается на точки для поиска ближайшей.
STREET_SAMPLE_M = 40

MAX_NAME = 90
MAX_NUMBER = 24


def haversine_m(lat1, lon1, lat2, lon2):
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = phi2 - phi1
    dlambda = math.radians(lon2 - lon1)
    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    )
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def clean(value, limit=MAX_NAME):
    if not value:
        return ""
    return " ".join(value.split())[:limit]


def is_house_number(text):
    """Отсекает мусор в addr:housenumber.

    В данных попадаются «?», «???», «&» и названия организаций
    («Gül Zemin»). Настоящий номер всегда содержит цифру.
    """
    if not text or len(text) > MAX_NUMBER:
        return False
    return any(character.isdigit() for character in text)


def point_in_polygon(lat, lon, ring):
    """Лучевой алгоритм: сколько раз луч из точки пересёк контур."""
    inside = False
    count = len(ring)
    j = count - 1
    for i in range(count):
        lat_i, lon_i = ring[i]
        lat_j, lon_j = ring[j]
        if (lat_i > lat) != (lat_j > lat):
            x = (lon_j - lon_i) * (lat - lat_i) / (lat_j - lat_i) + lon_i
            if lon < x:
                inside = not inside
        j = i
    return inside


def in_country(lat, lon):
    return (fmt.BBOX_SOUTH <= lat <= fmt.BBOX_NORTH
            and fmt.BBOX_WEST <= lon <= fmt.BBOX_EAST)


class StreetLocator:
    """Ближайшая названная улица к произвольной точке.

    Дороги раскладываются на точки с шагом в несколько десятков метров и
    складываются в сетку. Полный перебор здесь не годится: улиц тысячи, а
    спросить нужно для каждого из восьми тысяч домов.
    """

    def __init__(self):
        self._cells = {}

    def add(self, name, points):
        carried = 0.0
        previous = points[0]
        self._put(name, previous)
        for point in points[1:]:
            carried += haversine_m(previous[0], previous[1], point[0], point[1])
            if carried >= STREET_SAMPLE_M:
                carried = 0.0
                self._put(name, point)
            previous = point
        self._put(name, points[-1])

    def _put(self, name, point):
        key = (int(point[0] / LOOKUP_CELL_DEG), int(point[1] / LOOKUP_CELL_DEG))
        self._cells.setdefault(key, []).append((point[0], point[1], name))

    def nearest(self, lat, lon):
        row = int(lat / LOOKUP_CELL_DEG)
        col = int(lon / LOOKUP_CELL_DEG)
        best = None
        best_distance = STREET_SNAP_M
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                for point_lat, point_lon, name in self._cells.get((row + dr, col + dc), ()):
                    distance = haversine_m(lat, lon, point_lat, point_lon)
                    if distance < best_distance:
                        best_distance = distance
                        best = name
        return best


class Collector(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.locator = StreetLocator()

        self.places = []  # (type, name, lat, lon)
        self.street_points = {}  # name -> [(lat, lon)]
        self.buildings = []  # (number, lat, lon, street_tag, ring)
        self.nodes = []  # (number, lat, lon, street_tag)

        self.skipped_junk = 0
        self.skipped_no_geometry = 0
        self.skipped_outside = 0

    def _place(self, tags, lat, lon):
        place_type = fmt.PLACE_TAGS.get(tags.get("place"))
        if place_type is None:
            return
        name = clean(tags.get("name"))
        if name:
            self.places.append((place_type, name, lat, lon))

    def _address(self, tags, lat, lon, ring):
        number = tags.get("addr:housenumber")
        if not number:
            return
        number = clean(number, MAX_NUMBER).strip()
        if not is_house_number(number):
            self.skipped_junk += 1
            return
        street = clean(tags.get("addr:street")) or None
        if ring is None:
            self.nodes.append((number, lat, lon, street))
        else:
            self.buildings.append((number, lat, lon, street, ring))

    def node(self, n):
        if not n.location.valid():
            if n.tags.get("addr:housenumber"):
                self.skipped_no_geometry += 1
            return
        lat, lon = n.location.lat, n.location.lon
        if not in_country(lat, lon):
            if n.tags.get("addr:housenumber"):
                self.skipped_outside += 1
            return
        self._place(n.tags, lat, lon)
        self._address(n.tags, lat, lon, None)

    def way(self, w):
        ring = [
            (node.location.lat, node.location.lon)
            for node in w.nodes
            if node.location.valid()
        ]
        if not ring:
            if w.tags.get("addr:housenumber"):
                self.skipped_no_geometry += 1
            return
        # Середина контура: для прямоугольного дома это его центр, для
        # вытянутого — точка внутри, чего для адреса достаточно.
        lat = sum(p[0] for p in ring) / len(ring)
        lon = sum(p[1] for p in ring) / len(ring)
        if not in_country(lat, lon):
            if w.tags.get("addr:housenumber"):
                self.skipped_outside += 1
            return

        self._place(w.tags, lat, lon)
        self._address(w.tags, lat, lon, ring)

        if w.tags.get("highway"):
            name = clean(w.tags.get("name"))
            if name:
                self.street_points.setdefault(name, []).append((lat, lon))
                self.locator.add(name, ring)

    def deduplicate(self):
        """Убирает второй адрес одного и того же дома.

        Признак дубля — точка лежит ВНУТРИ контура с тем же номером.
        Именно геометрия, а не расстояние: у панельного дома длиной под
        сотню метров точка стоит у подъезда, а центр контура посередине,
        и по радиусу их не свести, не склеив заодно разные дома с
        одинаковым номером в соседних кварталах.
        """
        cells = {}
        for index, (number, _, _, _, ring) in enumerate(self.buildings):
            seen = set()
            for point_lat, point_lon in ring:
                key = (number,
                       int(point_lat / LOOKUP_CELL_DEG),
                       int(point_lon / LOOKUP_CELL_DEG))
                if key not in seen:
                    seen.add(key)
                    cells.setdefault(key, []).append(index)

        kept = {}
        result = []
        inside_building = 0
        near_duplicate = 0

        def accept(number, lat, lon, street):
            nonlocal near_duplicate
            neighbours = kept.setdefault(number, [])
            for other_lat, other_lon in neighbours:
                if haversine_m(lat, lon, other_lat, other_lon) <= NEARBY_RADIUS_M:
                    near_duplicate += 1
                    return
            neighbours.append((lat, lon))
            result.append((number, lat, lon, street))

        # Контуры первыми: их центр заведомо внутри дома, поэтому при
        # схлопывании выживать должен именно он, а не адресная точка.
        for number, lat, lon, street, _ in self.buildings:
            accept(number, lat, lon, street)

        for number, lat, lon, street in self.nodes:
            key = (number, int(lat / LOOKUP_CELL_DEG), int(lon / LOOKUP_CELL_DEG))
            if any(point_in_polygon(lat, lon, self.buildings[index][4])
                   for index in cells.get(key, ())):
                inside_building += 1
                continue
            accept(number, lat, lon, street)

        return result, inside_building, near_duplicate

    def streets(self):
        """Улицы, разведённые по городам: (name, lat, lon)."""
        result = []
        for name, points in self.street_points.items():
            clusters = []
            for lat, lon in points:
                for cluster in clusters:
                    if haversine_m(lat, lon, cluster[0], cluster[1]) <= STREET_CLUSTER_M:
                        cluster[2].append((lat, lon))
                        break
                else:
                    clusters.append((lat, lon, [(lat, lon)]))
            for _, _, members in clusters:
                result.append((
                    name,
                    sum(p[0] for p in members) / len(members),
                    sum(p[1] for p in members) / len(members),
                ))
        return result


def deduplicate_places(places):
    """Схлопывает населённый пункт, размеченный точкой и полигоном.

    В экстракте `place=city` висит и на узле в центре города, и на
    контуре его границы — в сыром виде Теджен и Туркменгала приезжают в
    базу по два раза. Сравнение по свёрнутому названию, а не по строке:
    «Altyn asyr» и «Altyn Asyr» — один посёлок.

    Выживает запись с самым весомым типом: если один и тот же объект
    размечен и городом, и микрорайоном, адрес принадлежит городу.
    """
    kept = []
    groups = {}
    dropped = 0
    for place in places:
        key = fmt.search_key(place[1])
        bucket = groups.setdefault(key, [])
        for position in bucket:
            other = kept[position]
            if haversine_m(place[2], place[3], other[2], other[3]) <= PLACE_DUPLICATE_M:
                if place[0] < other[0]:
                    kept[position] = place
                dropped += 1
                break
        else:
            bucket.append(len(kept))
            kept.append(place)
    return kept, dropped


def attach_places(streets, places):
    """Каждой улице — населённый пункт, в котором она лежит.

    Микрорайон и местность для этого не годятся: адрес привязывают к
    городу или селу, «Parahat 4» само по себе не адрес.
    """
    anchors = [
        (index, place[2], place[3], PLACE_REACH[place[0]])
        for index, place in enumerate(places)
        if place[0] in fmt.PLACE_PARENTS
    ]

    # Полный перебор: населённых пунктов пара тысяч, улиц три с половиной —
    # семь миллионов проверок, считаные секунды. Сетка тут не помогла бы,
    # радиус привязки много больше её ячейки.
    result = []
    for name, lat, lon in streets:
        best = fmt.NO_REF
        best_score = None
        for index, place_lat, place_lon, reach in anchors:
            distance = haversine_m(lat, lon, place_lat, place_lon)
            if distance > PLACE_SNAP_M:
                continue
            score = distance / reach
            if best_score is None or score < best_score:
                best_score = score
                best = index
        result.append(best)
    return result


def resolve_streets(addresses, streets, locator):
    """Каждому дому — индекс его улицы.

    Порядок: addr:street, если он есть; иначе ближайшая названная дорога
    в пределах STREET_SNAP_M. Улица с тегом, но без дороги поблизости,
    всё равно настоящая — под неё заводится своя запись, иначе дом
    пропал бы вместе с адресом, который в OSM записан явно.
    """
    by_name = {}
    for index, (name, lat, lon) in enumerate(streets):
        by_name.setdefault(name, []).append((index, lat, lon))

    extra = []  # новые улицы: (name, lat, lon)
    extra_by_name = {}
    resolved = []
    dropped = 0
    invented = 0

    def nearest_cluster(name, lat, lon, limit):
        best = None
        best_distance = limit
        for index, cluster_lat, cluster_lon in by_name.get(name, ()):
            distance = haversine_m(lat, lon, cluster_lat, cluster_lon)
            if distance < best_distance:
                best_distance = distance
                best = index
        return best

    for number, lat, lon, tagged in addresses:
        if tagged:
            index = nearest_cluster(tagged, lat, lon, STREET_CLUSTER_M)
            if index is None:
                # Та же кластеризация, что у дорог, но по домам: иначе
                # улица без дороги разложится на сотню записей — по одной
                # на дом.
                index = None
                for candidate, cluster_lat, cluster_lon in extra_by_name.get(tagged, ()):
                    if haversine_m(lat, lon, cluster_lat, cluster_lon) <= STREET_CLUSTER_M:
                        index = candidate
                        break
                if index is None:
                    index = len(streets) + len(extra)
                    extra.append((tagged, lat, lon))
                    extra_by_name.setdefault(tagged, []).append((index, lat, lon))
                    invented += 1
            resolved.append((number, lat, lon, index, True))
            continue

        name = locator.nearest(lat, lon)
        if name is None:
            # Голый номер без улицы искать невозможно: «дом 12» есть в
            # каждом квартале.
            dropped += 1
            continue
        index = nearest_cluster(name, lat, lon, STREET_CLUSTER_M)
        if index is None:
            dropped += 1
            continue
        resolved.append((number, lat, lon, index, False))

    return resolved, extra, dropped, invented


_NUMBER_PARTS = re.compile(r"(\d+)")


def natural_key(number):
    """Ключ сортировки номеров домов по-человечески.

    По строке «48» встаёт между «4» и «5», а дом 10 — сразу за домом 1.
    Список домов на улице читают глазами, и такой порядок в нём выглядит
    поломкой. Номер разбирается на цифровые и нецифровые куски: «2/4»,
    «12-а» и «111(A)» тоже раскладываются правильно.
    """
    return tuple(
        (1, int(part)) if part.isdigit() else (0, part)
        for part in _NUMBER_PARTS.split(number)
        if part
    )


def to_le(values):
    if sys.byteorder != "little":
        values = values[:]
        values.byteswap()
    return values.tobytes()


def write_database(path, places, streets, street_places, addresses):
    """Пишет секции. Строки — только названия, каждое по одному разу."""
    strings = []
    string_index = {}

    def intern(text):
        index = string_index.get(text)
        if index is None:
            index = len(strings)
            string_index[text] = index
            strings.append(text)
        return index

    place_lat = array("i")
    place_lon = array("i")
    place_name = array("I")
    place_type = array("B")
    for kind, name, lat, lon in places:
        place_lat.append(round(lat * 1e7))
        place_lon.append(round(lon * 1e7))
        place_name.append(intern(name))
        place_type.append(kind)

    street_lat = array("i")
    street_lon = array("i")
    street_name = array("I")
    street_place = array("I", street_places)
    for name, lat, lon in streets:
        street_lat.append(round(lat * 1e7))
        street_lon.append(round(lon * 1e7))
        street_name.append(intern(name))

    address_lat = array("i")
    address_lon = array("i")
    address_street = array("I")
    number_off = array("I", [0])
    number_bytes = bytearray()
    exact_bits = bytearray((len(addresses) + 7) // 8)
    for position, (number, lat, lon, street, exact) in enumerate(addresses):
        address_lat.append(round(lat * 1e7))
        address_lon.append(round(lon * 1e7))
        address_street.append(street)
        number_bytes.extend(number.encode("utf-8"))
        number_off.append(len(number_bytes))
        if exact:
            exact_bits[position >> 3] |= 1 << (position & 7)

    string_off = array("I", [0])
    string_bytes = bytearray()
    for text in strings:
        string_bytes.extend(text.encode("utf-8"))
        string_off.append(len(string_bytes))

    sections = [None] * fmt.SECTION_COUNT
    sections[fmt.S_PLACE_LAT] = to_le(place_lat)
    sections[fmt.S_PLACE_LON] = to_le(place_lon)
    sections[fmt.S_PLACE_NAME] = to_le(place_name)
    sections[fmt.S_PLACE_TYPE] = place_type.tobytes()
    sections[fmt.S_STREET_LAT] = to_le(street_lat)
    sections[fmt.S_STREET_LON] = to_le(street_lon)
    sections[fmt.S_STREET_NAME] = to_le(street_name)
    sections[fmt.S_STREET_PLACE] = to_le(street_place)
    sections[fmt.S_ADDR_LAT] = to_le(address_lat)
    sections[fmt.S_ADDR_LON] = to_le(address_lon)
    sections[fmt.S_ADDR_STREET] = to_le(address_street)
    sections[fmt.S_ADDR_NUM_OFF] = to_le(number_off)
    sections[fmt.S_ADDR_NUM] = bytes(number_bytes)
    sections[fmt.S_STR_OFF] = to_le(string_off)
    sections[fmt.S_STR] = bytes(string_bytes)
    sections[fmt.S_ADDR_STREET_EXACT] = bytes(exact_bits)

    offset = fmt.HEADER_BYTES + fmt.SECTION_TABLE_BYTES
    table = []
    for payload in sections:
        table.append((offset, len(payload)))
        offset += len(payload)
        offset += (-offset) % 4

    header = bytearray(fmt.HEADER_BYTES)
    struct.pack_into(
        "<4sIIIII",
        header,
        0,
        fmt.MAGIC,
        fmt.FORMAT_VERSION,
        fmt.SECTION_COUNT,
        len(places),
        len(streets),
        len(addresses),
    )

    with open(path, "wb") as out:
        out.write(header)
        for start, length in table:
            out.write(struct.pack("<II", start, length))
        position = fmt.HEADER_BYTES + fmt.SECTION_TABLE_BYTES
        for payload in sections:
            out.write(payload)
            position += len(payload)
            padding = (-position) % 4
            if padding:
                out.write(b"\0" * padding)
                position += padding
    return offset, len(strings), len(string_bytes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pbf", help="входной OSM PBF")
    parser.add_argument("out", help="выходной .adb")
    args = parser.parse_args()

    started = time.time()
    print("читаем данные…", flush=True)
    collector = Collector()
    collector.apply_file(args.pbf, locations=True, idx="flex_mem")
    print(f"  населённых пунктов: {len(collector.places)},"
          f" названных дорог: {len(collector.street_points)}", flush=True)
    print(f"  контуров с адресом: {len(collector.buildings)},"
          f" адресных точек: {len(collector.nodes)}", flush=True)
    if collector.skipped_junk:
        print(f"  отброшено мусорных номеров: {collector.skipped_junk}", flush=True)
    if collector.skipped_outside:
        print(f"  отброшено за границей страны: {collector.skipped_outside}", flush=True)
    if collector.skipped_no_geometry:
        print(f"  пропущено без координат: {collector.skipped_no_geometry}", flush=True)

    collector.places, duplicate_places = deduplicate_places(collector.places)
    if duplicate_places:
        print(f"  схлопнуто населённых пунктов (точка и полигон):"
              f" {duplicate_places}", flush=True)

    addresses, inside, nearby = collector.deduplicate()
    print(f"  точек внутри своего же контура: {inside}", flush=True)
    print(f"  схлопнуто близнецов (в пределах {NEARBY_RADIUS_M} м): {nearby}", flush=True)

    streets = collector.streets()
    print(f"  улиц после разведения по городам: {len(streets)}", flush=True)

    resolved, extra, dropped, invented = resolve_streets(
        addresses, streets, collector.locator)
    streets = streets + extra
    if invented:
        print(f"  улиц заведено по addr:street без дороги рядом: {invented}",
              flush=True)
    if dropped:
        print(f"  домов отброшено (нет улицы ближе {STREET_SNAP_M} м): {dropped}",
              flush=True)

    street_places = attach_places(streets, collector.places)
    without_place = sum(1 for index in street_places if index == fmt.NO_REF)
    if without_place:
        print(f"  улиц без населённого пункта: {without_place}", flush=True)

    # Дома группой по улице: выдача «все дома на улице» становится
    # непрерывным куском, который берётся двоичным поиском, да и жмётся
    # лучше. Внутри улицы — по номеру, по-человечески.
    resolved.sort(key=lambda row: (row[3], natural_key(row[0])))

    exact = sum(1 for row in resolved if row[4])
    print(f"  домов на выходе: {len(resolved)}"
          f" (улица из addr:street у {exact},"
          f" выведена у {len(resolved) - exact})", flush=True)
    if not resolved:
        sys.exit("в файле не нашлось ни одного адреса")

    print(f"пишем {args.out}…", flush=True)
    size, string_count, string_bytes = write_database(
        args.out, collector.places, streets, street_places, resolved)
    print(f"  строк в таблице названий: {string_count} ({string_bytes / 1024:.0f} КБ)",
          flush=True)
    print(f"готово: {size / 1024:.0f} КБ за {time.time() - started:.0f} с", flush=True)


if __name__ == "__main__":
    main()
