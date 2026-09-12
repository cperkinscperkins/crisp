# More Tile helpers ✅

```
(position-tile tile-tensor tensor (... grid-y grid-x))
(position-tile-at tile-tensor tensor (... y x))
```

These functions have a very similar API to the load/store tile functions above. But they do not transfer any data, instead they simply update the tile metadata. This is useful when a tile is being used a view into a larger (parent) tensor and you want to move that "window". 


