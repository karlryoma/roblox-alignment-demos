# Alignment demos

Roblox tech demos on camera/perspective alignment illusions — the Monument Valley /
Echochrome / Superliminal / The Room family. Showcase pieces for a developer audience,
not a shipped game: client-only, no server authority, placeholder art on purpose.

| # | Demo | State |
| --- | --- | --- |
| 1 | **Item inspection** — a puzzle box turned in the hand, near-orthographic | built |
| 2 | **Room-scale align-to-unlock** — walk a room, two-step chain | built |
| 3 | Impossible connector | not built |
| 4 | Forced perspective | not built |

## Running it

```
rokit install
rojo serve            # port 34873; Studio: Rojo plugin -> Connect
```

Studio: **File → New** (Baseplate), **Save As** `sandbox.rbxlx` here, connect, press Play.
A loading screen hands over to a menu; pick a demo, and `Q` or the on-screen **EXIT**
returns you to the menu.

Run `rojo serve` from **Windows PowerShell**, not WSL: the file watcher does not fire on
`/mnt/c`, so a WSL-hosted server silently serves a stale tree. Editing
`default.project.json` always needs a server restart.

---

## Demo 1 — Item inspection

<!-- GIF: demo1.gif -->

Drag to turn the box · click or `E` to engage when armed · `R` reset · `Q` leave.

Two anchors sit at different depths inside a 3-stud box, collinear with its pivot. From
exactly one viewing direction they coincide; committing there snaps to the exact solution
and swings the lid open. The box stays turnable afterwards, so further stages can be
authored against whatever the reveal exposed.

**`atan2`, not `acos`.** The obvious test is `acos(ua:Dot(ub))`. At FOV 1 it returns
nothing at all: the lock tolerance is 0.0097°, so `1 - cos(0.0097°) = 1.42e-8` against a
float32 ULP at 1.0 of `1.19e-7` — and Vector3 components are float32. Measured: at the lock
threshold the float32 dot rounds to exactly `1.0`, so `acos` reports `0.000000°` where
`atan2(|a×b|, a·b)` in doubles reports `0.009665°`. `Align.selfTest()` prints both at boot.

**The raw lock window is ~14 mouse pixels wide** — correct, and unhittable. Fixed by damping
the drag gain inside the band and arming the commit at a much wider threshold, never by
loosening the tolerance. Loosening it makes the illusion lie.

## Demo 2 — Room-scale align-to-unlock

<!-- GIF: demo2.gif -->

Walk with WASD · drag to orbit · click or `E` to engage when armed · drag the panel ·
`R` reset · `Q` leave.

Alignment does not spawn or move anything here — it **gates an interaction**. Nothing
teleports and no geometry appears, so nothing can look wrong from an off angle. The chain
is the point: align → the bolts retract and a wall panel becomes draggable → drag it aside
→ a second pair is exposed in the alcove → align again → the door opens. One alignment is a
trick; alignment → action → new alignment is a system.

**Unlock persistence: for one visit.** Everything is rebuilt inside `start()`, so a menu
round-trip resets the room to locked. Persisting across round-trips would mean lifting the
state above `start()/stop()` and *applying* it to geometry on re-entry rather than replaying
the animation.

**The camera is custom, and that was forced.** There is no pitch-clamp property — `Player`
exposes `CameraMaxZoomDistance`, `CameraMinZoomDistance`, `CameraMode`,
`DevCameraOcclusionMode`, `DevComputerCameraMode`, `DevTouchCameraMode`, and nothing for
pitch; the default camera's vertical limit is hard-coded in PlayerModule, which this project
may not require (luau-lsp cannot resolve it through the sourcemap, so it fails the gate).
And a commit that re-poses the view needs `CameraType = Scriptable`, which the default
camera cannot share. So `Orbit` owns the camera, and therefore owns the clamp. Walking still
works: the default control module derives its move vector from `workspace.CurrentCamera.CFrame`.

### Why demo 2 reverses demo 1's FOV, and why that is right

Demo 1 runs at FOV 1. Demo 2 runs at FOV 70. That is not inconsistency.

Roblox has **no orthographic camera** — still an open, unanswered feature request — and
`FieldOfView` is hard-clamped to [1, 120]. The standard approximation is FOV = 1 with a
distant camera, at a required distance of about **57 × the on-screen height of the subject**
(57.29 = 0.5 / tan(0.5°)). At item scale that is free: a 3-stud subject needs ~372 studs
once you frame against its *circumradius* rather than its half-extent, which costs nothing.
At room scale it is not: a 50-stud room needs ~2,850 studs and hits render-distance culling
on low graphics settings.

But the real argument is not cost. **Perspective is better here.** Under orthographic
projection only camera *rotation* changes an alignment, giving a few discrete states. Under
perspective, position **and** rotation change it continuously — and that continuous search
space is the entire "walk around until it lines up" feel. Demo 1 wants the near-ortho look
because a handheld object read at a fixed standoff should not distort. Demo 2 wants
perspective because walking is the verb.

Correspondingly, demo 1's `atan2`-over-`acos` argument is a FOV-1 precision argument and
**does not bind at room scale**: `1 - cos(1°) = 1.52e-4` is about 1,280 float32 ULPs, so
`acos` would be numerically fine at a 1–2° tolerance. Demo 2 still calls `Align.probe`,
because a second hand-written test is exactly the two-sources-of-truth failure this codebase
warns about, and because the *predicates* are the part that matters.

---

## Layout

| File | Role |
| --- | --- |
| `src/shared/Align.luau` | Pure geometry: separation, probe, closed-form solve, hysteresis gate. No Instances. |
| `src/shared/Chain.luau` | Staged alignment: per-stage params, poser list, aim-failure propagation. |
| `src/shared/Session.luau` | Acquire/undo lifecycle. LIFO teardown, guarded start. |
| `src/shared/Shell.luau` | Shell↔demo contract, bind-name registry, per-effect lighting, character helpers. |
| `src/shared/Orbit.luau` | Scriptable third-person camera that follows a walking avatar (demo 2, and 3). |
| `src/shared/Mount.luau` | The near-ortho rig. `Mount.object` (demo 1) / `Mount.orbit` (fixed subject). |
| `src/shared/Spin.luau` | View-sphere state; one integrator for drag, coast and snap. |
| `src/shared/Damp.luau` | Framerate-independent smoothing. Every constant is a time constant. |
| `src/client/init.client.luau` | **The shell.** The only LocalScript: menu, hosting, respawn, global restores. |
| `src/client/Demo1/`, `Demo2/` | The demos. Each is a controller with `start(ctx)` / `stop()`. |
| `src/replicatedFirst/` | The loading screen. Requires nothing from `src/client`. |

`bash scripts/check.sh` — sourcemap + `luau-lsp analyze` + `selene`. Must be 0 errors,
0 warnings.

### Two rules that are not style

**The subject sphere is the anchor pair's own neighbourhood, never the room's.**
`Align.probe` divides by the pair's apparent angular diameter to make the tolerance
dimensionless. `subtendDeg` returns 180 when the eye is *inside* that sphere — so passing
the room's centre and circumradius puts the eye inside it for the whole session, `sepNorm`
silently becomes `sepDeg / 180`, and the demo looks like it works while responding to nothing
you authored. `probe` now fails closed on it, and demo 2 asserts it every frame.

**Thresholds are dimensionless; demo 1's are not portable.** Author the window in degrees and
divide once by the subject subtend (`Chain.fromDegrees`). Feeding raw degrees makes
`Align.closeness` saturate for everything below 1 — a ramp that is flat forever. `minGap` is
the one exception: it is in **studs**, and must be re-derived per stage at roughly half the
baseline, or the wrong-side guard goes toothless exactly where it matters.

## Place settings

`StreamingEnabled` and `FallenPartsDestroyHeight` are set from `default.project.json`'s
`Workspace` node, because neither can be set from a script and the place file is not tracked
— so a fresh clone reproduces them without anyone touching the Properties panel.

## Porting to demos 3–4

Demo 3 (camera orbits a fixed monument) reuses `Align`, `Chain`, `Session`, `Shell` and
`Orbit` unchanged, and swaps `Mount.object` for `Mount.orbit`. The alignment test is written
in world space against whatever pose was actually rendered this frame — it does not care
whether the object moved or the camera did.

Demo-1-only: `Demo1/Stage.luau`, and `Feedback.halo`, whose rest poses are captured in world
space and only hold while the camera is parked.
