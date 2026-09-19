# **Reductions: Shop Local, Act Global 📝**


A fundamental reality of GPU programming is that coordinating threads is cheap locally and expensive globally. A very common practice among GPU algorithm writers is "shop local, act global."

In this practice, a small amount of local memory (or register space) is operated upon by the threads in a single workgroup. Once the workgroup has reduced its data down to a single local value, one leader thread "acts global" by combining that local result with the results from all the other workgroups across the grid.

Crisp embraces this reality. We don't provide a single, monolithic, "one-size-fits-all" reduction. Instead, Crisp provides composable building blocks based on a two-phase strategy:

* **Phase 1: The Micro Strategy (Intra-Workgroup).** How do threads *within* a workgroup combine their data?
* **Phase 2: The Macro Strategy (Inter-Workgroup).** How do the workgroups safely combine their partial results into a final global answer?

By mixing and matching these strategies, you can tailor your reductions for speed, simplicity, or hardware capabilities.

---

