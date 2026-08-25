--!strict
--[[
	DEMO 3 — IMPOSSIBLE CONNECTOR (lock-to-connect)

	Demo 2 proved alignment can GATE an interaction. This is the payoff: alignment CREATES REAL
	GEOMETRY YOU WALK ACROSS. Line the two sockets up, commit, and a connector materialises along
	the true 3D line between them. Then the camera stops mattering entirely -- the connector is
	real, it stays, and you cross it with your actual avatar.

	WHY THIS ONE IS DIFFERENT, AND IT IS THE MOST INTERESTING THING ABOUT IT:
	this is the only demo of the four whose RESULT is coherent from every camera in the server.
	Demos 1, 2 and 4 are camera-relative and inherently single-viewer -- the illusion lives in one
	player's projection. Here the alignment is merely the TRIGGER; what it produces is world-space
	geometry that every client would agree about. That is the difference between a trick and a
	mechanic that could ship in a multiplayer game.

	OWNING THE SEAM. From the locking seat the connector is foreshortened to nothing. From every
	other angle it is a long beam hanging in space, and no amount of care hides that. So it is
	deliberately stylised -- floating slabs with a Neon spine that assemble from the near anchor
	outward. A plank bridge seen off-angle looks like a bug; a light bridge that built itself
	looks like something you cast.

	CONTROLS  walk with WASD · drag to orbit · click or E to engage when armed · R reset ·
	          Q or EXIT to leave
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
local Field = require(script.Field)

--[[
	Thresholds are authored in DEGREES and divided once by the pair's nominal apparent diameter.
	Nothing dimensionless from another demo is portable: the subject spheres differ.

	The subject sphere here deviates from the usual "half the baseline plus the art", and it is a
	considered deviation. With a 40-stud baseline in an OPEN EXTERIOR that sphere is 21 studs
	across the middle of the chasm, and the orbit camera -- which swings ~10.5 studs past the
	player -- can enter it whenever the player stands at a platform edge. Inside the sphere
	subtendDeg returns 180, probe fails closed, and the HUD would be shouting STEP BACK during
	ordinary walking. The normalisation is valid for ANY radius, because sepNorm reduces to
	(perpendicular offset / 2r) with the viewing distance cancelling either way; the radius only
	sets the scale. So the sphere is sized on the marker art instead, and the clearance from every
	standable spot is asserted numerically rather than assumed.
]]
local TUNE = {
	orbitDistance = 11,
	orbitHeight = 1.6,
	-- Wider than Orbit.defaults' -14. The anchor line sits 1.2 studs above the deck the player
	-- stands on, so the eye has to get DOWN to it: -18 deg with this boom. -30 leaves headroom
	-- for the player standing on uneven ground or mid-step.
	minPitchDeg = -30,
	maxPitchDeg = 55,

	s1 = { radius = 6.0, nominalDistance = 25, minGap = 20, bandDeg = 12.0, armDeg = 3.5, enterDeg = 1.2, exitDeg = 1.9 },
	s2 = { radius = 4.0, nominalDistance = 28, minGap = 17, bandDeg = 12.0, armDeg = 3.5, enterDeg = 1.2, exitDeg = 1.9 },

	settleTime = 0.5,
	snapTime = 0.22,
	postSnapHold = 0.12,
	connectorTime = 0.9,
	maxSlopeDeg = 4, -- a connector is a bridge, not a ramp: assert it at boot
	fallY = -15, -- below this the catch volume re-places the player
	moteMaxRate = 34,
	burstCount = 40,
}

local Demo3 = {}

Demo3.id = "connector"
Demo3.title = "DEMO 3 — IMPOSSIBLE CONNECTOR"
Demo3.blurb = "Line up two sockets and a bridge becomes real. Then the camera stops mattering."
Demo3.ready = true
Demo3.region = CFrame.new(-9000, 0, 0)

local session: Session.Handle? = nil

function Demo3.stop()
	local live = session
	if live then
		live.stop()
	end
	session = nil
end

function Demo3.start(ctx: Shell.Context): boolean
	local live = Session.new("demo3")
	session = live

	return live.start(function(s: Session.Handle)
		local cam = ctx.camera
		local origin = Demo3.region

		local hud = Hud.new(ctx.playerGui, Demo3.title)
		s.add(hud.destroy)
		hud.fade(0, 0)

		s.add(ctx.dim({ depthOfField = true }))

		local field = Field.build(origin, workspace)
		s.add(field.destroy)
		ctx.place(field.spawnCF)

		--------------------------------------------------------------------------------
		-- camera
		--------------------------------------------------------------------------------
		local opts = Orbit.defaults()
		opts.distance = TUNE.orbitDistance
		opts.height = TUNE.orbitHeight
		opts.minPitchDeg = TUNE.minPitchDeg
		opts.maxPitchDeg = TUNE.maxPitchDeg

		local character = ctx.player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local orbit = Orbit.new(cam, if root and root:IsA("BasePart") then root else nil, opts)
		s.add(orbit.restore)
		-- Orbit yaw is the direction from the focus to the EYE, so 0 parks the camera at +Z --
		-- behind a player who faces -Z, looking up the span. 180 pointed both away from the set.
		orbit.set(0, math.rad(-16))
		-- Starting inside a respawn window is reachable (die in the lobby, pick demo 3), and with
		-- no subject the focus would sit at the world origin 9,000 studs away.
		orbit.setFocus(field.spawnCF.Position + Vector3.new(0, TUNE.orbitHeight, 0))

		local function refreshCameraFilter()
			local body = ctx.player.Character
			orbit.setFilter(if body then { body } else {})
		end
		refreshCameraFilter()

		--------------------------------------------------------------------------------
		-- occlusion
		--------------------------------------------------------------------------------
		--[[
			The avatar is EXCLUDED here, which reverses the usual rule that the body should occlude
			the markers. It has to be. The anchor line sits 1.2 studs up -- knee height -- and the
			camera is over the player's shoulder, so at the solved viewpoint the ray from eye to
			near anchor runs lengthwise through the player's own shins on every frame. Body
			occlusion would mean the demo can never score at all. The wrong-side job that body
			occlusion was buying is already done, properly, by depth order + inFront + minGap.
		]]
		local sightParams = RaycastParams.new()
		sightParams.FilterType = Enum.RaycastFilterType.Exclude
		sightParams.FilterDescendantsInstances = field.markers
		-- Deliberate: decorative non-colliding props still block a sight line, which is what we
		-- want from scenery. Everything that must NOT block is in the exclude list instead.
		sightParams.RespectCanCollide = false
		sightParams.IgnoreWater = true

		local eyeNow = cam.CFrame.Position

		local function refreshSight()
			local list: { Instance } = {}
			for _, m in field.markers do
				table.insert(list, m)
			end
			local body = ctx.player.Character
			if body then
				table.insert(list, body)
			end
			sightParams.FilterDescendantsInstances = list
		end
		refreshSight()

		local function clearLineTo(target: Vector3): boolean
			local delta = target - eyeNow
			local dist = delta.Magnitude
			if dist < 0.05 then
				return false
			end
			return workspace:Raycast(eyeNow, delta.Unit * (dist - 0.2), sightParams) == nil
		end

		--------------------------------------------------------------------------------
		-- feedback
		--------------------------------------------------------------------------------
		local fx = Feedback.new()
		s.add(fx.destroy)

		local glowParts: { BasePart } = {}
		local function addGlow(parts: { BasePart })
			for _, p in parts do
				table.insert(glowParts, p)
			end
		end
		addGlow(field.stage1.glow)

		-- Feedback.halo is absent on purpose: its rest poses are world-fixed, so it slides off
		-- screen the moment the camera orbits.
		fx.add(Feedback.glow(glowParts, Field.COLD, Field.HOT, nil))
		local emitters: { ParticleEmitter } = {}
		fx.add(Feedback.motes(emitters, TUNE.moteMaxRate))
		local pulseChannel, pulse = Feedback.pulse(glowParts, Color3.new(1, 1, 1), 0.22)
		fx.add(pulseChannel)
		local burst = Feedback.burst(emitters, TUNE.burstCount)
		fx.on("locked", pulse)
		fx.on("solved", function()
			pulse()
			burst()
		end)

		local function emitterFor(host: BasePart)
			local e = Instance.new("ParticleEmitter")
			e.Rate = 0
			e.Lifetime = NumberRange.new(0.6, 1.4)
			e.Speed = NumberRange.new(0.4, 1.1)
			e.SpreadAngle = Vector2.new(180, 180)
			e.Size = NumberSequence.new(0.3)
			e.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.3, 0.25),
				NumberSequenceKeypoint.new(1, 1),
			})
			e.Color = ColorSequence.new(Field.HOT)
			e.LightEmission = 1
			e.LightInfluence = 0
			e.LockedToPart = true
			e.Parent = host
			table.insert(emitters, e)
		end
		emitterFor(field.stage1.near)

		--------------------------------------------------------------------------------
		-- connectors
		--------------------------------------------------------------------------------
		local connectors: { Field.Connector } = {}
		s.add(function()
			for _, c in connectors do
				c.destroy()
			end
		end)

		--[[ Materialises from the near anchor outward: it sells the causality, and it covers the
		     frame in which the geometry appears. Collision arrives per segment. ]]
		local function connectorMechanism(fromLocal: Vector3, toLocal: Vector3): () -> Chain.Poser?
			return function(): Chain.Poser?
				local built = Field.connector(origin, fromLocal, toLocal, field.folder)
				table.insert(connectors, built)
				local t = 0
				local total = #built.segments
				return function(_root: CFrame, dt: number): boolean
					t = math.min(t + dt / TUNE.connectorTime, 1)
					local eased = Damp.easeOutQuint(t)
					local arrived = math.floor(eased * total + 0.0001)
					for i, seg in built.segments do
						if i <= arrived then
							if seg.Transparency > 0 then
								seg.Transparency = 0
								seg.CanCollide = seg.Name == "Slab"
								seg.CanQuery = true
							end
						end
					end
					return t >= 1
				end
			end
		end

		--------------------------------------------------------------------------------
		-- stages
		--------------------------------------------------------------------------------
		local stage2Pair: Field.Pair? = nil

		local function sphereFor(nearLocal: Vector3, farLocal: Vector3, radius: number): () -> (Vector3, number)
			local centre = origin * CFrame.new(nearLocal:Lerp(farLocal, 0.5))
			return function(): (Vector3, number)
				return centre.Position, radius
			end
		end

		local function thresholdsFor(cfg: { radius: number, nominalDistance: number, bandDeg: number, armDeg: number, enterDeg: number, exitDeg: number }): Chain.Thresholds
			local subtend = math.deg(2 * math.atan(cfg.radius / cfg.nominalDistance))
			return Chain.fromDegrees(cfg.bandDeg, cfg.armDeg, cfg.enterDeg, cfg.exitDeg, subtend)
		end

		local stage2: Chain.Puzzle
		local stage1: Chain.Puzzle

		stage2 = {
			name = "span-b",
			anchors = function(): (Vector3, Vector3)
				local p = stage2Pair
				if not p then
					return Vector3.zero, Vector3.zero
				end
				return p.near.Position, p.far.Position
			end,
			sphere = sphereFor(Field.S2_NEAR, Field.S2_FAR, TUNE.s2.radius),
			minGap = TUNE.s2.minGap,
			slackFrac = 0,
			thresholds = thresholdsFor(TUNE.s2),
			visible = function(): boolean
				local p = stage2Pair
				if not p then
					return false
				end
				return clearLineTo(p.near.Position) and clearLineTo(p.far.Position)
			end,
			solve = function(): (number?, number?, string?)
				local p = stage2Pair
				if not p then
					return nil, nil, "stage 2 anchors do not exist yet"
				end
				local focus = orbit.focusPoint()
				return Align.solve(
					p.near.Position - focus,
					p.far.Position - focus,
					orbit.radius(),
					math.rad(opts.maxPitchDeg),
					math.rad(opts.minPitchDeg)
				)
			end,
			mechanism = connectorMechanism(Field.S2_NEAR, Field.S2_FAR),
			onSolved = nil,
		}

		stage1 = {
			name = "span-a",
			anchors = function(): (Vector3, Vector3)
				return field.stage1.near.Position, field.stage1.far.Position
			end,
			sphere = sphereFor(Field.S1_NEAR, Field.S1_FAR, TUNE.s1.radius),
			minGap = TUNE.s1.minGap,
			slackFrac = 0,
			thresholds = thresholdsFor(TUNE.s1),
			visible = function(): boolean
				return clearLineTo(field.stage1.near.Position) and clearLineTo(field.stage1.far.Position)
			end,
			solve = function(): (number?, number?, string?)
				local focus = orbit.focusPoint()
				return Align.solve(
					field.stage1.near.Position - focus,
					field.stage1.far.Position - focus,
					orbit.radius(),
					math.rad(opts.maxPitchDeg),
					math.rad(opts.minPitchDeg)
				)
			end,
			mechanism = connectorMechanism(Field.S1_NEAR, Field.S1_FAR),
			--[[ Lazily: stage 2's sockets are built at advance() time, when the first connector
			     has actually landed. The chaining contract never assumed the successor's anchors
			     already existed. ]]
			onSolved = function(): Chain.Puzzle?
				if not stage2Pair then
					local built = Field.pair(origin, Field.S2_NEAR, Field.S2_FAR, field.folder)
					stage2Pair = built
					addGlow(built.glow)
					emitterFor(built.near)
					for _, m in built.markers do
						table.insert(field.markers, m)
					end
					refreshSight()
				end
				return stage2
			end,
		}

		-- Where the shared lists stand before stage 2 adds to them, so a reset can trim back to
		-- exactly the stage-1 set instead of growing forever.
		local baseMarkerCount = #field.markers
		local baseEmitterCount = #emitters

		local chain = Chain.new(stage1)

		--------------------------------------------------------------------------------
		-- boot assertions
		--------------------------------------------------------------------------------
		do
			local spans = {
				{ name = "span-a", a = Field.S1_NEAR, b = Field.S1_FAR },
				{ name = "span-b", a = Field.S2_NEAR, b = Field.S2_FAR },
			}
			for _, span in spans do
				local slope = Field.slopeDeg(span.a, span.b)
				local baseline = (span.a - span.b).Magnitude
				print(("[demo3] %s: baseline %.1f studs, slope %.2f deg"):format(span.name, baseline, slope))
				if slope > TUNE.maxSlopeDeg then
					warn(`[demo3] {span.name} exceeds the authored slope limit: a connector is a bridge, not a ramp`)
				end
			end

			-- sepNorm must respond to viewpoint, and the antipode must be rejected by DEPTH ORDER
			-- rather than by the angle -- from there the two markers overlap perfectly.
			local nearW = (origin * CFrame.new(Field.S1_NEAR)).Position
			local farW = (origin * CFrame.new(Field.S1_FAR)).Position
			local centre = nearW:Lerp(farW, 0.5)
			local axis = (nearW - farW).Unit
			local onLine = nearW + axis * TUNE.s1.nominalDistance
			local anti = farW - axis * TUNE.s1.nominalDistance
			local good = Align.probe(onLine, (centre - onLine).Unit, nearW, farW, centre, TUNE.s1.radius, TUNE.s1.minGap, 0)
			local wrongDir = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(30)) * (onLine - centre)
			local off = centre + wrongDir
			local bad = Align.probe(off, (centre - off).Unit, nearW, farW, centre, TUNE.s1.radius, TUNE.s1.minGap, 0)
			local back = Align.probe(anti, (centre - anti).Unit, nearW, farW, centre, TUNE.s1.radius, TUNE.s1.minGap, 0)
			local t = stage1.thresholds
			print(
				("[demo3] self-check: on-line %.5f (enter %.4f) · 30 deg off %.3f (band %.3f) · antipode sep %.4f deg orderOk=%s"):format(
					good.sepNorm,
					t.enter,
					bad.sepNorm,
					t.band,
					back.sepDeg,
					tostring(back.orderOk)
				)
			)
			if good.sepNorm > t.enter then
				warn("[demo3] the authored solution never reaches the lock threshold")
			end
			if bad.sepNorm <= t.band then
				warn("[demo3] an off-axis viewpoint sits inside the feedback band")
			end
			if back.orderOk then
				warn("[demo3] the antipodal viewpoint is NOT rejected by depth order; minGap is too small")
			end
		end

		--------------------------------------------------------------------------------
		-- state
		--------------------------------------------------------------------------------
		type Phase = "Settling" | "Play" | "Committing" | "Revealing" | "Crossing" | "Done"
		local phase: Phase = "Settling"
		local settleFor = 0
		local holdFor = 0
		local armed = false
		local commitQueued = false
		local resetQueued = false
		local refusedFor = 0
		local awaitingArrival = false

		local snapping = false
		local snapT = 0
		local fromYaw, fromPitch = 0, 0
		local toYaw, toPitch = 0, 0

		local lastSafe = field.spawnCF

		local drag = Drag.new(cam, hud.gui, { touchHalf = true })
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

		ctx.onCharacter(function(fresh: Model)
			local freshRoot = fresh:FindFirstChild("HumanoidRootPart")
			if freshRoot and freshRoot:IsA("BasePart") then
				orbit.setSubject(freshRoot)
			end
			refreshCameraFilter()
			refreshSight()
			-- A respawn during a demo means the fall-catch failed; put them back on solid ground.
			Shell.placeCharacter(ctx.player, lastSafe)
		end)

		local function solveSnap(): (number?, number?, string?)
			local puzzle = chain.current()
			if not puzzle or not puzzle.solve then
				return nil, nil, "no live stage"
			end
			return puzzle.solve()
		end

		local function snapLanded(): boolean
			local puzzle = chain.current()
			if not puzzle then
				return false
			end
			local near, far = puzzle.anchors()
			local centre, radius = puzzle.sphere()
			local p = Align.probe(orbit.eye(), orbit.look(), near, far, centre, radius, puzzle.minGap, puzzle.slackFrac)
			-- The same predicate that armed the commit, occlusion included: otherwise a snap can
			-- land on a viewpoint the scorer would have rejected.
			local seen = if puzzle.visible then puzzle.visible() else true
			return p.valid and p.orderOk and seen and p.sepNorm <= puzzle.thresholds.arm
		end

		local function refuseCommit(why: string)
			warn(`[demo3] commit refused: {why}`)
			refusedFor = 1.4
			freezeCharacter(false)
			snapping = false
			phase = "Play"
			drag.setEnabled(true)
		end

		local function localPos(world: Vector3): Vector3
			return origin:PointToObjectSpace(world)
		end

		local function onDeck(p: Vector3, minX: number, maxX: number, minZ: number, maxZ: number): boolean
			return p.X >= minX and p.X <= maxX and p.Z >= minZ and p.Z <= maxZ and p.Y > -4 and p.Y < 8
		end

		local function resetDemo()
			phase = "Settling"
			settleFor = 0
			armed = false
			snapping = false
			refusedFor = 0
			awaitingArrival = false
			for _, c in connectors do
				c.destroy()
			end
			table.clear(connectors)
			if stage2Pair then
				-- The whole pair folder, not the handful of parts the handle names: the plinths
				-- were leaking, and the exclusion list was growing by one dead entry per reset.
				stage2Pair.destroy()
				stage2Pair = nil
			end
			for i = #field.markers, baseMarkerCount + 1, -1 do
				table.remove(field.markers, i)
			end
			for i = #emitters, baseEmitterCount + 1, -1 do
				table.remove(emitters, i)
			end
			refreshSight()
			table.clear(glowParts)
			addGlow(field.stage1.glow)
			chain.reset(stage1)
			drag.setEnabled(false)
			freezeCharacter(false)
			ctx.place(field.spawnCF)
			lastSafe = field.spawnCF
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

		local function afterConnector()
			freezeCharacter(false)
			drag.setEnabled(true)
			phase = "Crossing"
			if chain.current() == stage1 then
				awaitingArrival = true
				hud.setState("BRIDGE MADE")
				hud.setHint("walk across — the camera no longer matters")
			else
				hud.setState("BRIDGE MADE")
				hud.setHint("cross to the goal")
			end
		end

		local function beginReveal()
			phase = "Revealing"
			local animating = chain.beginMechanism()
			fx.fire("solved")
			hud.setState("CONNECTING")
			if not animating then
				afterConnector()
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

			-- 1. input
			local f = drag.consume()
			if phase ~= "Committing" and (f.dx ~= 0 or f.dy ~= 0) then
				orbit.turn(f.dx, f.dy)
			end

			-- 2. commit, accepted at the ARM threshold
			local wantsCommit = commitQueued or f.tapped
			commitQueued = false
			local grounded = true
			do
				local body0 = ctx.player.Character
				local hum0 = if body0 then body0:FindFirstChildOfClass("Humanoid") else nil
				grounded = hum0 == nil or hum0.FloorMaterial ~= Enum.Material.Air
			end
			if wantsCommit and phase == "Play" and chain.current() and armed and not grounded then
				-- Anchoring a character in mid-air holds it there for the whole reveal, and the
				-- solve was expressed against a focus that is still falling.
				refusedFor = 1.2
				hud.setState("LAND FIRST")
			elseif wantsCommit and phase == "Play" and chain.current() and armed then
				-- Freeze first, then converge the focus onto the frozen body: the focus chases the
				-- root with a time constant, so a commit taken while walking would be solved in a
				-- frame that keeps moving underneath the animation.
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

			-- 3. camera. The snap is re-solved every frame because Orbit's collision clamp changes
			--    the boom length as the direction sweeps: a target fixed at press time drifts off
			--    the anchor line during its own animation.
			if snapping then
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

			-- Verified against the pose that was actually rendered, after the clamp has had its
			-- say. The connector must never appear from a viewpoint that does not show the join.
			if phase == "Committing" and not snapping and holdFor <= 0 then
				if snapLanded() then
					holdFor = 0.0001
				else
					refuseCommit("the snapped viewpoint is blocked or clamped short")
				end
			end

			-- 4. mechanisms
			local newestDone = chain.pose(CFrame.new(), dt)
			if newestDone and phase == "Revealing" then
				afterConnector()
			end

			-- 5. falling is caught, never respawned: the drop here is 2,000 studs and a respawn
			--    would dump the player back in the shell's lobby mid-puzzle.
			local body = ctx.player.Character
			local bodyRoot = if body then body:FindFirstChild("HumanoidRootPart") else nil
			if bodyRoot and bodyRoot:IsA("BasePart") then
				local p = localPos(bodyRoot.Position)
				if p.Y < TUNE.fallY then
					Shell.placeCharacter(ctx.player, lastSafe)
				else
					local humanoid = body and body:FindFirstChildOfClass("Humanoid")
					-- Bounded to the field, not just to Y. During a respawn window the character is
					-- standing in the SHELL'S LOBBY 9,000 studs away, grounded and above -2 -- and
					-- latching that would make the fall-catch teleport the player out of the demo.
					local insideField = math.abs(p.X) < 80 and p.Z > -90 and p.Z < 40
					if humanoid and humanoid.FloorMaterial ~= Enum.Material.Air and p.Y > -2 and insideField then
						lastSafe = CFrame.new(bodyRoot.Position)
					end
				end

				-- arriving on platform B exposes the second pair
				if awaitingArrival and onDeck(p, -9, 9, -66, -50) then
					awaitingArrival = false
					local nextPuzzle, why = chain.advance()
					-- ADVISORY, never terminal. advance() probes solve() once, from wherever the
					-- player happens to be standing at the instant they cross onto the deck -- with
					-- a boom length Orbit may have clamped against the connector they just walked.
					-- Treating that single sample as "this stage is impossible" bricked the demo on
					-- a coin flip. The per-frame commit path already re-solves every frame and
					-- refuses gracefully with a reason.
					if why then
						warn(`[demo3] stage "{nextPuzzle and nextPuzzle.name or "?"}" did not solve at the arrival pose (advisory): {why}`)
					end
					phase = "Play"
					hud.setState("")
					hud.setHint("a second pair is exposed — line them up")
				elseif phase == "Crossing" and not awaitingArrival and chain.current() == stage2 and onDeck(p, 44, 60, -66, -50) then
					phase = "Done"
					hud.setState("GOAL")
					hud.setHint("both spans are real geometry · R to reset · Q or EXIT to leave")
				end
			end

			-- 6. score
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
				-- Say WHY when the score is rejected. Standing at the antipode shows a perfect
				-- overlap and a dead meter, and without this there is nothing on screen to explain
				-- it -- the worst possible first-time experience.
				if refusedFor > 0 then
					refusedFor -= dt
					hud.setState("MOVE CLOSER")
				elseif score.eyeInside then
					hud.setState("STEP BACK")
				elseif not score.inFront then
					hud.setState("TURN AROUND")
				elseif not score.orderOk then
					hud.setState("WRONG SIDE")
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
			elseif phase == "Crossing" or phase == "Done" then
				armed = false
				prox = chain.relax(dt)
				hud.setProgress(prox, false, false)
			else
				armed = false
				prox = chain.hold(dt)
				hud.setProgress(1, false, true)
			end

			fx.render(prox, dt)

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
		hud.fade(1, 0.45)
	end)
end

return Demo3
