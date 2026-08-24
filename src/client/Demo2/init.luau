--!strict
--[[
	DEMO 2 — ROOM-SCALE ALIGN-TO-UNLOCK

	A room you walk around. Alignment does not spawn or move anything: it GATES AN INTERACTION.
	Nothing teleports and no geometry appears, so nothing can look wrong from an off angle --
	which is why this is the lowest-jank world-scale mechanic and why it comes first.

	The chain is the point:
	    1. Orbit to the viewpoint where two hanging markers align.
	    2. Commit -> the bolts retract and a wall panel becomes DRAGGABLE.
	    3. Drag the panel aside, revealing a second pair inside the alcove.
	    4. Second alignment -> the door opens.
	One alignment is a trick; alignment -> action -> new alignment is a system.

	WHY PERSPECTIVE, NOT THE FOV-1 NEAR-ORTHO OF DEMO 1
	Ortho at room scale needs ~2,850 studs of standoff and hits render-distance culling. More
	importantly perspective is BETTER here: under ortho only camera ROTATION changes alignment,
	giving a few discrete states, while under perspective both POSITION and rotation change it
	continuously -- and that continuous search space is the entire "walk around until it lines
	up" feel. Demo 1's atan2-over-acos argument is a FOV-1 precision argument and does not bind
	at this scale (1 - cos(1 deg) is ~1,280 float32 ULPs); we use Align.probe anyway because a
	second hand-written test is exactly the two-sources-of-truth failure this repo warns about,
	and because the predicates are the part that matters.

	WHY A CUSTOM CAMERA. There is no pitch-clamp property on Player, the default camera's limit
	is hard-coded in PlayerModule (which this project may not require), and a commit that
	re-poses the view needs CameraType = Scriptable. So Orbit owns it.

	UNLOCK PERSISTENCE: for one visit. Everything is rebuilt inside start(), so returning to the
	menu and coming back resets the room to locked. That is the honest scope for a 20-second
	clip; persisting across round-trips would mean lifting the state above start()/stop() and
	APPLYING it to geometry on re-entry rather than replaying the animation.

	CONTROLS  walk with WASD · drag to orbit · click or E to engage when armed · drag the panel
	          · R to reset · Q or EXIT to leave
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Align = require(ReplicatedStorage.Shared.Align)
local Chain = require(ReplicatedStorage.Shared.Chain)
local Damp = require(ReplicatedStorage.Shared.Damp)
local Orbit = require(ReplicatedStorage.Shared.Orbit)
local Session = require(ReplicatedStorage.Shared.Session)
local Shell = require(ReplicatedStorage.Shared.Shell)

local Drag = require(script.Parent.Drag)
local Feedback = require(script.Parent.Feedback)
local Hud = require(script.Parent.Hud)
local Room = require(script.Room)

--[[
	Thresholds are authored in DEGREES of angular separation and divided ONCE by the pair's
	nominal apparent diameter, because every threshold the shipped code consumes is
	dimensionless. Demo 1's numbers are NOT portable here: feeding its enterFrac would be
	meaningless against a different subject sphere, and feeding raw degrees would make
	Align.closeness saturate for everything below 1 -- a ramp that is flat forever.

	minGap is the one absolute-length threshold in an otherwise scale-free system. It is in
	STUDS, and demo 1's 0.9 (for a 1.8-stud baseline) would be satisfied by almost any pose at
	room scale, making the wrong-side guard toothless exactly where it matters most: a player
	walking freely reaches the antipodal false solution within seconds.
]]
local TUNE = {
	orbitDistance = 13,
	orbitHeight = 3.0,

	s1 = {
		radius = 3.1, -- half the 5-stud baseline, plus the marker art
		nominalDistance = 10,
		bandDeg = 14.0,
		armDeg = 4.5,
		enterDeg = 1.5,
		exitDeg = 2.4,
		minGap = 2.5, -- half the baseline
	},
	s2 = {
		radius = 2.0,
		nominalDistance = 9,
		bandDeg = 12.0,
		armDeg = 4.0,
		enterDeg = 1.3,
		exitDeg = 2.1,
		minGap = 1.5,
	},

	settleTime = 0.5,
	snapTime = 0.22,
	postSnapHold = 0.12,
	boltTime = 0.45,
	doorTime = 1.2,
	panelOpenFraction = 0.9, -- past this the panel latches open
	moteMaxRate = 40,
	burstCount = 36,
}

local Demo2 = {}

Demo2.id = "room"
Demo2.title = "DEMO 2 — ROOM-SCALE ALIGN-TO-UNLOCK"
Demo2.blurb = "Walk a room. Line up two markers to unlock a panel, then line up again."
Demo2.ready = true
Demo2.region = CFrame.new(9000, 0, 0)

local session: Session.Handle? = nil

function Demo2.stop()
	local live = session
	if live then
		live.stop()
	end
	session = nil
end

function Demo2.start(ctx: Shell.Context): boolean
	local live = Session.new("demo2")
	session = live

	return live.start(function(s: Session.Handle)
		local cam = ctx.camera
		local origin = Demo2.region

		local hud = Hud.new(ctx.playerGui, Demo2.title)
		s.add(hud.destroy)
		hud.fade(0, 0)

		-- An interior: the blanket profile demo 1 uses would flatten it into a lit box. Only
		-- depth of field is worth suppressing here.
		s.add(ctx.dim({ depthOfField = true }))

		local room = Room.build(origin, workspace)
		s.add(room.destroy)

		ctx.place(room.spawnCF)

		--------------------------------------------------------------------------------
		-- camera
		--------------------------------------------------------------------------------
		local opts = Orbit.defaults()
		opts.distance = TUNE.orbitDistance
		opts.height = TUNE.orbitHeight

		local character = ctx.player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local orbit = Orbit.new(cam, if root and root:IsA("BasePart") then root else nil, opts)
		s.add(orbit.restore)
		orbit.set(math.rad(180), math.rad(20))
		-- Starting inside a respawn window is reachable: die in the lobby, click DEMO 2. With no
		-- subject the focus would sit at the world origin, 9,000 studs from the room, and the
		-- demo would fade up on empty space. Seed it where the respawn is going to land; the
		-- onCharacter hook takes over the moment there is a body.
		orbit.setFocus(room.spawnCF.Position + Vector3.new(0, TUNE.orbitHeight, 0))

		-- The avatar is excluded from CAMERA collision and deliberately NOT from the anchor
		-- occlusion test below: the body should hide the markers, but it must never shove the
		-- camera.
		local function refreshCameraFilter()
			-- Only the avatar is exempt from pushing the camera; the room must block it.
			local body = ctx.player.Character
			orbit.setFilter(if body then { body } else {})
		end
		refreshCameraFilter()

		ctx.onCharacter(function(fresh: Model)
			local freshRoot = fresh:FindFirstChild("HumanoidRootPart")
			if freshRoot and freshRoot:IsA("BasePart") then
				orbit.setSubject(freshRoot)
			end
			refreshCameraFilter()
		end)

		--------------------------------------------------------------------------------
		-- occlusion
		--
		-- The only visibility predicate in Align is inFront, a half-space sign test. Real
		-- occlusion is a raycast, and it belongs at the CALL SITE: Align is deliberately
		-- stateless and dependency-free. RespectCanCollide stays false, so a decorative
		-- non-colliding part still blocks -- which is what we want from a wall.
		--------------------------------------------------------------------------------
		local sightParams = RaycastParams.new()
		sightParams.FilterType = Enum.RaycastFilterType.Exclude -- Blacklist/Whitelist are gone
		sightParams.FilterDescendantsInstances = room.markers
		sightParams.RespectCanCollide = false
		sightParams.IgnoreWater = true

		local eyeNow = cam.CFrame.Position

		local function clearLineTo(target: Vector3): boolean
			local delta = target - eyeNow
			local dist = delta.Magnitude
			if dist < 0.05 then
				return false
			end
			local hit = workspace:Raycast(eyeNow, delta.Unit * (dist - 0.15), sightParams)
			return hit == nil
		end

		--------------------------------------------------------------------------------
		-- feedback
		--------------------------------------------------------------------------------
		local fx = Feedback.new()
		s.add(fx.destroy)

		local allGlow: { BasePart } = {}
		for _, part in room.stage1Glow do
			table.insert(allGlow, part)
		end
		for _, part in room.stage2Glow do
			table.insert(allGlow, part)
		end

		fx.add(Feedback.glow(allGlow, Room.COLD, Room.HOT, nil))
		fx.add(Feedback.motes(room.emitters, TUNE.moteMaxRate))
		-- Feedback.halo is deliberately absent: its rest poses are captured in WORLD space at
		-- build time, which is fine only while the camera is parked. Here the camera orbits.
		local pulseChannel, pulse = Feedback.pulse(allGlow, Color3.new(1, 1, 1), 0.22)
		fx.add(pulseChannel)
		local burst = Feedback.burst(room.emitters, TUNE.burstCount)
		fx.on("locked", pulse)
		fx.on("solved", function()
			pulse()
			burst()
		end)

		--------------------------------------------------------------------------------
		-- the two stages
		--------------------------------------------------------------------------------
		local function subtendFor(radius: number, distance: number): number
			return math.deg(2 * math.atan(radius / distance))
		end

		local near1Local, far1Local = Room.stage1Anchors()
		local near2Local, far2Local = Room.stage2Anchors()
		local s1Center = origin * CFrame.new(near1Local:Lerp(far1Local, 0.5))
		local s2Center = origin * CFrame.new(near2Local:Lerp(far2Local, 0.5))

		local stage2: Chain.Puzzle
		local stage1: Chain.Puzzle

		local function boltMechanism(): Chain.Poser?
			local t = 0
			return function(_root: CFrame, dt: number): boolean
				t = math.min(t + dt / TUNE.boltTime, 1)
				local e = Damp.easeOutQuint(t)
				for i, bolt in room.bolts do
					local side = if i % 2 == 0 then 1 else -1
					bolt.CFrame = room.panelClosed
						* CFrame.new(-0.2 - e * 0.55, (if i <= 2 then -1.5 else 1.5), side * 1.7)
					bolt.Color = Room.AMBER:Lerp(Room.HOT, e)
				end
				return t >= 1
			end
		end

		local function doorMechanism(): Chain.Poser?
			local t = 0
			return function(_root: CFrame, dt: number): boolean
				t = math.min(t + dt / TUNE.doorTime, 1)
				room.door.CFrame = room.doorClosed:Lerp(room.doorOpen, Damp.easeOutQuint(t))
				return t >= 1
			end
		end

		stage2 = {
			name = "alcove",
			anchors = function(): (Vector3, Vector3)
				return room.stage2Near.Position, room.stage2Far.Position
			end,
			-- The pair's OWN neighbourhood, never the room's. Passing the room would put the eye
			-- inside the sphere for the entire session: subtendDeg returns 180 there, sepNorm
			-- silently becomes sepDeg/180, and the demo looks like it works while responding to
			-- nothing that was authored. This centre sits behind the wall, so the eye is outside
			-- it by construction.
			sphere = function(): (Vector3, number)
				return s2Center.Position, TUNE.s2.radius
			end,
			minGap = TUNE.s2.minGap,
			slackFrac = 0,
			thresholds = Chain.fromDegrees(
				TUNE.s2.bandDeg,
				TUNE.s2.armDeg,
				TUNE.s2.enterDeg,
				TUNE.s2.exitDeg,
				subtendFor(TUNE.s2.radius, TUNE.s2.nominalDistance)
			),
			visible = function(): boolean
				return clearLineTo(room.stage2Near.Position) and clearLineTo(room.stage2Far.Position)
			end,
			mechanism = doorMechanism,
			onSolved = nil,
		}

		stage1 = {
			name = "hangers",
			anchors = function(): (Vector3, Vector3)
				return room.stage1Near.Position, room.stage1Far.Position
			end,
			sphere = function(): (Vector3, number)
				return s1Center.Position, TUNE.s1.radius
			end,
			minGap = TUNE.s1.minGap,
			slackFrac = 0,
			thresholds = Chain.fromDegrees(
				TUNE.s1.bandDeg,
				TUNE.s1.armDeg,
				TUNE.s1.enterDeg,
				TUNE.s1.exitDeg,
				subtendFor(TUNE.s1.radius, TUNE.s1.nominalDistance)
			),
			visible = function(): boolean
				return clearLineTo(room.stage1Near.Position) and clearLineTo(room.stage1Far.Position)
			end,
			mechanism = boltMechanism,
			onSolved = function(): Chain.Puzzle?
				return stage2
			end,
		}

		local chain = Chain.new(stage1)

		--------------------------------------------------------------------------------
		-- boot self-check: prove sepNorm responds to viewpoint
		--------------------------------------------------------------------------------
		do
			local near1, far1 = room.stage1Near.Position, room.stage1Far.Position
			local center = s1Center.Position
			local axis = (near1 - far1).Unit
			local onLine = near1 + axis * TUNE.s1.nominalDistance
			-- A viewpoint rotated well off the solution must read far above the feedback band.
			local wrong = center + (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(35)) * (onLine - center))

			local good = Align.probe(onLine, (center - onLine).Unit, near1, far1, center, TUNE.s1.radius, TUNE.s1.minGap, 0)
			local bad = Align.probe(wrong, (center - wrong).Unit, near1, far1, center, TUNE.s1.radius, TUNE.s1.minGap, 0)
			local t = stage1.thresholds
			print(
				("[demo2] self-check: on-line sepNorm %.5f (enter %.5f) · 35 deg off sepNorm %.3f (band %.3f)"):format(
					good.sepNorm,
					t.enter,
					bad.sepNorm,
					t.band
				)
			)
			if good.sepNorm > t.enter then
				warn("[demo2] the authored solution does not reach the lock threshold")
			end
			if bad.sepNorm <= t.band then
				warn("[demo2] an off-axis viewpoint is inside the feedback band: the sphere or thresholds are wrong")
			end
			print(
				("[demo2] stage1 lock %.2f deg / arm %.2f deg · stage2 lock %.2f deg / arm %.2f deg"):format(
					TUNE.s1.enterDeg,
					TUNE.s1.armDeg,
					TUNE.s2.enterDeg,
					TUNE.s2.armDeg
				)
			)
		end

		--------------------------------------------------------------------------------
		-- state
		--------------------------------------------------------------------------------
		type Phase = "Settling" | "Play" | "Committing" | "Revealing" | "Manipulating" | "Opened"
		local phase: Phase = "Settling"
		local settleFor = 0
		local holdFor = 0
		local armed = false
		local commitQueued = false
		local resetQueued = false
		local warnedInside = false

		local snapping = false
		local snapT = 0
		local fromYaw, fromPitch = 0, 0
		local toYaw, toPitch = 0, 0
		local refusedFor = 0

		local panelOffset = 0
		local panelLatched = false
		local grabParam = 0
		local grabOffset = 0

		--------------------------------------------------------------------------------
		-- input: ONE Drag instance, routed. Two capture surfaces would fight over InputBegan.
		--------------------------------------------------------------------------------
		local panelParams = RaycastParams.new()
		panelParams.FilterType = Enum.RaycastFilterType.Include
		panelParams.FilterDescendantsInstances = { room.panel }
		panelParams.RespectCanCollide = false

		--[[ Closest parameter along the panel's slide axis to the pointer ray. ]]
		local function axisParam(rayOrigin: Vector3, rayDir: Vector3): number?
			local a0 = room.panelClosed.Position
			local ad = room.panelAxis.Unit
			local bd = rayDir.Unit
			local adbd = ad:Dot(bd)
			local denom = 1 - adbd * adbd
			if math.abs(denom) < 1e-4 then
				return nil -- looking straight down the slide axis: no usable projection
			end
			local r = rayOrigin - a0
			return (r:Dot(ad) - adbd * r:Dot(bd)) / denom
		end

		--[[
			Classified ON PRESS and BEFORE any mouse lock: after LockCurrentPosition there is no
			screen point left to unproject, so the hit test must happen here or not at all.
		]]
		local function classify(pos: Vector2): string
			if phase ~= "Manipulating" or panelLatched then
				return "orbit"
			end
			-- ViewportPointToRay, not ScreenPointToRay: this is the documented pairing for a
			-- point from UserInputService:GetMouseLocation (and for a touch InputObject's
			-- Position). ScreenPointToRay offsets by the GUI inset and would be ~36 px off
			-- vertically, which at a distance turns into a visible mis-grab near the top of
			-- the screen.
			local ray = cam:ViewportPointToRay(pos.X, pos.Y)
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 300, panelParams)
			if not hit then
				return "orbit"
			end
			local param = axisParam(ray.Origin, ray.Direction)
			if not param then
				return "orbit"
			end
			grabParam = param
			grabOffset = panelOffset
			return "panel"
		end

		-- touchHalf: the player WALKS here, so a full-screen Modal surface would sit on top of the
		-- default thumbstick and it would never receive input at all.
		local drag = Drag.new(cam, hud.gui, { classify = classify, touchHalf = true })
		s.add(drag.destroy)
		drag.setEnabled(false)

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

		--[[ Freeze only across the snap: the solve is relative to the focus, so a walking player
		     would be re-aiming the target underneath the animation. ]]
		local unfreeze: (() -> ())? = nil
		local function freezeCharacter(on: boolean)
			if on then
				if not unfreeze then
					unfreeze = Shell.holdCharacter(ctx.player)
				end
			elseif unfreeze then
				unfreeze()
				unfreeze = nil
			end
		end
		s.add(function()
			freezeCharacter(false)
		end)

		--[[
			The viewpoint that coincides the anchors, solved in the frame centred on the camera's
			FOCUS -- but at the radius the eye is ACTUALLY at, not the nominal boom length.
			Orbit's collision clamp pulls the eye in whenever a wall is behind the player, which
			indoors is the normal case rather than an edge case, and solving against 13 studs
			while sitting at 8 aims the snap at a pose the camera cannot occupy.

			The pitch range is passed asymmetrically for the same reason: the rig clamps to
			[-14, +62], so a symmetric limit would accept solutions it then silently clamps away.
		]]
		local function solveSnap(): (number?, number?, string?)
			local puzzle = chain.current()
			if not puzzle then
				return nil, nil, "no live stage"
			end
			local focus = orbit.focusPoint()
			local near, far = puzzle.anchors()
			return Align.solve(
				near - focus,
				far - focus,
				orbit.radius(),
				math.rad(opts.maxPitchDeg),
				math.rad(opts.minPitchDeg)
			)
		end

		--[[ Did the snap actually land on the alignment? Checked against the ARM window, which is
		     the same generous threshold that accepted the commit. ]]
		local function snapLanded(): boolean
			local puzzle = chain.current()
			if not puzzle then
				return false
			end
			local near, far = puzzle.anchors()
			local center, radius = puzzle.sphere()
			local p = Align.probe(
				orbit.eye(),
				orbit.look(),
				near,
				far,
				center,
				radius,
				puzzle.minGap,
				puzzle.slackFrac
			)
			return p.valid and p.orderOk and p.sepNorm <= puzzle.thresholds.arm
		end

		local function setPanel(offset: number)
			panelOffset = math.clamp(offset, 0, room.panelTravel)
			room.panel.CFrame = room.panelClosed + room.panelAxis.Unit * panelOffset
		end

		local function resetDemo()
			phase = "Settling"
			settleFor = 0
			armed = false
			snapping = false
			refusedFor = 0
			panelLatched = false
			chain.reset(stage1)
			setPanel(0)
			room.door.CFrame = room.doorClosed
			for i, bolt in room.bolts do
				bolt.CFrame = room.panelClosed * CFrame.new(-0.2, (if i <= 2 then -1.5 else 1.5), (if i % 2 == 0 then 1 else -1) * 1.7)
				bolt.Color = Room.AMBER
			end
			drag.setEnabled(false)
			freezeCharacter(false)
			hud.setState("")
			hud.setHint("")
			hud.setProgress(0, false, false)
		end

		local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.E then
				commitQueued = true
			elseif input.KeyCode == Enum.KeyCode.R then
				resetQueued = true
			elseif input.KeyCode == Enum.KeyCode.Q then
				doExit()
			end
		end)
		s.track(inputConn)

		--------------------------------------------------------------------------------
		-- stage transitions
		--------------------------------------------------------------------------------
		local function afterStage1()
			local nextPuzzle, why = chain.advance()
			if why then
				warn(`[demo2] stage "{nextPuzzle and nextPuzzle.name or "?"}" is unsolvable: {why}`)
				hud.setState("STAGE 2 FAILED — see output")
				phase = "Opened"
				return
			end
			phase = "Manipulating"
			freezeCharacter(false)
			drag.setEnabled(true)
			hud.setState("UNLOCKED")
			hud.setHint("drag the panel aside")
		end

		local function afterStage2()
			chain.advance()
			phase = "Opened"
			freezeCharacter(false)
			drag.setEnabled(true)
			hud.setState("OPEN")
			hud.setHint("the way is open · R to reset · Q or EXIT to leave")
		end

		local function beginReveal()
			local solved = chain.current()
			phase = "Revealing"
			local animating = chain.beginMechanism()
			fx.fire("solved")
			hud.setState("ENGAGED")
			if not animating then
				-- `mechanism` may exist and still return nil, so the chain's own answer is the
				-- only reliable test for "there is nothing to wait on".
				if solved == stage1 then
					afterStage1()
				else
					afterStage2()
				end
			end
		end

		local function refuseCommit(why: string)
			warn(`[demo2] commit refused: {why}`)
			refusedFor = 1.4
			freezeCharacter(false)
			snapping = false
			phase = "Play"
			drag.setEnabled(true)
		end

		--------------------------------------------------------------------------------
		-- THE FRAME LOOP
		--------------------------------------------------------------------------------
		local bind = ctx.bindName
		RunService:BindToRenderStep(bind, Enum.RenderPriority.Camera.Value + 1, function(rawDt: number)
			local dt = Damp.clampDt(rawDt)

			if resetQueued then
				resetQueued = false
				if phase ~= "Committing" and phase ~= "Revealing" then
					resetDemo()
				end
			end

			-- 1. input, consumed exactly once
			local f = drag.consume()
			-- `mode` is decided on press and stays put until the next one, so it is only
			-- authoritative while the button is DOWN. Gating on held as well is what stops a
			-- press that began on the panel from spinning the camera once the panel latches --
			-- and stops a released panel press from blocking the camera forever.
			local panelPress = f.mode == "panel" and f.held
			local canOrbit = phase ~= "Committing" and not panelPress

			if panelPress and phase == "Manipulating" and not panelLatched then
				local ray = cam:ViewportPointToRay(f.pos.X, f.pos.Y)
				local param = axisParam(ray.Origin, ray.Direction)
				if param then
					setPanel(grabOffset + (param - grabParam))
				end
			elseif canOrbit and (f.dx ~= 0 or f.dy ~= 0) then
				orbit.turn(f.dx, f.dy)
			end

			-- Checked every frame in this phase, not only while dragging: releasing exactly past
			-- the threshold must still latch.
			if phase == "Manipulating" and not panelLatched and panelOffset >= room.panelTravel * TUNE.panelOpenFraction then
				panelLatched = true
				setPanel(room.panelTravel)
				phase = "Play"
				hud.setState("")
				hud.setHint("a second pair is exposed")
			end

			-- 2. commit, accepted at the ARM threshold and never at the lock threshold
			local wantsCommit = commitQueued or (f.tapped and f.mode ~= "panel")
			commitQueued = false
			if wantsCommit and phase == "Play" and chain.current() and armed then
				-- Freeze FIRST, then converge the focus onto the frozen body. The focus chases the
				-- root with a 0.12 s time constant, so a player who commits while still walking is
				-- ~2 studs behind it -- and the snap would be solved in a frame that keeps moving
				-- underneath the animation.
				freezeCharacter(true)
				local body = ctx.player.Character
				local bodyRoot = if body then body:FindFirstChild("HumanoidRootPart") else nil
				if bodyRoot and bodyRoot:IsA("BasePart") then
					orbit.setFocus(bodyRoot.Position + Vector3.new(0, TUNE.orbitHeight, 0))
				end

				local yaw, pitch, why = solveSnap()
				if yaw and pitch then
					fromYaw, fromPitch = orbit.get()
					toYaw, toPitch = yaw, pitch
					snapT = 0
					snapping = true
					phase = "Committing"
					holdFor = 0
					drag.setEnabled(false)
					hud.setState("ENGAGING")
				else
					refuseCommit(why or "no reachable viewpoint from here")
				end
			end

			-- 3. camera
			if snapping then
				-- Re-solved every frame: the collision clamp changes the boom length as the
				-- direction sweeps, so a target fixed at press time drifts off the anchor line
				-- during its own animation.
				local reYaw, rePitch = solveSnap()
				if reYaw and rePitch then
					toYaw, toPitch = reYaw, rePitch
				end
				snapT += dt
				local t = math.clamp(snapT / TUNE.snapTime, 0, 1)
				local e = Damp.easeOutQuint(t)
				orbit.set(fromYaw + Damp.shortestArc(fromYaw, toYaw) * e, fromPitch + (toPitch - fromPitch) * e)
				if t >= 1 then
					snapping = false
				end
			end
			orbit.step(dt)
			eyeNow = orbit.eye()

			-- Verified against the pose that was actually RENDERED, after the clamp has had its
			-- say. The mechanism must never fire on a viewpoint that does not show the illusion.
			if phase == "Committing" and not snapping and holdFor <= 0 then
				if snapLanded() then
					holdFor = 0.0001
				else
					refuseCommit("the snapped viewpoint is blocked or clamped short")
				end
			end

			-- 4. mechanisms: every poser, every frame, forever. Nothing here pivots, so an
			--    abandoned poser would simply freeze its part mid-slide.
			local newestDone = chain.pose(CFrame.new(), dt)
			if newestDone and phase == "Revealing" then
				if chain.current() == stage1 then
					afterStage1()
				else
					afterStage2()
				end
			end

			-- 5. score
			local prox
			if phase == "Settling" then
				settleFor += dt
				prox = chain.relax(dt)
				hud.setProgress(prox, false, false)
				if settleFor >= TUNE.settleTime then
					phase = "Play"
					drag.setEnabled(true)
					hud.setHint("walk and orbit until the ring and the bead line up")
				end
			elseif phase == "Play" then
				local score = chain.score(dt, eyeNow, orbit.look())
				prox = score.prox
				armed = score.armed
				if score.enteredLocked then
					fx.fire("locked")
				end
				if refusedFor > 0 then
					refusedFor -= dt
					hud.setState("MOVE CLOSER")
				elseif score.eyeInside then
					-- Asserted every frame. Align fails closed on it, but the player needs to be
					-- told why the markers went quiet.
					hud.setState("STEP BACK")
					if not warnedInside then
						warnedInside = true
						warn("[demo2] the eye entered the subject sphere; scoring is suspended")
					end
				elseif score.occluded then
					hud.setState("BLOCKED")
				elseif not score.orderOk then
					-- The antipode shows a picture-perfect overlap and scores nothing, because the
					-- authored near anchor is the far one from there. Without this line the meter
					-- just sits dead and the player has no idea why.
					hud.setState("WRONG SIDE")
				else
					hud.setState(
						if score.state == "Locked" and armed
							then "ALIGNED — click or E"
							elseif score.state == "Locked" then "ALIGNED"
							elseif armed then "click or E to engage"
							else ""
					)
				end
				hud.setProgress(prox, armed, score.state == "Locked")
			elseif phase == "Manipulating" or phase == "Opened" then
				armed = false
				prox = chain.relax(dt)
				hud.setProgress(prox, false, false)
			else
				armed = false
				prox = chain.hold(dt)
				hud.setProgress(1, false, true)
			end

			fx.render(prox, dt)

			-- 6. the reveal is caused by the snap, not simultaneous with it
			if phase == "Committing" and holdFor > 0 then
				holdFor += dt
				if holdFor >= TUNE.postSnapHold then
					beginReveal()
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

return Demo2
