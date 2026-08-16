In this endeavor we'll be adding support for DSMEM and Clusters in hopes of further improving MMA performance.


API PHASES

Expand the Crisp API to support `sync-cluster`, `cluster-size`, `:mode :cluster` and `:multicast true`.  

Proposed order of TDD tests and implementation:

- (sync-cluster)  
- autodiff of sync-cluster (if any)
- verify claim that "sync-cluster when cluster size is 1 is identical to sync-workgroup" that is in topology.md
- (declare (cluster-size ...))
- (make-async-barrier :mode :cluster)
- (make-asycn-barrier-ring :mode :cluster)
- autodiff of :mode :cluster
- (load-tile :multicast true)
- autodiff of :muticast

MMA Realization Phase
