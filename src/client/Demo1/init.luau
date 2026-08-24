--!strict
--[[
	DEMO 1 — ITEM INSPECTION

	A puzzle box turned in front of a near-orthographic camera. Two authored anchors sit at
	different depths inside it; from exactly one viewing direction they coincide, and committing
	there opens the box.

	This is now a CONTROLLER, not a script: the shell decides when it runs. The session
	lifecycle is Session, the staged-alignment contract is Chain, and the only render binding is
	the one below, under a name the shell hands out.

	THE THREE THINGS THAT MAKE IT WORK
	  1. atan2, not acos. At FOV 1 the lock threshold is 0.0097 deg and 1 - cos(0.0097 deg) is
	     1.42e-8, against a float32 ULP of 1.19e-7 -- the whole tolerance sits below one
	     representable step of the cosine. Measured: the float32 dot rounds to exactly 1.0, so
	     acos reads 0.000000 where atan2 reads 0.009665. Align.selfTest() prints both at boot.
	     (This is a FOV-1 argument. It does not bind at room scale -- see demo 2.)
	  2. Tolerance is a fraction of the subject's apparent diameter, not degrees and not pixels.
	  3. Two degrees of freedom, not three. Roll about the eye-pivot axis is an isometry fixing
	     the eye, so it provably cannot solve the puzzle.

	CONTROLS  drag to turn · click or E to engage when armed · R to reset · Q or EXIT to leave
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Align = require(ReplicatedStorage.Shared.Align)
local Chain = require(ReplicatedStorage.Shared.Chain)
local Damp = require(ReplicatedStorage.Shared.Damp)
local Mount = require(ReplicatedStorage.Shared.Mount)
local Session = require(ReplicatedStorage.Shared.Session)
local Shell = require(ReplicatedStorage.Shared.Shell)
local Spin = require(ReplicatedStorage.Shared.Spin)

local Drag = require(script.Parent.Drag)
local Feedback = require(script.Parent.Feedback)
local Hud = require(script.Parent.Hud)
local Stage = require(script.Stage)

--[[
	Every puzzle and feel number lives here. No magic constants below this table.

	The four thresholds are authored as the drag window you want to FEEL and converted once:
	sepNorm = delta_rad * L / (2r), with L = 1.8 (anchor baseline) and r = 2.6 (circumradius),
	so 2r/L = 2.8889 and sepNorm = delta_rad / 2.8889.

	  onset  20.0 deg of drag -> 0.12083   feedback begins
	  arm     6.0 deg         -> 0.03625   commit is accepted
	  enter   2.0 deg         -> 0.01208   LOCK / full glow
	  exit    3.2 deg         -> 0.01933   lock releases (1.6x hysteresis)
]]
local TUNE = {
	subjectRadius = 2.6, -- circumradius of a 3-stud cube: 1.5 * sqrt(3). NOT the half-extent.
	frameMargin = 1.25, -- the subject spans 1/1.25 = 80% of the short viewport axis
	fovDeg = 1,

	anchorNear = Vector3.new(0, 0, 0.9), -- collinear with the pivot, so the solve is closed-form
	anchorFar = Vector3.new(0, 0, -0.9), -- baseline L = 1.8
	anchorSlackFrac = 0,
	minDepthGap = 0.9, -- half the baseline; a near-co-depth authoring mistake fails loudly

	bandFrac = 0.12083,
	armFrac = 0.03625,
	enterFrac = 0.01208,
	exitFrac = 0.01933,

	startYaw = math.rad(122),
	startPitch = math.rad(34),

	settleTime = 0.35, -- scoring is suspended until the rig stops moving
	postSnapHold = 0.12, -- stillness after the snap, so the reveal reads as caused by it
	freeLookAfterOpen = true,
	lidSweepDeg = 104,
	lidTime = 0.75,

	humAssetId = "", -- paste a looping hum here; empty means the demo runs silently
	humMaxVolume = 0.35,
	humLoPitch = 0.86,
	moteMaxRate = 55,
	burstCount = 42,
	haloTravel = 0.55,
}

local Demo1 = {}

Demo1.id = "item"
Demo1.title = "DEMO 1 — ITEM INSPECTION"
Demo1.blurb = "A puzzle box turned in the hand. Near-orthographic, FOV 1."
Demo1.ready = true
-- Far above the shell's ground level, in its own region: the rig needs 372 studs of clean
-- standoff and a backdrop, and nothing else may be in frame.
Demo1.region = CFrame.new(0, 4000, 0)

local session: Session.Handle? = nil

function Demo1.stop()
	local live = session
	if live then
		live.stop()
	end
	session = nil
end

function Demo1.start(ctx: Shell.Context): boolean
	local live = Session.new("demo1")
	session = live

	return live.start(function(s: Session.Handle)
		local cam = ctx.camera
		local home = Demo1.region

		local hud = Hud.new(ctx.playerGui, Demo1.title)
		s.add(hud.destroy)
		hud.fade(0, 0) -- start black; the entry is a cut, never a dolly zoom from FOV 70

		-- The void at 372 studs: this is the one demo the blanket profile is right for.
		s.add(ctx.dim({ depthOfField = true, atmosphere = true, fog = true }))
		s.add(Shell.holdCharacter(ctx.player))

		local stage = Stage.build(home, workspace)
		s.add(stage.destroy)

		local rig = Mount.object(stage.model, home, cam, TUNE.subjectRadius, TUNE.frameMargin, TUNE.fovDeg)
		s.add(rig.restore)

		local feel = Spin.defaults()
		local spin = Spin.new(TUNE.startYaw, TUNE.startPitch, feel)

		local drag = Drag.new(cam, hud.gui)
		s.add(drag.destroy)
		-- Off until the rig has settled: a live surface would grab the cursor and hide the icon
		-- for 350 ms while the input is being discarded anyway.
		drag.setEnabled(false)

		--------------------------------------------------------------------------------
		-- feedback
		--------------------------------------------------------------------------------
		local fx = Feedback.new()
		s.add(fx.destroy)

		local hum: Sound? = nil
		if TUNE.humAssetId ~= "" then
			local sound = Instance.new("Sound")
			sound.SoundId = TUNE.humAssetId
			sound.Looped = true
			sound.Volume = 0
			sound.Parent = SoundService -- 2D: a spatial sound 372 studs away is inaudible
			hum = sound
			s.add(function()
				sound:Stop()
				sound:Destroy()
			end)
		end

		fx.add(Feedback.glow(stage.glowParts, Stage.COLD, Stage.HOT, stage.glowLight))
		fx.add(Feedback.hum(hum, TUNE.humLoPitch, TUNE.humMaxVolume))
		fx.add(Feedback.motes(stage.emitters, TUNE.moteMaxRate))
		fx.add(Feedback.halo(stage.haloParts, stage.haloRest, TUNE.haloTravel))

		local pulseChannel, pulse = Feedback.pulse(stage.glowParts, Color3.new(1, 1, 1), 0.22)
		fx.add(pulseChannel) -- after glow, so it wins for the length of its window
		local burst = Feedback.burst(stage.emitters, TUNE.burstCount)
		fx.on("locked", pulse)
		fx.on("solved", function()
			pulse()
			burst()
		end)

		--------------------------------------------------------------------------------
		-- the stage chain
		--------------------------------------------------------------------------------
		local function lidMechanism(): Chain.Poser?
			local swing = Feedback.lid(
				stage.lid,
				stage.lidHingeLocal,
				stage.lidClosedLocal,
				TUNE.lidSweepDeg,
				TUNE.lidTime
			)
			local t = 0
			local spinAngle = 0
			return function(root: CFrame, dt: number): boolean
				local done = swing(root, dt)
				t = math.min(t + dt / TUNE.lidTime, 1)
				spinAngle += dt * (0.9 + 3.4 * (1 - t))
				stage.prize.CFrame = root
					* stage.prizeClosedLocal:Lerp(stage.prizeOpenLocal, Damp.easeOutQuint(t))
					* CFrame.Angles(0, spinAngle, 0)
				return done
			end
		end

		local firstPuzzle: Chain.Puzzle = {
			name = "lid",
			anchors = function(): (Vector3, Vector3)
				return stage.nearAnchor.WorldPosition, stage.farAnchor.WorldPosition
			end,
			-- The subject sphere is the box itself, and the camera is 372 studs outside it.
			sphere = function(): (Vector3, number)
				return home.Position, TUNE.subjectRadius
			end,
			minGap = TUNE.minDepthGap,
			slackFrac = TUNE.anchorSlackFrac,
			thresholds = Chain.thresholds(TUNE.bandFrac, TUNE.armFrac, TUNE.enterFrac, TUNE.exitFrac),
			solve = function(): (number?, number?, string?)
				return Align.solve(TUNE.anchorNear, TUNE.anchorFar, rig.distance(), math.rad(feel.pitchLimitDeg))
			end,
			mechanism = lidMechanism,
			onSolved = nil,
		}

		local chain = Chain.new(firstPuzzle)
		local targetYaw, targetPitch = 0, 0

		local function aim(): boolean
			local puzzle = chain.current()
			-- A finished chain, or a stage that does not snap, is a silent success -- not a
			-- failure. Otherwise every ViewportSize change after the box opens warns.
			if not puzzle or not puzzle.solve then
				return true
			end
			local yaw, pitch, why = chain.aim()
			if not yaw or not pitch then
				warn(`[demo1] stage "{puzzle.name}" has no reachable solution: {why}`)
				return false
			end
			targetYaw, targetPitch = yaw, pitch
			return true
		end
		if not aim() then
			error("demo 1 has no reachable solution", 0)
		end

		local viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			rig.refit()
			-- The fit distance moved; with off-pivot anchors the solved direction moves with it.
			aim()
		end)
		s.track(viewportConn)

		--------------------------------------------------------------------------------
		-- boot assertions
		--------------------------------------------------------------------------------
		local subtend = Align.subtendDeg(rig.eye(), home.Position, TUNE.subjectRadius)
		local baseline = (TUNE.anchorNear - TUNE.anchorFar).Magnitude
		local function dragDegFor(frac: number): number
			return math.deg(frac * (2 * TUNE.subjectRadius) / baseline)
		end
		local function pixelsFor(frac: number): number
			return frac * subtend * cam.ViewportSize.Y / cam.FieldOfView
		end
		print(`[demo1] {Align.selfTest()}`)
		print(
			("[demo1] rig: fov %.2f deg, distance %.1f studs, subject subtends %.4f deg"):format(
				cam.FieldOfView,
				rig.distance(),
				subtend
			)
		)
		print(
			("[demo1] lock: %.2f deg of drag (%.0f screen px) · arm: %.2f deg of drag (%.0f px)"):format(
				dragDegFor(TUNE.enterFrac),
				pixelsFor(TUNE.enterFrac),
				dragDegFor(TUNE.armFrac),
				pixelsFor(TUNE.armFrac)
			)
		)

		--------------------------------------------------------------------------------
		-- state
		--------------------------------------------------------------------------------
		type Phase = "Settling" | "Play" | "Committing" | "Revealing" | "Opened"
		local phase: Phase = "Settling"
		local settleFor = 0
		local holdFor = 0
		local rawProx = 0
		local commitQueued = false
		local resetQueued = false
		local armed = false

		local exiting = false
		local function doExit()
			if exiting then
				return
			end
			exiting = true
			drag.setEnabled(false)
			hud.fade(0, 0.25)
			task.delay(0.25, ctx.exit)
		end
		hud.exitButton.Activated:Connect(doExit)

		local function finishOpen()
			local nextPuzzle, why = chain.advance()
			if why then
				-- A chained stage's failure is as loud as the first stage's: silently keeping the
				-- previous snap target makes the demo unsolvable with nothing printed.
				warn(`[demo1] stage "{nextPuzzle and nextPuzzle.name or "?"}" is unsolvable: {why}`)
			end

			if nextPuzzle and not why then
				aim()
				phase = "Play"
				drag.setEnabled(true)
				hud.setState("")
				hud.setHint(`stage: {nextPuzzle.name} · drag to turn`)
				return
			end

			phase = "Opened"
			if TUNE.freeLookAfterOpen then
				drag.setEnabled(true)
				hud.setHint("free look · R to reset · Q or EXIT to leave")
			else
				hud.setHint("R to reset · Q or EXIT to leave")
			end
		end

		local function beginReveal()
			phase = "Revealing"
			local animating = chain.beginMechanism()
			fx.fire("solved")
			hud.setState("OPEN")
			hud.setHint("R to reset · Q or EXIT to leave")
			if not animating then
				-- Nothing to animate: do not sit in Revealing waiting on a poser that was never
				-- added. Asking the chain is the only reliable test -- `mechanism` may exist and
				-- still return nil.
				finishOpen()
			end
		end

		local function resetPuzzle()
			phase = "Settling"
			settleFor = 0
			rawProx = 0
			-- The gate is rebuilt by chain.reset, so the cached snapshot must go with it or a
			-- reset taken while armed carries a stale arm into the next Play frame.
			armed = false
			chain.reset(firstPuzzle)
			aim()
			spin.set(TUNE.startYaw, TUNE.startPitch)
			drag.setEnabled(false)
			local root = stage.model:GetPivot()
			stage.lid.CFrame = root * stage.lidClosedLocal
			stage.prize.CFrame = root * stage.prizeClosedLocal
			hud.setState("")
			hud.setHint("")
			hud.setProgress(0, false, false)
		end

		local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Space then
				commitQueued = true
			elseif input.KeyCode == Enum.KeyCode.R then
				resetQueued = true
			elseif input.KeyCode == Enum.KeyCode.Q then
				doExit()
			end
		end)
		s.track(inputConn)

		--------------------------------------------------------------------------------
		-- THE FRAME LOOP. One binding, one writer per property, one dt clamp.
		--------------------------------------------------------------------------------
		local bind = ctx.bindName
		RunService:BindToRenderStep(bind, Enum.RenderPriority.Camera.Value + 1, function(rawDt: number)
			local dt = Damp.clampDt(rawDt)

			if resetQueued then
				resetQueued = false
				if phase ~= "Committing" then
					resetPuzzle()
				end
			end

			-- 1. input: accumulated in callbacks, consumed exactly once here
			local f = drag.consume()
			local canTurn = phase == "Play" or phase == "Opened"
			if canTurn then
				if f.dx ~= 0 or f.dy ~= 0 then
					spin.drag(f.dx, f.dy)
				end
				-- A tap is a commit, not a flick.
				if f.released and not f.tapped then
					spin.release(f.velX, f.velY)
				end
			end

			-- 2. commit, accepted at the ARM threshold and never at the lock threshold
			local wantsCommit = commitQueued or f.tapped
			commitQueued = false
			if wantsCommit and phase == "Play" and chain.current() and armed then
				phase = "Committing"
				holdFor = 0
				spin.freeze()
				spin.snapTo(targetYaw, targetPitch)
				drag.setEnabled(false)
				hud.setState("ENGAGING")
			end

			-- 3. one integrator for drag, coast and snap. The gain damping reads the RAW
			--    closeness: the smoothed one would add visible input lag.
			local yaw, pitch = spin.step(dt, rawProx)

			-- 4. the ONE line that differs from the world-scale demos
			rig.apply(yaw, pitch)

			-- 5. mechanisms are posed AFTER the pivot write, from this frame's pivot
			local root = stage.model:GetPivot()
			local newestDone = chain.pose(root, dt)
			if newestDone and phase == "Revealing" then
				finishOpen()
			end

			-- 6. the eye AS RENDERED this frame, after the pose write
			local render = cam:GetRenderCFrame()

			-- 7-9. score the pose that was actually written, unless scoring is suspended
			local prox
			if phase == "Settling" then
				settleFor += dt
				rawProx = 0
				prox = chain.relax(dt)
				hud.setProgress(prox, false, false)
				if settleFor >= TUNE.settleTime then
					phase = "Play"
					drag.setEnabled(true)
					hud.setHint("drag to turn the box")
				end
			elseif phase == "Play" then
				local score = chain.score(dt, render.Position, render.LookVector)
				rawProx = score.raw
				prox = score.prox
				armed = score.armed
				if score.enteredLocked then
					fx.fire("locked")
				end
				hud.setState(
					if score.state == "Locked" and armed
						then "ALIGNED — click or E"
						elseif score.state == "Locked" then "ALIGNED"
						elseif armed then "click or E to engage"
						else ""
				)
				hud.setProgress(prox, armed, score.state == "Locked")
			elseif phase == "Opened" then
				-- Free look: nothing is scored and the glow relaxes, but the object still turns
				-- and every mechanism is still posed, so it reads as an opened box being examined.
				rawProx = 0
				armed = false
				prox = chain.relax(dt)
				hud.setProgress(prox, false, false)
			else
				-- Committing / Revealing: the snap sweeps through the lock band by construction
				-- and would re-fire everything. Hold the signal lit instead.
				rawProx = 1
				armed = false
				prox = chain.hold(dt)
				hud.setProgress(1, false, true)
			end

			fx.render(prox, dt)

			-- 11. the reveal is caused by the snap, not simultaneous with it
			if phase == "Committing" then
				if spin.justLanded() then
					holdFor = 0.0001
				end
				if holdFor > 0 then
					holdFor += dt
					if holdFor >= TUNE.postSnapHold then
						beginReveal()
					end
				end
			end
		end)
		s.add(function()
			RunService:UnbindFromRenderStep(bind)
		end)

		hud.setHint("")
		hud.fade(1, 0.45) -- or the demo boots to a black screen with no error
	end)
end

return Demo1
