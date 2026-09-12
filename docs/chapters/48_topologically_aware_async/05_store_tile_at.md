# `store-tile-at` ✅


`(store-tile-at src dest (... y x) &key transpose transformF barrier) => nil`

Functions identically to `store-tile`, but uses exact **Element Coordinates** rather than logical Tile IDs to position the data in the destination tensor.

