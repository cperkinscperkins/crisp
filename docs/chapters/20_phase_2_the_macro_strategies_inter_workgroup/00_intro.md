# **Phase 2: The Macro Strategies (Inter-Workgroup)**


Once your `reduce-workgroup` finishes, every thread of the workgroup holds that workgroup's partial result. To get the final global sum, we must cross the grid boundary.

Crisp offers four Inter-Workgroup strategies to gather these partial results (a fifth, hardware-dependent one is sketched at the end). Because crossing the grid boundary involves hardware trade-offs between memory footprint and execution contention, you should choose the strategy that best fits your algorithm's constraints.

