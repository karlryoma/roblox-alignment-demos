# Alignment demos

Roblox tech demos on camera/perspective alignment illusions — the Monument Valley /
Echochrome / Superliminal / The Room family. Showcase pieces for a developer audience,
not a shipped game: client-only, no server authority, placeholder art on purpose.

| # | Demo | State |
| --- | --- | --- |
| 1 | **Item inspection** — a puzzle box turned in the hand, near-orthographic | built |
| 2 | **Room-scale align-to-unlock** — walk a room, two-step chain | built |
| 3 | **Impossible connector** — align to create a real bridge, then walk it | built |
| 4 | **Monument Valley traversal** — baked screen-space connectivity, rotate the world | built |

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
`R` reset · `Q` leave. On touch the capture surface takes the right half of the screen
only, so the default thumbstick still works.

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

## Demo 3 — Impossible connector

<!-- GIF: demo3.gif -->

Walk with WASD · drag to orbit · click or `E` to engage when armed · `R` reset · `Q` leave.

Demo 2 proved alignment can *gate* an interaction. This is the payoff: alignment **creates
real geometry you walk across**. Line up two sockets 40 studs apart in depth, commit, and a
connector materialises along the true 3D line between them. Then the camera stops mattering —
the bridge is real, it stays, and you cross it with your actual avatar. Crossing exposes a
second pair, and a second connector reaches the goal.

**This is the only demo of the four whose result is coherent from every camera in the
server.** Demos 1, 2 and 4 are camera-relative and inherently single-viewer: the illusion
lives inside one player's projection, and a second player standing beside them sees nothing.
Here the alignment is merely the *trigger*; what it produces is world-space geometry every
client would agree about. That is the difference between a trick and a mechanic that could
ship in a multiplayer game.

**Owning the seam.** From the locking seat the connector is foreshortened to nothing — that
is the illusion. From every other angle it is a long beam hanging in space, and no amount of
care hides that. So it is deliberately **stylised**: floating slabs with a Neon spine that
assemble in sequence from the near anchor outward. A concrete plank bridge read off-angle
looks like a bug; a light bridge that built itself looks like something you cast. The
materialisation also covers the single frame in which the geometry appears.

**Anchors differ in depth, never in height.** The connector is a real 3D line, so a pair
separated vertically would look flat from the locking seat and be a steep ramp in world
space — still walkable (`Humanoid.MaxSlopeAngle` defaults to 89°) but wrong to walk. Both
pairs are dead level, and the slope is asserted at boot. Depth separation is also the
*stronger* illusion, because depth is exactly what the eye cannot judge.

**A deviation worth naming:** the subject sphere here is sized on the marker art rather than
the usual half-the-baseline. With a 40-stud baseline in an open exterior, a half-baseline
sphere is 21 studs across the middle of the chasm and the orbit camera — which swings ~10.5
studs past the player — enters it during ordinary walking, where `probe` fails closed and the
HUD would shout STEP BACK for no reason. The normalisation is valid for any radius (`sepNorm`
reduces to perpendicular-offset / 2r, with viewing distance cancelling either way); the radius
only sets the scale. Clearance from every standable spot is asserted numerically: +3.5 studs
for stage 1, +3.0 for stage 2.

## Demo 4 — Monument Valley traversal

<!-- GIF: demo4.gif -->

← → rotate the view · `F` turns the bridge · click a tile to walk there · `R` reset · `Q` leave.
**Wants high graphics settings** — see the caveat below.

The capstone, and deliberately the odd one out. Demos 1–3 all measure the angle subtended at
the eye — a perspective quantity — and commit on alignment. This one does neither. It is a
**baked screen-space connectivity graph under an orthographic projection**, traversed by a
puppet. It uses `Session`, `Shell`, `Hud` and `Damp`; it does not use `Chain`, `Orbit`,
`Mount`, `Spin` or `Align.probe`, because angular-at-eye is the wrong measure and contorting
those modules to fit would have produced a worse version of both.

**The architectural insight is the whole demo.** The camera snaps to four fixed angles and the
sub-model to four positions, so there are only sixteen connectivity graphs — bake them all.
That decouples two things that look coupled:

- **Rendering** uses the FOV-1 approximation and only has to fool the eye.
- **Gameplay logic** uses a mathematically exact orthographic projection computed in
  `Graph.project` — drop the depth component in camera space.

So the illusion being approximate never leaks into correctness. There is no runtime
screen-space measurement, no floating-point drift, and no per-frame cost: a click is answered
by a table lookup and a BFS over a few dozen edges.

Authoring an impossible join is exact rather than fitted: under a true isometric view
(elevation 35.264°) two nodes coincide in the 45° state precisely when their difference is
parallel to (1,1,1). So a join *is* adding (k,k,k) to a node.

Verified before the code was reviewed: all four camera states produce different virtual edges,
**no single (camera, sub-model) combination reaches the goal** — rotation is genuinely
required, not decorative — and the monolith rejects exactly one coincidence as hidden, so the
visibility rule is load-bearing rather than a no-op.

**Crossing a virtual edge is a snap, not a slide.** Roblox gives no per-object depth sorting,
so a puppet straddling two depths cannot be rendered correctly. Monument Valley teleports
across the seam for the same reason.

**The honest caveat.** At FOV 1 the camera sits ~2,400 studs out, and on low graphics settings
the engine may cull the level entirely. A script *cannot* force quality — `settings()` is
plugin-security and throws in a live game. The HUD says so. For a demo that gets filmed on max
settings this is acceptable, but it is a real limitation rather than a hidden one. Worst-case
perspective residual at a virtual edge is 1.2 px at 1080p, and zero at frame centre.

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
| `src/client/Demo1/`…`Demo4/` | The demos. Each is a controller with `start(ctx)` / `stop()`. |
| `src/client/Demo4/Graph.luau` | Exact ortho projection, the graph baker, BFS. Knows nothing about `Align`. |
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

## What is shared, and what is not

`Align`, `Chain`, `Session`, `Shell` and `Damp` carry demos 1–3. `Orbit` carries
demos 2 and 3 — the same follow camera, with demo 3 widening the pitch clamp to -30° because
its anchor line sits only 1.2 studs above the deck and the eye has to get *down* to it.

Demo-1-only: `Mount` (a fixed-centre near-ortho rig, wrong for a walking player), `Spin`, and
`Feedback.halo`, whose rest poses are captured in world space and only hold while the camera
is parked.

Demo 4 shares only `Session`, `Shell`, `Hud`, `Damp` and `Align.fromSpherical` (to place the
four camera states). Its measure is *coincidence under a parallel projection*, which has no eye
in it at all — so it brings its own `Graph` module rather than bending `Align` to fit.
