Not sure this endeavor deserves its own directory.


In endeavor 111 we added a synchronous (load-tile ...) and (store-tile ...) support.

Then in 113 we added asynchronous versions of the same: (request-load-tile ...) and (request-store-tile ...) and (await-request req)

Unfortunately, that design has issues that prevent it from expanding when we want to make the async "topologically aware" and use them for data transfers across the fabric.    So the API is being changed.

The full API document for all async and topology related stuff is in docs/topology.md  
Today we are NOT realizing all that.  It has to wait. Instead we are just revisiting the implementation we did before this API change and fixing it, updating it.

1. the tile-stride aware helpers load-tile and store-tile are going away. No more tile-stride aware helpers. We always require grid coords. (... grid-y grid-x) for the "nth" tile in the grid of the tile over the problem space. 
2. load-tile and store-tile now take a &key :barrier <barrier> arg.  When not present, they are synchronous, when present they are asynchronous.
3. We are adding a (make-async-barrier) routine that returns a barrier object that can be used by laod-tile and store-tile.
   Ultimately, this will be a topologically aware routine that knows the topology when the kernel is being compiled, but not today.  Also, it'll most likely need a CuTensorMap argument in the future, which will be an implicit ("side channel") arg to the kernel like scratch Storage Handles are today. But I'm guessing we won't need that quite yet.
4.  (await-request req) just becomse (await barrier)
5. the request-load-tile and all request-xxxx variants should be removed.
6. load-tile-at should be renamed to load-tile-at and it takes straight ...y, x as position args, and it ALSO takes a :barrier key.
7. :barrier cannot be used with :transformF at the same time. we should error.

Obviously, we'll need the compiler code changed, but also the pre-existing tests and possibly their validators.

We'll probably need some new tests, esp for make-async-barrier.

Testing

Let's Audit the tests to make sure we have tests that cover these situations.
If we do not, we'll write new ones

- load-tile take grid indices, load-tile-at takes absolute coords.
- same with store-tile store-tile-at.
- :barrier can't be used with :transformF at the same time - error.
- all four (load-tile/load-tile-at/store-tile/store-tile-at) compile and work with and without barrier.
  without :barrier: synchronous.  with :barrier: asynchronous.

Second
- many of the existing tests of tile-stride and hardware-stride pass, but they are written
  with outdated, or even incorrect, coord terminology.  I'd like to shore them up.  "grid-x" is the term for grid indices 
  and that is what the bindings of tile-stride and hardware-stride are.    "x" "y" are coordinates.
  Ideally, we should not use terms like "idx-y" or "orig-x" anymore
- if you encounter a test that has a fundamentally wrong expectation, let me know. 