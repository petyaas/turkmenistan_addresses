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
street is a name and a reference to a settlement.

File: [32-byte header][section table, 16*8 bytes][sections, 4-byte aligned]

There is deliberately no spatial index: with thirteen thousand entries a
full scan is cheaper than a grid held in memory.
"""

MAGIC = b"TMAB"
FORMAT_VERSION = 1

HEADER_BYTES = 32
SECTION_COUNT = 16
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

# Turkmenistan's bounding box: the extract reaches across the border and
# brings in Makhachkala and Astrakhan.
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
