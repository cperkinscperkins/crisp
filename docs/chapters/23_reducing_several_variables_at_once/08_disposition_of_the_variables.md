# Disposition of the Variables


* **`reduce-warp`**: Every lane of the warp receives the final reduced value(s) in its bound
  variables.
* **`reduce-workgroup`**: Every thread of the workgroup receives the final reduced value(s).
  Every reduced variable is `uniform` afterward.
* **`grid-reduce!`**: Results are written to the clauses' return cells. The local variables
  holding the partial states are indeterminate afterward.

*Execution constraint:* Every thread of the warp or workgroup must reach the call. Reductions
cannot be placed inside divergent control paths.

