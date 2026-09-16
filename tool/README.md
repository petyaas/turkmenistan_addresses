# Building the address database

`build_address_db.py` turns an OpenStreetMap extract into
`assets/turkmenistan.adb`; `address_db_format.py` describes the file
format and folds names into search keys.

```bash
python3 -m venv .venv && .venv/bin/pip install osmium
.venv/bin/python build_address_db.py ../turkmenistan.pbf ../assets/turkmenistan.adb
```

The build takes about twelve seconds and prints exactly what it dropped
and why — junk house numbers, duplicate settlements, houses mapped twice,
houses with no street nearby.

`address_db_format.py` and `../lib/src/address_db.dart` describe the same
binary layout. **Change one and you must change the other**, raising
`FORMAT_VERSION` and `AddressDatabase.formatVersion` together: the loader
refuses a version it does not know rather than reading garbage.

The same goes for `search_key` here and `normalize` in
`../lib/src/address_search.dart`: let them drift apart and typed text
stops meeting the stored names, silently and completely. A test in
`../test/address_db_test.dart` guards exactly that.
