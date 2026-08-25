--!strict
--[[
	DEMO 3 — DWELL TO WEAVE

	Your own Roblox character, walking a Monument Valley-ish building with normal Humanoid
	movement. Two surfaces that COINCIDE ON SCREEN are connected -- but only once the camera
	settles. While you are turning, the world is inert. Stop for a beat and the coincidences
	crystallise: the seams light, and walking into one continues you onto the surface that looked
	joined, which is somewhere else entirely in world space.

	There is no commit button and no authored anchor pair to line up. The whole building's
	connectivity is a function of the camera angle, which is what separates this from demo 2:
	there, alignment unlocks one authored thing; here, alignment IS the level's topology.

	WHY NOT FOV 70. When the character crosses a seam it jumps 20 studs in depth. Under a close
	perspective camera that would visibly pop its size, and so would every other relationship in
	frame. H = 2*D*tan(FOV/2), so FOV 6 at 400 studs frames a ~42-stud-tall view: a 20.8-stud
	depth jump then changes apparent size by 5.2%, which on a 60px character is about 3px -- gone
	in a single frame. It is a deliberate middle ground between demo 1's FOV 1 at 372 studs and a
	normal game camera, and 400 studs is comfortably inside safe render distance.

	WHY THE CAMERA FRAMES THE BUILDING, NOT THE CHARACTER. If it followed the avatar it would be
	dragged 20 studs along the view ray on every crossing and the whole scene would appear to
	lurch. Framing the building means only the character changes depth, by its own small amount.

	CONTROLS  walk with WASD · drag to orbit · hold still to weave · R reset · Q or EXIT to leave
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Align = require(ReplicatedStorage.Shared.Align)
local Damp = require(ReplicatedStorage.Shared.Damp)
local Orbit = require(ReplicatedStorage.Shared.Orbit)
local Seam = require(ReplicatedStorage.Shared.Seam)
local Session = require(ReplicatedStorage.Shared.Session)
local Shell = require(ReplicatedStorage.Shared.Shell)

local Drag = require(script.Parent.Drag)
local Feedback = require(script.Parent.Feedback)
local Hud = require(script.Parent.Hud)
local Building = require(script.Building)

local TUNE = {
	fovDeg = 6,
	-- A starting point only: the real distance is FITTED to the building and the viewport at
	-- boot, and refitted when the window changes shape. A hard-coded standoff crops the building
	-- on a narrow window and wastes frame on a wide one.
	distance = 400,
	frameMargin = 1.15,
	framePad = 2.0,
	-- The seams are authored to coincide at the isometric pitch, so the clamp has to contain it
	-- with room either side for the player to hunt.
	minPitchDeg = 5,
	maxPitchDeg = 62,
	startYawDeg = 20,
	startPitchDeg = 30,

	--[[ Screen-space slack, in studs of the parallel projection. At D = 400 the visible frame is
	     ~42 studs tall, so 0.9 studs is about 2% of frame height -- roughly 23 px at 1080p. Wide
	     enough that a settle within ~3 degrees of the exact angle takes, narrow enough that the
	     player is genuinely hunting for the angle. ]]
	epsilon = 0.9,

	-- Dwell: below this angular speed for this long and the world crystallises.
	settleSpeedDeg = 6,
	dwellTime = 0.45,
	-- Once settled, this much total angular drift breaks it. Displacement rather than speed: a
	-- slow steady drag never trips a speed threshold but does slide the seams apart.
	settleDriftDeg = 1.2,

	fallY = -30,
	walkSpeed = 16,
}

local Demo3 = {}

Demo3.id = "weave"
Demo3.title = "DEMO 3 — DWELL TO WEAVE"
Demo3.blurb = "Hold the camera still and coincident surfaces become connected. Then walk across."
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

		-- Flat-shaded: shadows are weak at 400 studs, so the look leans on raised ambient and
		-- painted-on face colours instead of pretending otherwise.
		s.add(ctx.dim({ depthOfField = true }))

		local building = Building.build(origin, workspace)
		s.add(building.destroy)
		ctx.place(building.spawnCF)

		--------------------------------------------------------------------------------
		-- the seam graph
		--------------------------------------------------------------------------------
		local nodes: { Seam.Node } = {}
		local indexById: { [string]: number } = {}
		for _, spec in Building.NODES do
			local attachment = building.attachments[spec.id]
			table.insert(nodes, {
				id = spec.id,
				point = attachment,
				surface = spec.surface,
			})
			indexById[spec.id] = #nodes
		end

		local seamOptions = Seam.defaults()
		seamOptions.epsilon = TUNE.epsilon
		seamOptions.occluders = { building.occluders }

		-- Authoring assertion: a pair whose orientations do not match cannot be crossed by a pure
		-- translation, and would silently mangle the player's velocity.
		for _, pair in Building.INTENDED do
			local a, b = nodes[indexById[pair[1]]], nodes[indexById[pair[2]]]
			local fault = Seam.orientationFault(a, b)
			if fault then
				error(`demo 3: intended seam {pair[1]}-{pair[2]} is not crossable: {fault}`, 0)
			end
		end

		local traverser = Seam.newTraverser(nodes, Seam.traverserDefaults())

		--------------------------------------------------------------------------------
		-- camera: fixed focus on the BUILDING, free yaw
		--------------------------------------------------------------------------------
		local opts = Orbit.defaults()
		opts.distance = TUNE.distance
		opts.fovDeg = TUNE.fovDeg
		opts.minPitchDeg = TUNE.minPitchDeg
		opts.maxPitchDeg = TUNE.maxPitchDeg
		opts.followTau = 0 -- nothing to follow; the focus is pinned

		-- nil subject: Orbit.step only chases `live` when it is non-nil, so this is a fixed-focus
		-- free-yaw orbit.
		--[[
			Fit the standoff to the building and the viewport rather than hard-coding it. Note this
			cannot disturb the seams: a coincidence under a parallel projection depends on the view
			DIRECTION alone, so moving the camera along that direction changes nothing about which
			surfaces connect -- only how much of the frame the building fills.
		]]
		local focusWorld = (origin * CFrame.new(building.centre)).Position
		local function fitDistance(): number
			local halfV = math.tan(math.rad(TUNE.fovDeg) * 0.5)
			local vp = cam.ViewportSize
			local aspect = if vp.Y > 0 then vp.X / vp.Y else 1
			local lo, hi = building.boundsMin, building.boundsMax
			local corners: { Vector3 } = {}
			for _, x in { lo.X, hi.X } do
				for _, y in { lo.Y, hi.Y } do
					for _, z in { lo.Z, hi.Z } do
						table.insert(corners, (origin * CFrame.new(x, y, z)).Position)
					end
				end
			end
			local widest, tallest = 0, 0
			for step = 0, 7 do
				local dir = Align.fromSpherical(math.rad(step * 45), math.rad(35.264), 1)
				local probe = CFrame.lookAt(focusWorld + dir * 100, focusWorld)
				local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
				for _, corner in corners do
					local screen = (Seam.project(corner, probe))
					minX, maxX = math.min(minX, screen.X), math.max(maxX, screen.X)
					minY, maxY = math.min(minY, screen.Y), math.max(maxY, screen.Y)
				end
				widest = math.max(widest, (maxX - minX) + 2 * TUNE.framePad)
				tallest = math.max(tallest, (maxY - minY) + 2 * TUNE.framePad)
			end
			local needV = tallest * 0.5 / halfV
			local needH = widest * 0.5 / (halfV * aspect)
			return TUNE.frameMargin * math.max(needV, needH)
		end
		opts.distance = fitDistance()

		local orbit = Orbit.new(cam, nil, opts)
		s.add(orbit.restore)
		-- Orbit reads opts.distance every frame, so refitting is a single assignment.
		local viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			opts.distance = fitDistance()
		end)
		s.track(viewportConn)
		orbit.setFocus((origin * CFrame.new(building.centre)).Position)
		orbit.set(math.rad(TUNE.startYawDeg), math.rad(TUNE.startPitchDeg))
		--[[
			MANDATORY at this distance. The boom ray runs 400 studs outward from a focus INSIDE the
			building, so it hits the building immediately and the boom collapses to its minimum --
			the demo would render from inside a wall. The avatar is excluded for the same reason:
			it stands on that geometry, so it too sits on the outgoing ray.
		]]
		local function refreshCameraFilter()
			local body = ctx.player.Character
			orbit.setFilter(if body then { building.folder, body } else { building.folder })
		end
		refreshCameraFilter()

		--------------------------------------------------------------------------------
		-- character
		--------------------------------------------------------------------------------
		--[[
			LEASED, not written and forgotten. Zeroing the jump and never restoring it would leave
			the player unable to jump for the rest of the session, in every other demo and in the
			lobby -- and the shell has disabled the reset button, so there is no way to shake it
			off.
		]]
		local releaseCharacter: (() -> ())? = nil
		local function prepareCharacter()
			if releaseCharacter then
				releaseCharacter()
				releaseCharacter = nil
			end
			local character = ctx.player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if not humanoid then
				return
			end
			local walk, power, height = humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight
			-- No jump: Monument Valley has none, and it removes every mid-air seam case.
			humanoid.JumpPower = 0
			humanoid.JumpHeight = 0
			humanoid.WalkSpeed = TUNE.walkSpeed
			releaseCharacter = function()
				if humanoid.Parent then
					humanoid.WalkSpeed = walk
					humanoid.JumpPower = power
					humanoid.JumpHeight = height
				end
			end
		end
		prepareCharacter()
		s.add(function()
			if releaseCharacter then
				releaseCharacter()
				releaseCharacter = nil
			end
		end)

		local lastSafe = building.spawnCF
		ctx.onCharacter(function()
			prepareCharacter()
			refreshCameraFilter()
			Shell.placeCharacter(ctx.player, lastSafe)
		end)

		--------------------------------------------------------------------------------
		-- feedback: the settle is the money moment
		--------------------------------------------------------------------------------
		local fx = Feedback.new()
		s.add(fx.destroy)

		--[[
			PER-NODE, not per-building. Lighting every bar on every settle tells the player that
			four seams are live when at most one is -- and lights them just as brightly at an angle
			where nothing coincides at all, which teaches exactly the wrong rule.

			Feedback.glow is not used here for that reason, and Feedback.halo is absent because its
			rest poses are world-fixed and slide off screen the moment the camera orbits.
		]]
		local liveBars: { [BasePart]: boolean } = {}
		local flashFor = 0
		fx.add(function(p: number, dt: number)
			flashFor = math.max(flashFor - dt, 0)
			local flash = flashFor / 0.3
			for _, bar in building.glow do
				if liveBars[bar] then
					local lit = Building.COLD:Lerp(Building.HOT, p)
					bar.Color = if flash > 0 then lit:Lerp(Color3.new(1, 1, 1), flash) else lit
				else
					bar.Color = Building.COLD
				end
			end
		end)

		--------------------------------------------------------------------------------
		-- state
		--------------------------------------------------------------------------------
		local settled = false
		local stillFor = 0
		local prevYaw, prevPitch = orbit.get()
		local settleYaw, settlePitch = 0, 0
		local prox = 0
		local resetQueued = false
		local liveEdges = 0
		local solved = false

		local drag = Drag.new(cam, hud.gui, { touchHalf = true })
		s.add(drag.destroy)

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

		local function unsettle()
			if not settled then
				return
			end
			settled = false
			liveEdges = 0
			table.clear(liveBars)
			traverser.setGraph(nil, nil)
			if not solved then
				hud.setState("")
				hud.setHint("hold the camera still to weave")
			end
		end

		local function settle()
			settled = true
			stillFor = 0
			settleYaw, settlePitch = orbit.get()
			local graph = Seam.build(nodes, cam:GetRenderCFrame(), seamOptions)
			-- Handing the character in disarms any node whose mouth already contains it, which is
			-- the fix for the case that would otherwise read as a bug: settling while standing ON
			-- a seam that goes live. It is per-node and self-releasing, so unlike a blanket timer
			-- it never eats a crossing the player is legitimately walking into.
			traverser.setGraph(graph, ctx.player.Character)
			table.clear(liveBars)
			for _, edge in graph.edges do
				local barA = building.markers[nodes[edge.a].id]
				local barB = building.markers[nodes[edge.b].id]
				if barA then
					liveBars[barA] = true
				end
				if barB then
					liveBars[barB] = true
				end
			end
			liveEdges = #graph.edges
			flashFor = 0.3
			if solved then
				return -- do not talk over the ending
			end
			if liveEdges > 0 then
				local names = {}
				for _, edge in graph.edges do
					table.insert(names, `{nodes[edge.a].id}~{nodes[edge.b].id}`)
				end
				hud.setState(`WOVEN — {table.concat(names, ", ")}`)
				hud.setHint("walk into a lit seam")
			else
				hud.setState("SETTLED — nothing coincides from here")
				hud.setHint("try another angle")
			end
		end

		local function resetDemo()
			unsettle()
			solved = false
			ctx.place(building.spawnCF)
			lastSafe = building.spawnCF
			orbit.set(math.rad(TUNE.startYawDeg), math.rad(TUNE.startPitchDeg))
			prevYaw, prevPitch = orbit.get()
			stillFor = 0
		end

		local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.R then
				resetQueued = true
			elseif input.KeyCode == Enum.KeyCode.Q then
				doExit()
			end
		end)
		s.track(inputConn)

		--------------------------------------------------------------------------------
		-- boot report
		--------------------------------------------------------------------------------
		do
			local half = TUNE.distance * math.tan(math.rad(TUNE.fovDeg) * 0.5)
			print(
				("[demo3] FOV %d at %d studs -> %.1f studs of visible height, %.1f px per stud at 1080p"):format(
					TUNE.fovDeg,
					TUNE.distance,
					half * 2,
					(1080 / 2) / half
				)
			)
			local found = 0
			for _, pair in Building.INTENDED do
				local a, b = nodes[indexById[pair[1]]], nodes[indexById[pair[2]]]
				local offset = b.point.WorldPosition - a.point.WorldPosition
				found += 1
				print(
					("[demo3] seam %s~%s: offset (%.0f, %.0f, %.0f), %.1f studs of depth to jump"):format(
						pair[1],
						pair[2],
						offset.X,
						offset.Y,
						offset.Z,
						offset.Magnitude
					)
				)
			end
			print(`[demo3] {#nodes} nodes, {found} intended seams, all orientation-checked`)
			print(("[demo3] fitted standoff %.0f studs"):format(opts.distance))

			--[[
				The level's whole claim, asserted in-engine rather than only in my notes: sweep the
				yaw at the isometric pitch and confirm that no SINGLE settle reaches the goal
				surface, and that at least two different angles produce seams. If either fails the
				camera is decorative and the demo is a diorama.
			]]
			local anglesWithSeams = 0
			local soloSolve: number? = nil
			for step = 0, 71 do
				local yaw = math.rad(step * 5)
				local dir = Align.fromSpherical(yaw, math.rad(35.264), 1)
				local probe = CFrame.lookAt(focusWorld + dir * opts.distance, focusWorld)
				local graph = Seam.build(nodes, probe, seamOptions)
				if #graph.edges > 0 then
					anglesWithSeams += 1
					local reach = Seam.reachableSurfaces(nodes, Building.REAL_EDGES, graph, Building.START_SURFACE)
					if reach[Building.GOAL_SURFACE] and not soloSolve then
						soloSolve = step * 5
					end
				end
			end
			print(`[demo3] swept 72 angles: {anglesWithSeams} produce a seam`)
			if soloSolve then
				warn(`[demo3] yaw {soloSolve} reaches the goal in ONE settle -- the camera is decorative`)
			else
				print("[demo3] no single settle reaches the goal: the route needs more than one angle")
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
				resetDemo()
			end

			local f = drag.consume()
			if f.dx ~= 0 or f.dy ~= 0 then
				orbit.turn(f.dx, f.dy)
			end
			orbit.step(dt)

			-- 1. dwell. Angular speed of the actual camera state, not of the input: inertia in
			--    the rig means the camera keeps moving after the drag stops, and connecting the
			--    world while it drifts would light seams that are already sliding apart.
			local yaw, pitch = orbit.get()
			local speed = (math.abs(Damp.shortestArc(prevYaw, yaw)) + math.abs(pitch - prevPitch)) / math.max(dt, 1e-4)
			prevYaw, prevPitch = yaw, pitch

			--[[
				Settling is a SPEED test; staying settled is a DISPLACEMENT test. Speed alone has
				two failure modes: a slow steady drag stays under the threshold forever, so dead
				seams remain lit and crossable while they visibly slide apart on screen; and a
				single-frame twitch over the threshold throws away a settle that then costs 0.45 s
				to earn back. Measuring how far the camera has moved SINCE the settle fixes both,
				and gives the hysteresis for free.
			]]
			if settled then
				local drift = math.abs(Damp.shortestArc(settleYaw, yaw)) + math.abs(pitch - settlePitch)
				if math.deg(drift) > TUNE.settleDriftDeg then
					stillFor = 0
					unsettle()
				end
			elseif math.deg(speed) > TUNE.settleSpeedDeg then
				stillFor = 0
			else
				stillFor += dt
				if stillFor >= TUNE.dwellTime then
					settle()
				end
			end

			-- 2. the settling indicator. Without it a player who never discovers that holding
			--    still matters concludes the demo is broken.
			local target = if settled then 1 else math.clamp(stillFor / TUNE.dwellTime, 0, 1)
			prox = Damp.damp(prox, target, dt, 0.06)
			hud.setProgress(prox, settled and liveEdges > 0, settled and liveEdges > 0)
			fx.render(if settled then prox else prox * 0.35, dt)

			-- 3. traversal and the fall catch
			local character = ctx.player.Character
			if character then
				local crossed = traverser.step(dt, character)
				if crossed then
					hud.setState(("CROSSED — %.0f studs of depth, invisibly"):format(crossed.depthDelta))
				end

				local root = character:FindFirstChild("HumanoidRootPart")
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if root and root:IsA("BasePart") then
					local localPos = origin:PointToObjectSpace(root.Position)

					-- Arriving is worth acknowledging: without it the route just ends.
					if not solved and math.abs(localPos.X - 17) < 2.5 and math.abs(localPos.Z - 6) < 2.5 and localPos.Y > 2 then
						solved = true
						flashFor = 0.3
						hud.setState("SOLVED — two angles, one route")
						hud.setHint("R to reset · Q or EXIT to leave")
					end
					if localPos.Y < TUNE.fallY then
						-- Caught, never respawned: the drop here ends 2,000 studs down and would
						-- put the player back in the shell's lobby mid-puzzle.
						Shell.placeCharacter(ctx.player, lastSafe)
					elseif not crossed and humanoid and humanoid.FloorMaterial ~= Enum.Material.Air then
						-- Bounded to the building, not just grounded. During a respawn window the
						-- character is standing in the shell's LOBBY 9,000 studs away, grounded and
						-- above the fall line -- latching that would make the catch volume
						-- teleport the player out of the demo.
						local inside = math.abs(localPos.X) < 60
							and math.abs(localPos.Z) < 60
							and localPos.Y > -10
							and localPos.Y < 40
						if inside then
							-- The whole pivot, not just the position: rebuilding from the position
							-- alone snaps the player to world -Z on every catch.
							lastSafe = character:GetPivot()
						end
					end
				end
			end
		end)
		s.add(function()
			RunService:UnbindFromRenderStep(bind)
		end)

		hud.setHint("hold the camera still to weave")
		hud.fade(1, 0.45)
	end)
end

return Demo3
