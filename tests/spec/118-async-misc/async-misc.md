
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

Pass 3.  I'll definitely be adding more to this one. maybe it should be its own endeavor. We'll see.
Before we can start this, I will need to update some documentation about it.
- [ ] strategy :tiled so we can get hoist testing. 
