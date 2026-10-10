---
type: architecture
description: Agent orientation for excerpt — state, layout, conventions, branch and release model.
---

# excerpt — agent notes

A macOS menu-bar screenshot tool in Swift (SwiftPM, macOS 15+). The architecture of record is
[docs/design.md](docs/design.md); what's next is [docs/roadmap.md](docs/roadmap.md) — start
there before planning work.

**State:** Phase 0 (Core) shipped; Phase 1 (capture shell) built, real-app hand checks pending. Next: Phase 2, the editor.

`just gate` per change; `just run` launches a signed build.

## Conventions

- **Core is pure.** Anything testable without a screen or a permission — rendering, cut
  geometry, stitching, tiling, gap detection — lives in `ExcerptCore` as functions over values.
  Capture, the editor and the app stay thin.
- **One renderer.** The editor draws through Core's renderer; never add a second drawing path
  for on-screen preview.
- **The primary file is clean.** Nothing the user removed — cut bands, blurred pixels, the
  original — may be embedded in the dated primary PNG. The original and the edits live only in
  `… original.png`.
- **Golden images** pin the renderer; a deliberate visual change regenerates them in the same
  commit. `EXCERPT_RECORD_GOLDENS=1 swift test` re-records goldens; inspect every recorded PNG
  before committing it.

## Branch and release model

`main` + `dev`. Work lands on `dev`; `main` advances only by `git merge --ff-only dev` at a
release, or by a docs-only commit forward-merged into `dev` straight after. The version's one
source is the tracked root `VERSION` file; a release tags `v<version>` and publishes a GitHub
release with notes. No CI: excerpt ships on macOS only, so the local `just gate` is the check.
