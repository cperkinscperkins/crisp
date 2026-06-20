
The previous endeavor (117) changed the load-tile/store-tile and async APIS. It touched a lot of tests.

But there is still a long punch list of things that need to be tended. I'm starting a new endeavor for these.

Let's break these up into individual passes instead of doing everything at once.
Pass 1
- [x] (await barrier) maps to cp.async.wait_all , not individual barriers.  
       It should wait on just the named barrier.  If this is an issue, let me know and we can discuss.
- [x] need test(s) for above. should go in the 118-async-misc directory 

Pass 2.  I may add a task here.  
In Crisp "barrier" denotes memcopy/data movement, and "sync" denote thread synchronization. 
- [x] rename local-barrier => sync-workgroup
- [x] sync-warp

Pass 2.5 - arrival sync primitives
(make-arrival-sync count) : A thread-count barrier. Returns a handle used by the consumer to block until `count` threads have called (sync-arrive). Implementation uses a global atomic counter.

(sync-arrive sync-handle) : non-blocking. Puts one "unit" into the sync bucket.
(sync-wait sync-handle) : blocks until "count" units have been put into the sync bucket.

- first: need testing added to the 118-async-misc directory.
        including negative tests (under /error)
- second: implement.

Pass 2.7
- [x] load-local and store-local with :barrier arg

Here are the relevant docs

#### Scratch Helpers

Important: These helpers support a `:barrier` key for asynchronous execution.  See [Async Memory Operations](#async-memory-operations) for more information. 

```
(load-local global-tensor scratch-tensor &key identity barrier)
(store-global scratch-tensor global-tensor &key (transformF #'identityF) barrier)

(load-tile ...) 
(store-tile ...)

```

`load-local` and `store-global` simply copy data between a global tensor and a scratch one. There is no "positioning" of the tensors relative one another. These are most straightforward to use if the two arguments are the same size. But, in the event they are not the same size, the bytes moved are limited by the smaller of the two.  

`load-tile` and `store-tile`, on the other hand, have positioning arguments and that determine what section of the global tensor is copied to/from. See topology.md for details. 





Pass 2.8
- [x] there should not be any real need for any "request-XXXX" functions anymore.
So request-load-tile request-store-tile, etc can be removed because load-tile/store-tile has :barrier args now.  Remove all request-XXXX from the compiler .

Pass 2.9
- [x] position-tile  / position-tile-at
- [x] with tests

Docs for this:

### More Tile helpers
```
(position-tile tile-tensor tensor (... grid-y grid-x))
(position-tile-at tile-tensor tensor (... y x))
```

These functions have a very similar API to the load/store tile functions above. But they do not transfer any data, instead they simply update the tile metadata. This is useful when a tile is being used a view into a larger (parent) tensor and you want to move that "window". 



DO NOT IMPLEMENT THIS. SEE the strategy.md file instead
Pass 3.  I'll definitely be adding more to this one. maybe it should be its own endeavor. We'll see.
Before we can start this, I will need to update some documentation about it.
- [ ] strategy :tiled so we can get hoist testing. 
