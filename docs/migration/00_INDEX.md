# Android → Flutter Migration Documentation Index

**Source project:** `D:\Development Projecrts\FaceVerficationFlutter` (Android Native, Kotlin/Compose, package `com.thanaraj.faceverfication`)
**Target project:** `D:\Development Projecrts\face_ios_android` (Flutter, currently empty `main.dart` boilerplate)
**Status:** Documentation phase complete. **No Flutter implementation code has been written yet.** Awaiting user approval to proceed.

---

## How to read this set

If you have 5 minutes, read **01_project_analysis** and **07_architecture**.
If you are scoping the work, read **12_effort_estimation** and **11_risks**.
If you are implementing, follow the order: **07 → 08 → 05 → 03/04 → 06 → 09 → 10 → 13**.

---

## Documents

| # | Document | Purpose |
|---|----------|---------|
| 01 | [Project Analysis](01_project_analysis.md) | Inventory of every component in the Android project: classes, screens, dependencies, dead code, native module |
| 02 | [Feature Mapping](02_feature_mapping.md) | Each Android feature → Flutter equivalent + chosen package |
| 03 | [Screen-by-Screen Migration](03_screen_migration.md) | Each Compose screen → Flutter widget tree, state, callbacks |
| 04 | [API Integration Mapping](04_api_mapping.md) | All "API surfaces" — none are external; documents the SDK module API and how it maps to Flutter services |
| 05 | [Database Migration](05_database_migration.md) | Room → Drift mapping, schema, BLOB encoding, migration strategy |
| 06 | [Dependency Mapping](06_dependency_mapping.md) | Gradle library → pubspec.yaml package, with rationale and unused entries |
| 07 | [Architecture Recommendation](07_architecture.md) | Riverpod + Clean-Lite layers, why, how, with diagrams |
| 08 | [Folder Structure](08_folder_structure.md) | Concrete `lib/` layout the team will follow |
| 09 | [Performance Optimization](09_performance.md) | YUV→tensor pipeline, isolates, GPU delegate, thresholds |
| 10 | [Security & Encryption](10_security.md) | Template encryption, root/emulator, secure storage, permissions |
| 11 | [Risks & Dependencies](11_risks.md) | Technical risks, plugin maturity, iOS gaps, mitigations |
| 12 | [Effort Estimation](12_effort_estimation.md) | Module-by-module hours/days, phases, milestones |
| 13 | [Test Strategy](13_test_strategy.md) | Functional, UI, integration, performance, manual scenarios |

---

## Source-of-truth corrections vs. existing Android docs

While reading the Android project, two factual errors in the existing docs were noticed and corrected here:

1. **`Converters.kt` storage format** — `application_performance.md` claims templates are stored as Gson JSON strings. The actual code uses **little-endian `ByteBuffer`** with size guards (list size 0–1000, array size 0–10000, total ≤ `Int.MAX_VALUE`). All migration docs treat ByteBuffer as authoritative.
2. **`FaceData.landmarks` type** — `AGENTS.md` shows `Map<FaceLandmark, PointF>`. Actual code uses `Map<Int, PointF>` (ML Kit landmark types are `Int` constants like `FaceLandmark.LEFT_EYE = 4`).

Both corrections are reflected in the migration mapping.

---

## What was deliberately not done

Per the source prompt's instruction *"Generate documentation before implementation. Ask for confirmation before generating Flutter code implementation"*:

- No Dart/Flutter source files were created.
- No `pubspec.yaml` modifications were made.
- The existing Flutter scaffold (`lib/main.dart` boilerplate) was left untouched.

The next step requires explicit user approval — see the bottom of [12_effort_estimation.md](12_effort_estimation.md) for the proposed phase plan.
