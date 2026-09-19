# **Phase 2: The Macro Strategies (Inter-Workgroup)**


Once your `reduce-workgroup` finishes, thread 0 is holding a partial sum for its specific workgroup. To get the final global sum, we must cross the grid boundary.

Crisp offers four different Inter-Workgroup strategies to gather these partial results. Because crossing the grid boundary involves hardware trade-offs between memory footprint and execution contention, you should choose the strategy that best fits your algorithm's constraints.

