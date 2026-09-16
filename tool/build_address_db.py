#!/usr/bin/env python3
"""Builds the Turkmenistan address database from an OSM PBF extract.

    tool/.venv/bin/python tool/build_address_db.py \
        turkmenistan.pbf assets/turkmenistan.adb

Only what an address search needs goes in:
  * settlements - cities, villages, neighbourhoods;
  * streets - named roads, separated by town;
  * houses - everything with addr:housenumber, each with its street.

Shops, rivers and monuments stay out: they are not addresses.

Three things here show up directly in the results:

  * houses are deduplicated. A house is routinely mapped twice - as a
    building outline and as an address node inside it - and left alone
    both land in the results as two identical rows;
  * a street is stored once instead of being copied into every house;
  * each house records where its street came from: the addr:street tag,
    or the nearest road.

The output format is described in address_db_format.py.
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

# The same street name occurs in different towns. Further apart than this
# they are different streets, and merging them is not allowed: it sends
# you to another town, to a house with the same number.
STREET_CLUSTER_M = 6000

# Beyond this a house is no longer "on that street" - better to leave it
# without one.
STREET_SNAP_M = 150

# Two houses with the same number closer than this are one house mapped
# twice. The radius is deliberately small: different houses with the same
# number do occur in neighbouring blocks, and merging those is wrong.
NEARBY_RADIUS_M = 25

# A settlement closer than this to another one of the same name is the
# same settlement mapped twice: as a node at its centre and as a boundary
# polygon. The radius is generous because the centroid of the polygon and
# the node in the town centre sit kilometres apart, while two different
# villages sharing a name ten kilometres apart do not occur.
PLACE_DUPLICATE_M = 10000

# Beyond this a street no longer belongs to a settlement. Villages in
# Turkmenistan are far apart, hence the generous radius.
PLACE_SNAP_M = 25000

# How far a settlement of each type "reaches". Plain distance does not
# work here: the Ashgabat neighbourhoods - Parahat 7/2, Gurtly - lie
# closer to the suburban villages (Gämi, Nurly zaman) than to the node
# marking the city centre, so by proximity alone the whole residential
# district moves to a village. Distance is therefore divided by a weight:
# a city is visible from fifteen kilometres, a village from two.
PLACE_REACH = {
    fmt.PLACE_CITY: 6.0,
    fmt.PLACE_TOWN: 3.0,
    fmt.PLACE_VILLAGE: 1.0,
    fmt.PLACE_HAMLET: 0.7,
}

# Cell size of the lookup grids, in degrees (~550 m).
LOOKUP_CELL_DEG = 0.005

# Spacing at which a road is sampled into points for nearest-road lookup.
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
    """Rejects junk in addr:housenumber.

    The data contains "?", "???", "&" and company names ("Gül Zemin").
    A real house number always contains a digit.
    """
    if not text or len(text) > MAX_NUMBER:
        return False
    return any(character.isdigit() for character in text)


def point_in_polygon(lat, lon, ring):
    """Ray casting: how many times a ray from the point crosses the ring."""
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
    """The nearest named street to an arbitrary point.

    Roads are sampled into points every few dozen metres and dropped into
    a grid. A full scan will not do here: there are thousands of streets
    and the question is asked for each of eight thousand houses.
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
        # The middle of the ring: for a rectangular house that is its
        # centre, for an elongated one a point inside it, which is enough
        # for an address.
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
        """Removes the second address of one and the same house.

        The mark of a duplicate is an address node INSIDE an outline with
        the same number. Geometry, not distance: on a panel block a
        hundred metres long the node stands at an entrance while the
        outline's centre is in the middle, and no radius brings those
        together without also merging different houses that share a
        number in neighbouring blocks.
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

        # Outlines first: their centre is certainly inside the house, so
        # it is the one that should survive a merge, not the node.
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
        """Streets separated by town: (name, lat, lon)."""
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
    """Merges a settlement mapped as both a node and a polygon.

    In the extract `place=city` sits on the node at the town centre and
    on its boundary outline alike - untouched, Tejen and Türkmengala
    arrive in the database twice. Comparison runs on the folded name, not
    the raw string: "Altyn asyr" and "Altyn Asyr" are one settlement.

    The record with the weightiest type survives: if the same object is
    mapped as both a city and a neighbourhood, an address belongs to the
    city.
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
    """Gives every street the settlement it lies in.

    A neighbourhood or a locality will not do: an address is bound to a
    city or a village, and "Parahat 4" on its own is not an address.
    """
    anchors = [
        (index, place[2], place[3], PLACE_REACH[place[0]])
        for index, place in enumerate(places)
        if place[0] in fmt.PLACE_PARENTS
    ]

    # Full scan: a couple of thousand settlements against three and a half
    # thousand streets is seven million checks, a few seconds. A grid
    # would not help - the attachment radius is far larger than its cell.
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
    """Gives every house the index of its street.

    In order: addr:street if present, otherwise the nearest named road
    within STREET_SNAP_M. A tagged street with no road nearby is still a
    real street - it gets a record of its own, or the house would be lost
    along with an address OSM states explicitly.
    """
    by_name = {}
    for index, (name, lat, lon) in enumerate(streets):
        by_name.setdefault(name, []).append((index, lat, lon))

    extra = []  # new streets: (name, lat, lon)
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
                # The same clustering roads get, but over houses:
                # otherwise a street with no road becomes a hundred
                # records, one per house.
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
            # A bare number is unsearchable: "house 12" exists in every
            # block.
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
    """Sort key that orders house numbers the way people read them.

    By string, "48" falls between "4" and "5", and house 10 right after
    house 1. The list of houses on a street is read by eye, and that
    order looks like a bug in it. The number is split into digit and
    non-digit runs, so "2/4", "12-a" and "111(A)" come out right too.
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
    """Writes the sections. Strings are names only, each one stored once."""
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
    parser.add_argument("pbf", help="input OSM PBF")
    parser.add_argument("out", help="output .adb")
    args = parser.parse_args()

    started = time.time()
    print("reading the extract...", flush=True)
    collector = Collector()
    collector.apply_file(args.pbf, locations=True, idx="flex_mem")
    print(f"  settlements: {len(collector.places)},"
          f" named roads: {len(collector.street_points)}", flush=True)
    print(f"  outlines with an address: {len(collector.buildings)},"
          f" address nodes: {len(collector.nodes)}", flush=True)
    if collector.skipped_junk:
        print(f"  junk numbers dropped: {collector.skipped_junk}", flush=True)
    if collector.skipped_outside:
        print(f"  dropped outside the country: {collector.skipped_outside}", flush=True)
    if collector.skipped_no_geometry:
        print(f"  skipped without coordinates: {collector.skipped_no_geometry}", flush=True)

    collector.places, duplicate_places = deduplicate_places(collector.places)
    if duplicate_places:
        print(f"  settlements merged (node and polygon):"
              f" {duplicate_places}", flush=True)

    addresses, inside, nearby = collector.deduplicate()
    print(f"  nodes inside their own outline: {inside}", flush=True)
    print(f"  twins merged (within {NEARBY_RADIUS_M} m): {nearby}", flush=True)

    streets = collector.streets()
    print(f"  streets after separating by town: {len(streets)}", flush=True)

    resolved, extra, dropped, invented = resolve_streets(
        addresses, streets, collector.locator)
    streets = streets + extra
    if invented:
        print(f"  streets created from addr:street with no road nearby:"
              f" {invented}", flush=True)
    if dropped:
        print(f"  houses dropped (no street within {STREET_SNAP_M} m):"
              f" {dropped}", flush=True)

    street_places = attach_places(streets, collector.places)
    without_place = sum(1 for index in street_places if index == fmt.NO_REF)
    if without_place:
        print(f"  streets with no settlement: {without_place}", flush=True)

    # Houses grouped by street: "every house on this street" becomes one
    # contiguous slice, taken by binary search, and it compresses better
    # too. Within a street, by number, the way people read them.
    resolved.sort(key=lambda row: (row[3], natural_key(row[0])))

    exact = sum(1 for row in resolved if row[4])
    print(f"  houses written: {len(resolved)}"
          f" (street from addr:street for {exact},"
          f" inferred for {len(resolved) - exact})", flush=True)
    if not resolved:
        sys.exit("the extract contained no addresses at all")

    print(f"writing {args.out}...", flush=True)
    size, string_count, string_bytes = write_database(
        args.out, collector.places, streets, street_places, resolved)
    print(f"  strings in the name table: {string_count}"
          f" ({string_bytes / 1024:.0f} KB)", flush=True)
    print(f"done: {size / 1024:.0f} KB in {time.time() - started:.0f} s",
          flush=True)


if __name__ == "__main__":
    main()
