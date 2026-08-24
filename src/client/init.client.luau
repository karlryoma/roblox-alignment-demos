--!strict
--[[
	ALIGNMENT DEMO 1 — ITEM INSPECTION
	==================================

	A puzzle box turned in front of a near-orthographic camera. Two authored anchors sit at
	different depths inside it; from exactly one viewing direction they coincide, and
	committing there opens the box.

	This file is the demo, not a library, and it is the ONLY place a render step is bound.
	Everything above it in src/shared is reusable as-is by the world-scale demos: there, the
	camera orbits and the world stays put, which is one line — Mount.orbit instead of
	Mount.object. The alignment test does not change at all, because it is written in world
	space against whatever pose was actually rendered this frame.

	THE THREE THINGS THAT MAKE IT WORK
	----------------------------------
	1. atan2, not acos. At FOV 1 the lock threshold is 0.0097 degrees, and 1 - cos(0.0097 deg)
	   is 1.42e-8 against a float32 ULP of 1.19e-7 — the whole tolerance sits below one
	   representable step of the cosine. acos would report a flat zero for everything inside
	   ~0.028 degrees. See the header of Align.luau; Align.selfTest() prints the comparison at
	   boot so nobody has to take it on faith.

	2. The tolerance is a fraction of the subject's own apparent diameter (sepNorm), not
	   degrees and not pixels. Degrees mean different things at FOV 1 and FOV 70; a screen
	   fraction silently changes difficulty when the fit distance is refit for portrait. The
	   identity sepNorm = delta * L / (2r) means the lock window in DEGREES OF DRAG depends
	   only on the object's own geometry, so the same four authored numbers give the same feel
	   on a 200-stud monument in demo 3.

	3. The raw lock window is about 14 mouse pixels wide — correct, and unhittable. It is
	   fixed by damping the drag gain inside the band and by arming the commit at a much wider
	   threshold, never by loosening the tolerance. Loosening the tolerance makes the illusion
	   lie, which is the one thing this demo cannot afford.

	CONTROLS   drag to turn · click or E to engage when armed · R to reset · Q or the EXIT
	           button to leave · I to re-enter

	           Not Escape: the Roblox menu owns that key, so InputBegan never sees it with
	           gameProcessedEvent false. The on-screen EXIT button is the only exit a touch
	           player can reach at all.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

ReplicatedStorage:WaitForChild("Shared")
local Align = require(ReplicatedStorage.Shared.Align)
local Damp = require(ReplicatedStorage.Shared.Damp)
local Mount = require(ReplicatedStorage.Shared.Mount)
local Spin = require(ReplicatedStorage.Shared.Spin)

local Drag = require(script.Drag)
local Feedback = require(script.Feedback)
local Hud = require(script.Hud)
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
	home = CFrame.new(0, 500, 0), -- the stage sits out of sight above spawn
	subjectRadius = 2.6, -- circumradius of a 3-stud cube: 1.5 * sqrt(3). NOT the half-extent.
	frameMargin = 1.25, -- the subject spans 1/1.25 = 80% of the short viewport axis
	fovDeg = 1,

	anchorNear = Vector3.new(0, 0, 0.9), -- collinear with the pivot, so the solve is closed-form
	anchorFar = Vector3.new(0, 0, -0.9), -- baseline L = 1.8
	-- Containment slack, in the same normalised unit as the thresholds below, subtracted after
	-- the division so it survives a change of rig. 0 keeps the mechanism exact. The honest
	-- value for this art is (ringInner - pipRadius)/distance / subtend =
	-- (0.13 - 0.06)/372.4 rad = 0.01077 deg / 0.8 deg = 0.01346, which would slightly more
	-- than double the lock window. The ring and pip are sized so the eye and the mechanism
	-- already agree without it.
	anchorSlackFrac = 0,
	minDepthGap = 0.9, -- half the baseline; a near-co-depth authoring mistake fails loudly

	bandFrac = 0.12083,
	armFrac = 0.03625,
	enterFrac = 0.01208,
	exitFrac = 0.01933,

	gamma = 2.2, -- back-loads the drama: halfway in reads as a faint shimmer
	attackTau = 0.05, -- fast in: the signal reads as caused by the player
	releaseTau = 0.22, -- slow out: no strobing at the boundary, and it leaves a trail
	dwell = 0.08, -- armed for this long before the prompt appears

	startYaw = math.rad(122),
	startPitch = math.rad(34),

	settleTime = 0.35, -- scoring is suspended until the rig stops moving
	postSnapHold = 0.12, -- stillness after the snap, so the reveal reads as caused by it
	lidSweepDeg = 104,
	lidTime = 0.75,
	prizeRise = 0.9,

	humAssetId = "", -- paste a looping hum here; empty means the demo runs silently
	humMaxVolume = 0.35,
	humLoPitch = 0.86,
	moteMaxRate = 55,
	burstCount = 42,
	haloTravel = 0.55,
}

local BIND = "AlignmentDemo1"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local camera = workspace.CurrentCamera
while not camera do
	task.wait()
	camera = workspace.CurrentCamera
end
local cam: Camera = camera

--------------------------------------------------------------------------------
-- scene hazards
--------------------------------------------------------------------------------

--[[
	Depth of field, atmosphere and fog are all distance-driven, and the subject is 372 studs
	away. Left alone they wash it out completely. Snapshot, neutralise, restore.
]]
local function neutraliseLighting(): () -> ()
	local undo: { () -> () } = {}

	for _, inst in Lighting:GetDescendants() do
		if inst:IsA("DepthOfFieldEffect") and inst.Enabled then
			inst.Enabled = false
			table.insert(undo, function()
				inst.Enabled = true
			end)
		elseif inst:IsA("Atmosphere") then
			local density, haze = inst.Density, inst.Haze
			inst.Density, inst.Haze = 0, 0
			table.insert(undo, function()
				inst.Density, inst.Haze = density, haze
			end)
		end
	end

	local fogEnd, fogStart = Lighting.FogEnd, Lighting.FogStart
	Lighting.FogEnd = 1e6
	Lighting.FogStart = 1e6
	table.insert(undo, function()
		Lighting.FogEnd, Lighting.FogStart = fogEnd, fogStart
	end)

	return function()
		for _, fn in undo do
			fn()
		end
	end
end

--[[
	The character is never moved and never required through PlayerModule (which cannot be
	resolved by luau-lsp through the sourcemap, so requiring it would fail this project's own
	quality gate). Anchoring the root and switching the movement modes to Scriptable is the
	typed way to say "stand still".
]]
local function holdCharacter(): () -> ()
	local undo: { () -> () } = {}

	local computerMode, touchMode = player.DevComputerMovementMode, player.DevTouchMovementMode
	player.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
	player.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable
	table.insert(undo, function()
		player.DevComputerMovementMode = computerMode
		player.DevTouchMovementMode = touchMode
	end)

	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") and not root.Anchored then
		root.Anchored = true
		table.insert(undo, function()
			if root and root.Parent then
				root.Anchored = false
			end
		end)
	end

	return function()
		for _, fn in undo do
			fn()
		end
	end
end

--------------------------------------------------------------------------------
-- session
--------------------------------------------------------------------------------

local active = false
local restores: { () -> () } = {}
local sessionCharacter: Model? = nil
local exitSession: (() -> ())? = nil

--[[ Idempotent, and called from every exit path including the error path. ]]
local function teardown()
	if not active then
		return
	end
	active = false
	exitSession = nil
	sessionCharacter = nil
	for i = #restores, 1, -1 do
		-- typed pcall needs a return type to hand back the error string
		local ok, err = pcall(restores[i] :: () -> any)
		if not ok then
			warn(`[demo1] teardown step failed: {err}`)
		end
	end
	table.clear(restores)
end

local function enter()
	if active then
		return
	end
	active = true

	sessionCharacter = player.Character

	local hud = Hud.new(playerGui)
	table.insert(restores, hud.destroy)
	hud.fade(0, 0) -- start black; the entry is a cut, never a dolly zoom from FOV 70

	table.insert(restores, neutraliseLighting())
	table.insert(restores, holdCharacter())

	local stage = Stage.build(TUNE.home, workspace)
	table.insert(restores, stage.destroy)

	local rig = Mount.object(stage.model, TUNE.home, cam, TUNE.subjectRadius, TUNE.frameMargin, TUNE.fovDeg)
	table.insert(restores, rig.restore)

	local resolveTarget: (() -> ())? = nil
	local viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		rig.refit()
		-- The fit distance moved, and with off-pivot anchors the solved direction moves with
		-- it. Free for this demo (the anchors are collinear with the pivot, so the answer is
		-- distance-independent) and correct for anyone who authors them elsewhere.
		if resolveTarget then
			resolveTarget()
		end
	end)
	table.insert(restores, function()
		viewportConn:Disconnect()
	end)

	local drag = Drag.new(cam, hud.gui)
	table.insert(restores, drag.destroy)
	-- Off until the rig has settled. Leaving it live would grab the cursor and hide the mouse
	-- icon for 350 ms while the input is being discarded anyway.
	drag.setEnabled(false)

	-- A cushioned exit: the entry was a cut, but leaving on a hard cut reads as a crash.
	local exiting = false
	local function doExit()
		if not active or exiting then
			return
		end
		exiting = true
		drag.setEnabled(false)
		hud.fade(0, 0.25)
		task.delay(0.25, teardown)
	end
	exitSession = doExit
	hud.exitButton.Activated:Connect(doExit)

	local feel = Spin.defaults()
	local spin = Spin.new(TUNE.startYaw, TUNE.startPitch, feel)
	local gate = Align.newGate(TUNE.enterFrac, TUNE.exitFrac, TUNE.armFrac, TUNE.bandFrac, TUNE.dwell)

	-- The solved pose is DERIVED from the anchors and self-verified, never authored. Two
	-- sources of truth disagreeing by a fraction of a degree is exactly the jank that would
	-- sink this.
	local solYaw, solPitch, solErr = Align.solve(
		TUNE.anchorNear,
		TUNE.anchorFar,
		rig.distance(),
		math.rad(feel.pitchLimitDeg)
	)
	if not solYaw or not solPitch then
		warn(`[demo1] the puzzle has no reachable solution: {solErr}`)
		teardown()
		return
	end
	local targetYaw: number, targetPitch: number = solYaw, solPitch
	resolveTarget = function()
		local y, pch = Align.solve(TUNE.anchorNear, TUNE.anchorFar, rig.distance(), math.rad(feel.pitchLimitDeg))
		if y and pch then
			targetYaw, targetPitch = y, pch
		end
	end

	--------------------------------------------------------------------------------
	-- boot assertions: what a developer reading this actually wants printed
	--------------------------------------------------------------------------------
	local subtend = Align.subtendDeg(rig.eye(), TUNE.home.Position, TUNE.subjectRadius)
	local baseline = (TUNE.anchorNear - TUNE.anchorFar).Magnitude
	local dragDegFor = function(frac: number): number
		return math.deg(frac * (2 * TUNE.subjectRadius) / baseline)
	end
	local pixelsFor = function(frac: number): number
		return frac * subtend * cam.ViewportSize.Y / cam.FieldOfView
	end
	print(("[demo1] %s"):format(Align.selfTest()))
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
	-- feedback channels
	--------------------------------------------------------------------------------
	local fx = Feedback.new()
	table.insert(restores, fx.destroy)

	local hum: Sound? = nil
	if TUNE.humAssetId ~= "" then
		local s = Instance.new("Sound")
		s.SoundId = TUNE.humAssetId
		s.Looped = true
		s.Volume = 0
		s.Parent = SoundService -- 2D: a spatial sound 372 studs from the listener is inaudible
		hum = s
		table.insert(restores, function()
			s:Stop()
			s:Destroy()
		end)
	end

	fx.add(Feedback.glow(stage.glowParts, Stage.COLD, Stage.HOT, stage.glowLight))
	fx.add(Feedback.hum(hum, TUNE.humLoPitch, TUNE.humMaxVolume))
	fx.add(Feedback.motes(stage.emitters, TUNE.moteMaxRate))
	fx.add(Feedback.halo(stage.haloParts, stage.haloRest, TUNE.haloTravel))

	local pulseChannel, pulse = Feedback.pulse(stage.glowParts, Color3.new(1, 1, 1), 0.22)
	fx.add(pulseChannel) -- added after glow, so it wins for the length of its window
	local burst = Feedback.burst(stage.emitters, TUNE.burstCount)
	fx.on("locked", pulse)
	fx.on("solved", function()
		pulse()
		burst()
	end)

	--------------------------------------------------------------------------------
	-- state
	--------------------------------------------------------------------------------
	type Phase = "Settling" | "Play" | "Committing" | "Revealing" | "Opened"
	local phase: Phase = "Settling"
	local settleFor = 0
	local holdFor = 0
	local prox = 0
	local proxRaw = 0
	local commitQueued = false
	local resetQueued = false
	local lidPoser: ((CFrame, number) -> boolean)? = nil
	local prizeT = 0

	local function beginReveal()
		phase = "Revealing"
		prizeT = 0
		lidPoser = Feedback.lid(
			stage.lid,
			stage.lidHingeLocal,
			stage.lidClosedLocal,
			TUNE.lidSweepDeg,
			TUNE.lidTime
		)
		fx.fire("solved")
		hud.setState("OPEN")
		hud.setHint("R to reset · Q or EXIT to leave")
	end

	local function resetPuzzle()
		phase = "Settling"
		settleFor = 0
		prox, proxRaw = 0, 0
		lidPoser = nil
		prizeT = 0
		gate.reset()
		spin.set(TUNE.startYaw, TUNE.startPitch)
		drag.setEnabled(false)
		local root = stage.model:GetPivot()
		stage.lid.CFrame = root * stage.lidClosedLocal
		stage.prize.CFrame = root * stage.prizeClosedLocal
		hud.setState("")
		hud.setHint("")
		hud.setProgress(0, false, false)
	end

	--------------------------------------------------------------------------------
	-- input that is not the drag
	--------------------------------------------------------------------------------
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
	table.insert(restores, function()
		inputConn:Disconnect()
	end)

	--------------------------------------------------------------------------------
	-- THE FRAME LOOP. One binding, one writer per property, one dt clamp.
	--------------------------------------------------------------------------------
	RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 1, function(rawDt: number)
		local dt = Damp.clampDt(rawDt)

		if resetQueued then
			resetQueued = false
			if phase == "Opened" or phase == "Revealing" then
				resetPuzzle()
			end
		end

		-- 1. input: accumulated in callbacks, consumed exactly once here
		local f = drag.consume()
		if phase == "Play" then
			if f.dx ~= 0 or f.dy ~= 0 then
				spin.drag(f.dx, f.dy)
			end
			-- A tap is a commit, not a flick. Throwing the box on the click that was meant to
			-- engage it is the most annoying possible way to miss the window.
			if f.released and not f.tapped then
				spin.release(f.velX, f.velY)
			end
		end

		-- 2. commit arbitration. Accepted at the ARM threshold, not the lock threshold: a
		--    click at the visually perfect moment must never be refused.
		local wantsCommit = commitQueued or f.tapped
		commitQueued = false
		if wantsCommit and phase == "Play" and gate.armed() then
			phase = "Committing"
			holdFor = 0
			spin.freeze()
			spin.snapTo(targetYaw, targetPitch)
			drag.setEnabled(false) -- leftover inertia must not fight the snap
			hud.setState("ENGAGING")
		end

		-- 3. one integrator for drag, coast and snap, so there is no seam between them
		local yaw, pitch = spin.step(dt, proxRaw)

		-- 4. the ONE line that differs from the world-scale demos
		rig.apply(yaw, pitch)

		-- 5. the lid is posed AFTER the pivot write, from the pivot, every frame it animates:
		--    PivotTo moves descendants rigidly by the frame's delta, so anything mid-animation
		--    has to be written absolutely, and from this frame's root.
		local root = stage.model:GetPivot()
		if lidPoser then
			local finished = lidPoser(root, dt)
			prizeT = math.min(prizeT + dt / TUNE.lidTime, 1)
			local rise = Damp.easeOutQuint(prizeT)
			stage.prize.CFrame = root
				* stage.prizeClosedLocal:Lerp(stage.prizeOpenLocal, rise)
				* CFrame.Angles(0, prizeT * math.pi * 1.5, 0)
			if finished and phase == "Revealing" then
				phase = "Opened"
			end
		end

		-- 6. the eye AS RENDERED this frame, after the pose write. Never a cached value and
		--    never camera.Focus.
		local render = cam:GetRenderCFrame()
		local eye = render.Position
		local look = render.LookVector

		-- 7-9. score the pose that was actually written, unless scoring is suspended
		if phase == "Settling" then
			settleFor += dt
			proxRaw = 0
			hud.setProgress(prox, false, false)
			if settleFor >= TUNE.settleTime then
				phase = "Play"
				drag.setEnabled(true)
				hud.setHint("drag to turn the box")
			end
		elseif phase == "Play" then
			local p = Align.probe(
				eye,
				look,
				stage.nearAnchor.WorldPosition,
				stage.farAnchor.WorldPosition,
				TUNE.home.Position,
				TUNE.subjectRadius,
				TUNE.minDepthGap,
				TUNE.anchorSlackFrac
			)
			local scored = if p.valid and p.orderOk then p.sepNorm else math.huge
			proxRaw = Align.closeness(scored, TUNE.enterFrac, TUNE.bandFrac, TUNE.gamma)
			gate.update(scored, dt)

			local enteredLocked, _leftLocked = gate.edges()
			if enteredLocked then
				fx.fire("locked")
			end

			local state = gate.state()
			-- Gated on the same predicate as the action. Locked says the anchors coincide; armed
			-- says the dwell has elapsed and a click will actually be taken. A fast sweep can
			-- satisfy the first without the second.
			local canCommit = gate.armed()
			hud.setState(
				if state == "Locked" and canCommit
					then "ALIGNED — click or E"
					elseif state == "Locked" then "ALIGNED"
					elseif canCommit then "click or E to engage"
					else ""
			)
			hud.setProgress(prox, canCommit, state == "Locked")
		else
			-- Committing / Revealing / Opened: the snap sweeps straight through the lock band
			-- by construction and would re-fire everything. Hold the signal lit instead.
			proxRaw = 1
			hud.setProgress(1, false, true)
		end

		-- the single smoothed scalar every channel reads
		prox = Damp.dampAsym(prox, proxRaw, dt, TUNE.attackTau, TUNE.releaseTau)
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

	table.insert(restores, function()
		RunService:UnbindFromRenderStep(BIND)
	end)

	hud.setHint("")
	hud.fade(1, 0.45)
end

--------------------------------------------------------------------------------
-- entry
--------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.I and not active then
		enter()
	end
end)

-- A respawn hands the camera back to the default scripts mid-session, so the session has to
-- end with it. Compared against the character the session was STARTED with: StarterPlayerScripts
-- are usually cloned before the first character replicates, so an unguarded handler tears the
-- demo down a moment after it boots.
player.CharacterAdded:Connect(function(character: Model)
	if active and character ~= sessionCharacter then
		local leave = exitSession
		if leave then
			task.defer(leave)
		else
			task.defer(teardown)
		end
	end
end)

task.spawn(function()
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	-- One beat for the default camera to acquire the fresh Humanoid, so the snapshot restore
	-- has something coherent to hand back to.
	task.wait(0.2)
	enter()
end)
