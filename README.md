# face_ios_android

On-device face verification — Flutter port of the Android Native `FaceVerfication` app.

> **Source-of-truth Android project:** `D:\Development Projecrts\FaceVerficationFlutter`
> **Migration documentation:** [`docs/migration/`](docs/migration/00_INDEX.md) — read this first.

## Status

Phase 1 complete: app scaffold, Riverpod, Drift, theme, router, security/permission gates, encrypted template wrapper. Live camera, embedding extraction, matching, and the enrollment/verification screens land in Phases 2–3 (see `docs/migration/12_effort_estimation.md`).

## First-time setup

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

The codegen step is required — Drift generates `app_database.g.dart` and `user_dao.g.dart` from the `@DriftDatabase` and `@DriftAccessor` annotations. Without it, the app will not compile.

During active schema work, run a watcher instead:

```bash
dart run build_runner watch --delete-conflicting-outputs
```

## Run

```bash
flutter run                      # debug
flutter run --release            # release
flutter test                     # unit + widget tests
flutter analyze                  # static analysis
```

## Repository layout

The full layout is documented in `docs/migration/08_folder_structure.md`. Highlights:

```
lib/
├── app/             MaterialApp + theme + GoRouter
├── core/            constants, DI, error types, platform glue
├── data/database/   Drift schema, DAOs
├── features/        feature-scoped UI + controllers
└── services/        face detection / recognition / matching (Phase 2+)
```

## Asset

`assets/models/mobile_facenet.tflite` must be copied verbatim from the Android project at:

```
D:\Development Projecrts\FaceVerficationFlutter\app\src\main\assets\mobile_facenet.tflite
```

This step is part of Phase 2 (TFLite integration). The folder is declared in `pubspec.yaml` and ready to receive the file.

## Documentation

| File | Purpose |
|---|---|
| `docs/migration/00_INDEX.md` | Entry point with reading-order recommendations |
| `docs/migration/01_project_analysis.md` | Inventory of the Android baseline |
| `docs/migration/07_architecture.md` | Why Riverpod + Clean-Lite |
| `docs/migration/12_effort_estimation.md` | Phase plan and milestones |

## Tests

```bash
flutter test                                      # all unit + widget tests
flutter test test/unit/core/byte_layout_test.dart  # parity test for Converters.kt port
```
