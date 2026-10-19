## 1.1.0

* Public places: 3,282 airports, stations, hospitals, ministries, markets
  and other named destinations — `searchPublicPlaces`,
  `publicPlacesNear`, `publicPlacesOf`, `PublicPlace`,
  `PublicPlaceCategory`. `search` and its `SearchHit` kinds are unchanged.
* Only what lies inside the country's border polygon is kept: the
  bounding box let in Mashhad and half of Khorezm.
* Fresh OSM data (2026-10-16): 1,941 settlements, 3,166 streets,
  7,091 houses. The asset is 391 KB.
* Database format version 2. Version 1 files still open, with no public
  places.

## 1.0.0

First release.

* Search over the settlements, streets and houses of Turkmenistan.
* A bundled 292 KB database: 2,039 settlements, 3,555 streets,
  6,993 houses.
* `nearestAddress`, `addressesNear`, `housesOn`.
