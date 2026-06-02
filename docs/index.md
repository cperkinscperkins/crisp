# Crisp Language Specification 🚧

Welcome to the Crisp compiler and language specification documentation. Crisp is a Lisp dialect designed specifically for writing safe, high-performance, and correct GPU kernels.

---

## Navigation Guide

Get started by exploring the key sections of our documentation:

*   **[Language Specification](ideal_001.md)**: The full, single-page living specification for the Crisp language. It outlines the design goals, syntax, types, storage handles, control flow constructs, and compilation targets.
*   **[The Blueprint Philosophy](crisp-curios.md)**: A concise list of features and constraints that make Crisp unique and set it apart from other languages and traditional compilers.
*   **[Crisp Codebase Reference](reference.md)**: A complete, automatically generated reference detailing all functions, macros, and symbols inside the compiler implementation.
*   **[Crisp Testing Guide](tests.md)**: A guide detailing the test-driven development (TDD) harness, specifications, and the "spine" test directives.
*   **[Benchmarks](benchmarks.md)**: Performance benchmarks comparing Crisp to alternative GPU acceleration frameworks.
*   **[Criticisms](criticsms.md)**: Open feedback, critiques, and resolved design issues.
*   **[Elevator Pitches](elevator_pitches.md)**: Quick conceptual summaries of what Crisp aims to achieve.

---

## Current Project Status

Crisp is currently in active development. As the compiler implementation moves forward, it continuously refines and informs the specification documented here. Each section of the [Language Specification](ideal_001.md) features status tags:
- `✅` **Completed**: Fully implemented, codegen validated, and covered by E2E test specs.
- `⚠️` **Partially Implemented**: Under development, partially working, or has known constraints.
- `📝` **Planned / Inactive**: Outlined in design but coding has not yet begun.
