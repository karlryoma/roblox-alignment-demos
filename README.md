# Alignment demos

Roblox tech demos on camera/perspective alignment illusions — the Monument Valley /
Echochrome / Superliminal / The Room family. Showcase pieces for a developer audience,
not a shipped game: client-only, no server authority, placeholder art on purpose.

| # | Demo | State |
| --- | --- | --- |
| 1 | **Item inspection** — a puzzle box turned in the hand, near-orthographic | built |
| 2 | **Room-scale align-to-unlock** — walk a room, two-step chain | built |
| 3 | **Dwell to weave** — hold the camera still and coincident surfaces connect | built |
| 4 | **Locked isometric** — four fixed angles, a turning bridge, sixteen baked graphs | built |

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

## Demo 3 — Dwell to weave

<!-- GIF: demo3.gif -->

Walk with WASD · drag to orbit · **hold the camera still to weave** · `R` reset · `Q` leave.

Your own Roblox character, walking a Monument Valley-ish building with normal Humanoid
movement. Two surfaces that **coincide on screen are connected** — but only once the camera
settles. While you are turning, the world is inert. Stop for a beat and the coincidences
crystallise: the seams light up, and walking into one continues you onto the surface that
looked joined, which is somewhere else entirely in world space.

There is no commit button and no authored anchor pair to line up. The building's whole
connectivity is a function of the camera angle — which is what separates this from demo 2,
where alignment unlocks one authored thing. Here **alignment is the level's topology**.

**Why not FOV 70.** A crossing jumps the character ~21 studs in depth. Under a close
perspective camera that would visibly pop its size, and so would every other relationship in
frame. `H = 2·D·tan(FOV/2)`, so FOV 6 at 400 studs frames a ~42-stud-tall view; a 20.8-stud
depth jump then changes apparent size by **5.2%** — about 3 px on a 60 px character, gone in a
single frame. A deliberate middle ground between demo 1's FOV 1 at 372 studs and a normal game
camera, and 400 studs is comfortably inside safe render distance.

**The camera frames the building, not the character.** If it followed the avatar it would be
dragged 21 studs along the view ray on every crossing and the whole scene would lurch. Framing
the building means only the character changes depth, by its own small amount.

**The crossing is a pure translation**, applied in one frame with no interpolation, and the
velocity is deliberately *not* zeroed — smooth movement is the entire point. That is only legal
because paired seam nodes share a surface normal and have **opposite outward directions**;
`Seam.orientationFault` asserts it at boot, because a mismatched pair would silently mangle
velocity.

**How a seam is authored, and a correction.** Under a *parallel* projection two points coincide
exactly when their difference is parallel to the view direction, so at the isometric pitch a join
is an offset of (k,k,k): `A_end → B_start` is (12,12,12) and lives at yaw 45°; `B_end → C_start`
is (−8,−8,8) and lives at yaw 135°. Neither is live at the other's angle, so the route needs
both.

But Roblox renders in **perspective**, and the test now measures what is actually drawn: the
angle the two points subtend at the eye, which is zero exactly when they land on the same pixel.
An earlier version tested the idealised parallel projection, which is not the same thing —
perspective separates two points by roughly (distance from frame centre) × (depth between them)
÷ (camera distance), so a seam composed off-centre would look apart while the logic insisted it
was joined. These two seams sit near frame centre, so they measure 2.0 px and 3.6 px apart at
the real eye; the editor's SOLVE zeroes that.

**Deliberate limitation: every walkable surface is a floor.** Roblox gravity is global −Y with
no per-character override, so Monument Valley's walls-become-floors moments are out unless the
Humanoid is abandoned — which is the one thing this design exists to keep. Most MV traversal is
flat walkway anyway, so the illusion still reads.

## Demo 4 — Locked isometric

<!-- GIF: demo4.gif -->

Walk with WASD · ← → rotate the view · `F` turns the bridge · `R` reset · `Q` leave.
**Wants high graphics settings** — see the caveat below.

The capstone: **demo 3 with the camera taken away from the player.** Demo 3 gives a free orbit
and makes screen-space connections live only once the camera settles. Here the camera snaps
between four fixed isometric angles, so it is *always* settled — nothing to wait for, and the
seams are live the instant a rotation lands. Same character, same walking, same `Seam` core.

**The bake is the architectural point.** Four camera states × four sub-model positions = sixteen
connectivity graphs, all computed at `start()`. Because the camera has finitely many poses,
connectivity is a finite table rather than a per-frame measurement: no runtime screen-space
maths, no drift, and a click is answered by a lookup.

The test inside each bake is the angle the two points subtend **at the eye** — zero exactly when
they are drawn on the same pixel. (An earlier version tested an idealised parallel projection on
the theory that exact logic could not inherit the render's approximation. That was backwards:
the player judges the picture, so the picture is the authority.) The bake summary prints at
boot — per-state seams, the angle each coincides at, and an assertion that no single state
reaches the goal.

**The route needs both rotations.** `S_end → R_a` is live only at yaw 45° with the bridge at
rest; `R_b → T_start` only at yaw 135° with the bridge turned once. The bridge's seams are
Attachments *on the rotating part*, so their outward directions turn with it — which is why
`Seam` derives orientation from `Attachment.WorldCFrame` rather than storing it. Stand on the
bridge when it turns and you are carried by the same rigid delta, as in Monument Valley.

**The rendering budget, derived.** `FieldOfView` is clamped to [1, 120] and
`H = 2·D·tan(FOV/2)`. This level projects to ~54 studs of on-screen height across the four
states, so: FOV 1 → 3,468 studs (1.3 px seam residual); FOV 2 → 1,734 (2.6 px); **FOV 3 →
1,156 (3.9 px)**; FOV 4 → 867 (5.2 px). Every one is inside the ~10 px budget, so the deciding
factor is *distance*, not orthographic purity — Roblox's level-of-detail is **distance**-based,
not screen-size-based. The engine does not know the character occupies 89 px; it sees an avatar
1,156 studs away and may simplify it, and graphics quality is a client setting a script cannot
override (`settings()` is plugin-security and throws in a live game). FOV 3 is the smallest
standoff that still reads as parallel.

**That risk is untested.** Nothing in this repo has run in Studio, so how the avatar actually
renders at 1,156 studs is unknown. `TUNE.fovDeg` is the single number to change: 4 costs 867
studs and 5.2 px, 6 costs 578 studs and 7.7 px.

## Editing the maps

**`M` in demo 3 or demo 4 opens a live map editor.** (Not `F2` — Studio binds that to Rename
and swallows it before the game sees it. `F2` still works in a published place.)

These illusions are composed by eye. The maths that makes two points coincide is exact and
easy; deciding *which* two things should appear to touch, from *which* angle, so the shot reads
well, is a judgement about a picture. Authoring those numbers blind produces geometry that is
arithmetically perfect and visually wrong — which is what happened.

| key | |
| --- | --- |
| `M` | open / close the editor |
| `[` `]` | select entry (one per surface-and-seam) |
| `←` `→` `↑` `↓` | move the selected surface **on screen** |
| `PGUP` `PGDN` | move it **in depth** — free under a parallel projection, and the readout proves it |
| `-` `=` | step size, 0.25 → 5 studs |
| `ENTER` | **SOLVE** — put this seam on the same pixel as its partner |
| `Z` | **FLIP** — swap which surface draws in front |
| `;` `'` | choose a reference object from the depth stack |
| `HOME` / `END` | constrain: must be **in front of** / **behind** the reference |
| `\` | clear this surface's ordering constraints |
| `BACKSPACE` | undo all moves to this surface |
| `P` | print the edits as paste-ready Luau |

**Choosing what draws in front.** Roblox has no per-object draw order — occlusion is decided
entirely by distance from the camera. So "put this walkway in front of that one" *is* "move it
toward the eye", which under these near-parallel projections barely touches the picture:
`PGUP`/`PGDN` move the selected surface along the view axis, and `Z` mirrors it to the other
side of its partner in one press. Verified: a flip leaves the seam's screen separation bit-identical
(0.0099° before and after) and only the occlusion order changes.

**Cycles are possible, and the tool models them.** "A in front of B, B in front of the pole, the
pole in front of A" has no total order along the view axis — but a z-buffer doesn't sort objects,
it sorts *pixels*. If the three overlaps happen at three different places in frame, each resolves
its own way and the cycle renders perfectly. That is exactly how a Penrose triangle is built out
of three ordinary beams.

So each constraint is measured by casting a ray through the place that pair actually overlaps,
not by comparing whole-object depth ranges (which forces a total order and calls every cycle
impossible — a limit of the tool, not of the engine). Verified: three bars in a pinwheel settle
into a genuine cycle after relaxation, moving 1–4 studs each.

The catch is that **the pairs must overlap on screen**. Two objects that don't overlap can't
occlude each other at all, so there is nothing to order and the editor says so. In demo 3 as it
ships, surfaces A and B overlap but the poles overlap neither — so a three-way cycle there needs
the pole moved into the overlap first.

**Ordering against named things.** "In front of the pole but behind that platform" is a statement
about three objects, and satisfying one half at a time silently undoes the other. So `HOME` and
`END` set *constraints* rather than performing one-shot moves, and both are re-solved together
every time either changes: the editor intersects the two allowed depth intervals and moves the
surface the shortest distance into the result. The panel shows a **depth stack** — every surface
and pole sorted by distance from the eye — with the selection and the active reference marked.

When the two constraints cannot both hold it says so with the numbers, rather than quietly
breaking one. That is common and it is a fact about the level, not an error: in demo 3, asking a
platform to sit in front of `col-B` *and* behind surface A is impossible, because the pole is
already nearer than A's back face — the pair leaves −20 studs of room for an 11-stud-deep
platform. Widening the gap, or shrinking the platform, is then the real fix.

It is not free, though, and the panel says what it costs. The ratio of the two distances is the
ratio of their drawn sizes, which is *also* exactly how much the avatar's apparent size pops when
it crosses that seam. Demo 3's authored 20.8-stud gap costs 5%; flipping it to a 62-stud gap
costs 15%, which is visible. The readout shows the live figure so the trade is in front of you.

**SOLVE is the point of the tool.** Frame the shot you want, select the surface that should
appear to meet another, and press it: the surface moves the exact amount that puts its seam point
on the ray from your eye through the partner — the same pixel, from where you are standing,
keeping its own distance from the eye so it moves as little as it can. No eyeballing, no fitting.

The readout is measured in the **real** projection (the angle at the eye, shown in pixels of your
viewport), not an idealised one — so it cannot tell you a seam is coincident while you can see
that it is not.

A surface is one Model — slab, skirt and seam markers together, with the seam Attachments on
the slab — so moving a walkway moves everything on it and the geometry can never desync from
the graph. Every edit rebuilds whatever was cached (demo 3's settled graph, demo 4's sixteen
baked graphs).

Nothing writes to disk — a client cannot. `P` prints a block to the Output; paste the numbers
back into `Demo3/Building.luau` or `Demo4/Level.luau`, which is what Rojo syncs.

**Both demos also print, at boot, the exact camera angle at which each authored seam
coincides** — so the angle to look from is a stated fact rather than something to hunt for.

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
| `src/shared/Seam.luau` | Screen-space traversal: exact ortho projection, seam graph, the crossing. Demos 3 and 4. |
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
