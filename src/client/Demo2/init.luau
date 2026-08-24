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
			local ray = cam:ScreenPointToRay(pos.X, pos.Y)
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

		local drag = Drag.new(cam, hud.gui, { classify = classify })
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

		local function setPanel(offset: number)
			panelOffset = math.clamp(offset, 0, room.panelTravel)
			room.panel.CFrame = room.panelClosed + room.panelAxis.Unit * panelOffset
		end

		local function resetDemo()
			phase = "Settling"
			settleFor = 0
			armed = false
			snapping = false
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
			chain.beginMechanism()
			fx.fire("solved")
			hud.setState("ENGAGED")
			if solved and not solved.mechanism then
				if solved == stage1 then
					afterStage1()
				else
					afterStage2()
				end
			end
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
			local canOrbit = phase ~= "Committing"
			if f.mode == "panel" and phase == "Manipulating" and not panelLatched then
				if f.held then
					local ray = cam:ScreenPointToRay(f.pos.X, f.pos.Y)
					local param = axisParam(ray.Origin, ray.Direction)
					if param then
						setPanel(grabOffset + (param - grabParam))
					end
				end
				if panelOffset >= room.panelTravel * TUNE.panelOpenFraction then
					panelLatched = true
					setPanel(room.panelTravel)
					phase = "Play"
					hud.setState("")
					hud.setHint("a second pair is exposed")
				end
			elseif canOrbit and (f.dx ~= 0 or f.dy ~= 0) then
				orbit.turn(f.dx, f.dy)
			end

			-- 2. commit, accepted at the ARM threshold and never at the lock threshold
			local wantsCommit = commitQueued or (f.tapped and f.mode ~= "panel")
			commitQueued = false
			if wantsCommit and phase == "Play" and chain.current() and armed then
				local puzzle = chain.current()
				-- The snap target is solved in the frame centred on the CAMERA'S FOCUS, at the
				-- orbit radius: that is the sphere the eye actually lives on.
				local focus = orbit.focusPoint()
				local near, far = (puzzle :: Chain.Puzzle).anchors()
				local yaw, pitch, why = Align.solve(near - focus, far - focus, TUNE.orbitDistance, math.rad(opts.maxPitchDeg))
				if yaw and pitch then
					fromYaw, fromPitch = orbit.get()
					toYaw, toPitch = yaw, pitch
					snapT = 0
					snapping = true
					phase = "Committing"
					holdFor = 0
					freezeCharacter(true)
					drag.setEnabled(false)
					hud.setState("ENGAGING")
				else
					-- Loud rather than silent: a refused commit with no explanation is the worst
					-- possible feel.
					warn(`[demo2] commit refused, no reachable snap from here: {why}`)
					hud.setState("MOVE CLOSER")
				end
			end

			-- 3. camera
			if snapping then
				snapT += dt
				local t = math.clamp(snapT / TUNE.snapTime, 0, 1)
				local e = Damp.easeOutQuint(t)
				orbit.set(fromYaw + Damp.shortestArc(fromYaw, toYaw) * e, fromPitch + (toPitch - fromPitch) * e)
				if t >= 1 then
					snapping = false
					holdFor = 0.0001
				end
			end
			orbit.step(dt)
			eyeNow = orbit.eye()

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
				if score.eyeInside then
					-- Asserted every frame. Align fails closed on it, but the player needs to be
					-- told why the markers went quiet.
					hud.setState("STEP BACK")
					if not warnedInside then
						warnedInside = true
						warn("[demo2] the eye entered the subject sphere; scoring is suspended")
					end
				elseif score.occluded then
					hud.setState("BLOCKED")
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
