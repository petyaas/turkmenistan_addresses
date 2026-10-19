"""The address database format (.adb) - the single source of truth.

The same layout is mirrored in the package's Dart reader. Change it here
and you must change it there, raising FORMAT_VERSION; the loader is
required to refuse a mismatch rather than read garbage.

The layout is normalised, because the obvious flat one wastes most of the
file:

  * a search key stored next to the name takes 40% of all strings. Folding
    6,500 unique names at load time costs a few milliseconds ONCE, not on
    every keystroke, so keys are not stored at all;
  * a human-readable label for the kind of an entry bakes a language into
    the data. A type code is stored instead, and whoever displays the
    entry gets to word it;
  * the full string "Görogly köçesi, 8" repeated in every house is waste:
    eight thousand houses share 924 street names.

Hence: a house is a coordinate, a reference to a street and a number; a
street is a name and a reference to a settlement; a public place - an
airport, a station, a hospital - is a coordinate, a name, a category code
and a reference to a settlement.

File: [32-byte header][section table, 21*8 bytes][sections, 4-byte aligned]

Header: magic, FORMAT_VERSION, SECTION_COUNT, then the number of
settlements, streets, houses and public places, all uint32.

There is deliberately no spatial index: with twenty thousand entries a
full scan is cheaper than a grid held in memory.
"""

MAGIC = b"TMAB"
FORMAT_VERSION = 2

HEADER_BYTES = 32
SECTION_COUNT = 21
SECTION_TABLE_BYTES = SECTION_COUNT * 8

# Settlements.
S_PLACE_LAT = 0  # int32[placeCount]      latitude * 1e7
S_PLACE_LON = 1  # int32[placeCount]
S_PLACE_NAME = 2  # uint32[placeCount]    index into the string table
S_PLACE_TYPE = 3  # uint8[placeCount]     PLACE_* below

# Streets, already separated by town.
S_STREET_LAT = 4  # int32[streetCount]
S_STREET_LON = 5  # int32[streetCount]
S_STREET_NAME = 6  # uint32[streetCount]  index into the string table
S_STREET_PLACE = 7  # uint32[streetCount] settlement index, or NO_REF

# Houses.
S_ADDR_LAT = 8  # int32[addressCount]
S_ADDR_LON = 9  # int32[addressCount]
S_ADDR_STREET = 10  # uint32[addressCount]  street index, always set
S_ADDR_NUM_OFF = 11  # uint32[addressCount+1]
S_ADDR_NUM = 12  # uint8[...]               house numbers in UTF-8, packed

# String table: street and settlement names, each stored once.
S_STR_OFF = 13  # uint32[stringCount+1]
S_STR = 14  # uint8[...]

# Where each house's street came from, one bit per house, LSB first.
# 1 - the street came from addr:street, 0 - it was inferred from the
# nearest road. The tag is present on only 71% of houses; the rest had
# their street determined geometrically and it may be the wrong one. A
# general-purpose library has to let the caller tell a fact from a guess.
S_ADDR_STREET_EXACT = 15  # uint8[ceil(addressCount/8)]

# Public places, sorted by category and then by name, so that "every
# airport" is one contiguous slice.
S_POI_LAT = 16  # int32[poiCount]
S_POI_LON = 17  # int32[poiCount]
S_POI_NAME = 18  # uint32[poiCount]      index into the string table
S_POI_CATEGORY = 19  # uint8[poiCount]   POI_* below
S_POI_PLACE = 20  # uint32[poiCount]     settlement index, or NO_REF

NO_REF = 0xFFFFFFFF

# The kind of a settlement. The order sets priority in the results: a city
# outranks a village, a village outranks a nameless locality. The position
# is the on-disk code, so new kinds may only be appended.
PLACE_CITY = 0
PLACE_TOWN = 1
PLACE_VILLAGE = 2
PLACE_SUBURB = 3
PLACE_NEIGHBOURHOOD = 4
PLACE_HAMLET = 5
PLACE_LOCALITY = 6

# What counts as a settlement in OSM.
PLACE_TAGS = {
    "city": PLACE_CITY,
    "town": PLACE_TOWN,
    "village": PLACE_VILLAGE,
    "suburb": PLACE_SUBURB,
    "neighbourhood": PLACE_NEIGHBOURHOOD,
    "hamlet": PLACE_HAMLET,
    "isolated_dwelling": PLACE_HAMLET,
    "locality": PLACE_LOCALITY,
}

# Which settlement a street may be attached to: a neighbourhood or a
# locality will not do - an address is bound to a city or a village.
PLACE_PARENTS = (PLACE_CITY, PLACE_TOWN, PLACE_VILLAGE, PLACE_HAMLET)

# The category of a public place. As with PLACE_*, the position is the
# on-disk code: new categories may only be appended. No label is stored -
# the reader words a category in whatever language it displays.
POI_AIRPORT = 0
POI_RAILWAY_STATION = 1
POI_BUS_STATION = 2
POI_FERRY_TERMINAL = 3
POI_HOSPITAL = 4
POI_CLINIC = 5
POI_PHARMACY = 6
POI_UNIVERSITY = 7
POI_SCHOOL = 8
POI_KINDERGARTEN = 9
POI_GOVERNMENT = 10
POI_POLICE = 11
POI_FIRE_STATION = 12
POI_POST_OFFICE = 13
POI_EMBASSY = 14
POI_BANK = 15
POI_FUEL = 16
POI_MARKETPLACE = 17
POI_MALL = 18
POI_HOTEL = 19
POI_MUSEUM = 20
POI_THEATRE = 21
POI_CINEMA = 22
POI_LIBRARY = 23
POI_PLACE_OF_WORSHIP = 24
POI_MONUMENT = 25
POI_ATTRACTION = 26
POI_PARK = 27
POI_SPORTS = 28
POI_AMUSEMENT = 29

# Which OSM tags make a public place. The list is ordered: an object
# carrying several of them takes the first match, so a station that is
# also tagged as a building is a station, and a hospital with a pharmacy
# inside is a hospital.
#
# Deliberately left out: cafés and shops (there are thousands, and they
# are not destinations one searches the country for), ATMs, parking,
# railway=crossing.
POI_TAGS = [
    (POI_AIRPORT, "aeroway", ("aerodrome",)),
    (POI_RAILWAY_STATION, "railway", ("station", "halt")),
    (POI_RAILWAY_STATION, "building", ("train_station",)),
    (POI_BUS_STATION, "amenity", ("bus_station",)),
    (POI_FERRY_TERMINAL, "amenity", ("ferry_terminal",)),
    (POI_HOSPITAL, "amenity", ("hospital",)),
    (POI_HOSPITAL, "healthcare", ("hospital",)),
    (POI_CLINIC, "amenity", ("clinic", "doctors")),
    (POI_CLINIC, "healthcare", ("clinic", "centre")),
    (POI_UNIVERSITY, "amenity", ("university", "college")),
    (POI_SCHOOL, "amenity", ("school",)),
    (POI_KINDERGARTEN, "amenity", ("kindergarten",)),
    (POI_EMBASSY, "diplomatic", ("embassy", "consulate")),
    (POI_EMBASSY, "office", ("diplomatic",)),
    (POI_EMBASSY, "amenity", ("embassy",)),
    (POI_GOVERNMENT, "amenity", ("townhall", "courthouse")),
    (POI_GOVERNMENT, "office", ("government",)),
    (POI_POLICE, "amenity", ("police",)),
    (POI_FIRE_STATION, "amenity", ("fire_station",)),
    (POI_POST_OFFICE, "amenity", ("post_office",)),
    (POI_MUSEUM, "tourism", ("museum",)),
    (POI_THEATRE, "amenity", ("theatre", "arts_centre")),
    (POI_CINEMA, "amenity", ("cinema",)),
    (POI_LIBRARY, "amenity", ("library",)),
    (POI_PLACE_OF_WORSHIP, "amenity", ("place_of_worship",)),
    (POI_AMUSEMENT, "tourism", ("theme_park", "zoo")),
    (POI_AMUSEMENT, "leisure", ("water_park",)),
    (POI_SPORTS, "leisure", ("stadium", "sports_centre")),
    (POI_PARK, "leisure", ("park", "garden")),
    (POI_MONUMENT, "historic", ("monument", "memorial")),
    (POI_ATTRACTION, "tourism", ("attraction", "viewpoint")),
    (POI_HOTEL, "tourism", ("hotel", "hostel", "guest_house", "motel")),
    (POI_MARKETPLACE, "amenity", ("marketplace",)),
    (POI_MALL, "shop", ("mall", "department_store", "supermarket")),
    (POI_PHARMACY, "amenity", ("pharmacy",)),
    (POI_PHARMACY, "healthcare", ("pharmacy",)),
    (POI_BANK, "amenity", ("bank",)),
    (POI_FUEL, "amenity", ("fuel",)),
]


def poi_category(tags):
    """The POI_* code for an object's tags, or None."""
    for category, key, values in POI_TAGS:
        if tags.get(key) in values:
            return category
    return None


# Turkmenistan's bounding box: the extract reaches across the border and
# brings in Makhachkala and Astrakhan. Only a cheap first test - the box
# still holds Mashhad and half of Khorezm, so the builder then checks the
# country's border polygon.
BBOX_SOUTH = 35.0
BBOX_NORTH = 43.0
BBOX_WEST = 51.0
BBOX_EAST = 67.0

# Diacritic folding. Turkmen names use ä, ç, ň, ö, ş, ü, ý and nobody is
# going to type them on a keyboard - "gorogly" has to find
# "Görogly köçesi".
FOLD = str.maketrans({
    "ä": "a", "Ä": "a",
    "ç": "c", "Ç": "c",
    "ž": "z", "Ž": "z",
    "ň": "n", "Ň": "n",
    "ö": "o", "Ö": "o",
    "ş": "s", "Ş": "s",
    "ü": "u", "Ü": "u",
    "ý": "y", "Ý": "y",
    "é": "e", "É": "e",
    "ı": "i", "İ": "i",
    "ğ": "g", "Ğ": "g",
    "ё": "е", "Ё": "е",
})

# What survives in a key besides letters and digits: the slash and the
# hyphen are part of house numbers ("2/4", "12-a"). Commas, periods,
# brackets and quotes become word separators, so that "par 2/4 1" finds
# "Parahat 2/4, 1".
KEPT_PUNCTUATION = "/-"


def search_key(*parts):
    """The key that typed text is compared against.

    Exactly the same function must exist in the Dart reader, or typed
    text will not meet what the names were folded into.
    """
    text = " ".join(part for part in parts if part)
    folded = text.lower().translate(FOLD)
    cleaned = "".join(
        character
        if character.isalnum() or character in KEPT_PUNCTUATION
        else " "
        for character in folded
    )
    return " ".join(cleaned.split())
