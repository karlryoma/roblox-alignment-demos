# Alignment demos

Roblox tech demos on camera/perspective alignment illusions — the Monument Valley /
Echochrome / Superliminal / The Room family. Showcase pieces for a developer audience,
not a shipped game: client-only, no server authority, placeholder art on purpose.

**Demo 1 — Item Inspection** is built. Demos 2–4 are world-scale variants that reuse
`src/shared` unchanged.

## Running it

```
rokit install
rojo serve            # port 34873; Studio: Rojo plugin -> Connect
```

Studio: **File → New** (Baseplate), **Save As** `sandbox.rbxlx` here, connect, press Play.
The demo enters itself once the character exists.

```
drag          turn the box (mouse or touch) — also after it opens
click / E     engage, once the HUD says it is armed
R             reset to the first stage
Q or EXIT     leave the inspection view
I             re-enter
```

Not Escape — the Roblox menu owns that key, so `InputBegan` never sees it with
`gameProcessedEvent` false.

## What it does

A 3-stud puzzle box turns in front of a near-orthographic camera. Two anchors sit at
different depths inside it, collinear with the pivot. From exactly one viewing direction
they coincide; approaching it escalates glow / hum / motes, and committing snaps to the
exact solution and swings the lid open.

## The three decisions that matter

**1. `atan2`, not `acos`.** The obvious test is `acos(ua:Dot(ub))`. At FOV 1 it does not
merely lose precision, it returns nothing at all. The lock tolerance is 0.0097°, so
`1 - cos(0.0097°) = 1.42e-8`, against a float32 ULP at 1.0 of `1.19e-7` — and Vector3
components are float32. Measured: at the lock threshold the float32 dot product rounds to
exactly `1.0`, so `acos` reports `0.000000°` where `atan2(|a×b|, a·b)` in doubles reports
`0.009665°`. `Align.selfTest()` prints both at boot.

**2. Tolerance is a fraction of the subject's apparent diameter**, not degrees and not
pixels. Degrees mean different things at FOV 1 and FOV 70; a screen fraction changes
difficulty when the fit distance is refit for portrait. The identity
`sepNorm = delta * L / (2r)` means the lock window *in degrees of drag* depends only on the
object's own geometry, so the same four authored numbers give the same feel on a 200-stud
monument in demo 3.

**3. Two degrees of freedom, not three.** Roll about the eye–pivot axis is an isometry
fixing the eye, so it preserves every angle subtended there and provably cannot solve the
puzzle. State is `(yaw, pitch)` and the CFrame is rebuilt from scratch each frame: no
accumulated shear, no drag-axis inversion, no locking while upside down, and the snap
target is closed-form.

A corollary worth stating: the raw lock window is ~14 mouse pixels wide — correct, and
unhittable. That is fixed by damping the drag gain inside the band and arming the commit at
a much wider threshold, never by loosening the tolerance. Loosening it makes the illusion
lie.

## Layout

| File | Role |
| --- | --- |
| `src/shared/Align.luau` | Pure geometry: separation, probe, closed-form solve, hysteresis gate. No Instances. |
| `src/shared/Damp.luau` | Framerate-independent smoothing. Every constant is a time constant. |
| `src/shared/Spin.luau` | View-sphere state; one integrator for drag, coast and snap. |
| `src/shared/Mount.luau` | The near-ortho rig. `Mount.object` (demo 1) / `Mount.orbit` (demos 2–4). |
| `src/client/Drag.luau` | Input capture only; accumulate in callbacks, consume once per frame. |
| `src/client/Feedback.luau` | Proximity-driven channels + the angle-driven hinged lid. |
| `src/client/Stage.luau` | Client-built placeholder geometry. |
| `src/client/Hud.luau` | Meter, state line, fade, exit button. |
| `src/client/init.client.luau` | The demo: TUNE table, state machine, the single render step. |

`bash scripts/check.sh` — sourcemap + `luau-lsp analyze` + `selene`.

## Chaining stages

The box stays turnable after the lid opens (`TUNE.freeLookAfterOpen`), so a second alignment
can be authored against whatever the reveal exposed. A stage is an anchor pair, the mechanism
it drives, and what comes next:

```lua
local core: Puzzle = {
    name = "core",
    near = stage.coreNear,                    -- Attachments, read live as WorldPosition
    far = stage.coreFar,
    nearLocal = Vector3.new(0, 0.4, 0.55),    -- the SAME points in the model's frame
    farLocal = Vector3.new(0, 0.4, -0.55),
    mechanism = function() return myPoser() end,  -- or nil: then the snap is the payoff
    onSolved = nil,                           -- return another Puzzle to chain again
}
-- and on the stage before it:
onSolved = function() return core end
```

`nearLocal`/`farLocal` are what the closed-form solve runs on, so they must be the
attachments' own local positions — otherwise the snap aims at a pose where the anchors do not
actually coincide. The solved orientation is always derived, never authored.

`mechanism` returns a per-frame poser `(rootCF, dt) -> done`. It keeps being called after it
reports done, which is what holds its parts attached while the object is turned afterwards.
A stage with no mechanism finishes the instant the snap lands.

## Porting to demos 2–4

Swap `Mount.object` for `Mount.orbit`: the camera then orbits and the world stays put.
Nothing else in `src/shared` changes, because the alignment test is written in world space
against whatever pose was actually rendered this frame — it does not care which side moved.
Both mounts read `(yaw, pitch)` in the frame the anchors were authored in, so
`Align.solve`'s answer is portable between them.

What is demo-1-only: `Stage.luau`, and `Feedback.halo`'s world-fixed reticle rest poses
(fine while the camera is parked, needs re-posing per frame once the camera orbits).

## WSL note

Rojo's file watcher does not fire on `/mnt/c`. A `rojo serve` started from WSL keeps serving
the source as it was when the process launched. Run it from Windows PowerShell, or restart
it after each edit. Editing `default.project.json` always needs a restart.
