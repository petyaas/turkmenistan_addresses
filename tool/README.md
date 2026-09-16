# Сборка адресной базы

`build_address_db.py` делает `assets/turkmenistan.adb` из экстракта OSM,
`address_db_format.py` описывает формат файла и сворачивает названия в
ключи поиска.

```bash
python3 -m venv .venv && .venv/bin/pip install osmium
.venv/bin/python build_address_db.py ../turkmenistan.pbf ../assets/turkmenistan.adb
```

`address_db_format.py` и `../lib/src/address_db.dart` описывают один и тот
же двоичный layout. **Меняешь один — меняй и другой**, с подъёмом
`FORMAT_VERSION` и `AddressDatabase.formatVersion`: загрузчик отказывается
читать чужую версию, а не разбирает мусор.

То же касается `search_key` здесь и `normalize` в
`../lib/src/address_search.dart`: разойдутся — и набранный текст
перестанет встречаться с названиями, молча и целиком. За этим следит тест
`../test/address_db_test.dart`.
