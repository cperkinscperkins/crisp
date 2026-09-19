# `load-tile-at` ✅


`(load-tile-at src dest (... y x) &key transpose identity barrier) => nil`

Functions identically to `load-tile`, but instead of using logical Tile IDs, the location is specified using exact **Element Coordinates** (the specific scalar index offsets, such as the top-left pixel). This is necessary for unaligned loads, halo exchanges, or ragged boundary processing.

Note that, unlike `load-tile`, this does NOT accept the `:multicast` key. This is because proper resolution for multicast requires tile grid coordinates. 

