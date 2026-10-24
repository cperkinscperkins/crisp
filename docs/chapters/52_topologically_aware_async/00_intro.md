# Topologically Aware Async


```
(let ((barrier (make-async-barrier)))

  (load-tile A A-tile (... grid-y grid-x) :transpose <bool> :identity <val> :barrier barrier)
  (load-tile-at A A-tile (... y x) :transpose <bool> :identity <val> :barrier barrier)

  (store-tile C-Tile C ( ... grid-y grid-x) :transpose <bool> :transformF <func> :barrier barrier) ;; illegal to use transfomF and barrier together.
  (store-tile-at C-Tile C ( ... y x) :transpose <bool> :transformF <func> :barrier barrier) ;; illegal to use transfomF and barrier together.

  (await barrier)

  (signal barrier))

```

