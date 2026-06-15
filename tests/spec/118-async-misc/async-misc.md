
The previous endeavor (117) changed the load-tile/store-tile and async APIS. It touched a lot of tests.

But there is still a long punch list of things that need to be tended. I'm starting a new endeavor for these.

Let's break these up into individual passes instead of doing everything at once.
Pass 1
- [x] (await barrier) maps to cp.async.wait_all , not individual barriers.  
       It should wait on just the named barrier.  If this is an issue, let me know and we can discuss.
- [x] need test(s) for above. should go in the 118-async-misc directory 

Pass 2.  I may add a task here.  
In Crisp "barrier" denotes memcopy/data movement, and "sync" denote thread synchronization. 
- [ ] rename local-barrier => sync-workgroup
- [ ] sync-warp

Pass 3.  I'll definitely be adding more to this one. maybe it should be its own endeavor. We'll see.
Before we can start this, I will need to update some documentation about it.
- [ ] strategy :tiled so we can get hoist testing. 