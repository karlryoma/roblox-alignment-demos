--!strict
--[[
	DEMO 4 — MONUMENT VALLEY-STRICT TRAVERSAL (the capstone)

	Demos 1-3 all measure the ANGLE SUBTENDED AT THE EYE -- a perspective quantity -- and commit
	on alignment. This one does neither. It is a baked screen-space connectivity graph under an
	orthographic projection, traversed by a puppet, and it deliberately shares almost nothing
	with the rest of the repo: no Chain, no Orbit, no Align.probe. Contorting those to fit would
	have produced a worse version of both.

	THE ARCHITECTURAL INSIGHT, which is the whole demo: the camera snaps to four fixed angles and
	the sub-model to four positions, so there are only sixteen connectivity graphs. Bake them
	all. Rendering then uses the FOV-1 near-orthographic approximation and only has to fool the
	eye, while gameplay logic uses a mathematically EXACT orthographic projection computed in
	Graph.project. The illusion being approximate never leaks into correctness.

	WHY FOV 1 AND ~2,400 STUDS. Roblox has no orthographic camera and FieldOfView is clamped to
	[1, 120], so the standard approximation is FOV 1 with a distant camera: view height
	H = 2 * D * tan(FOV/2), which at FOV 1 gives D ~= 57.3 * H. The level plus its support columns
	is authored to about a 39-stud on-screen height, so D lands near 2,400. The exact figure is
	computed by fitDistance and printed at boot rather than restated in prose here. Bigger costs
	linearly and buys nothing.

	HONEST LIMITATION: on low graphics settings the engine may cull a level ~2,400 studs away
	entirely, and a script CANNOT force quality -- settings() is plugin-security and throws in a
	live game. The HUD says so. For a demo that gets filmed on max settings this is acceptable,
	but it is a real caveat rather than a hidden one.

	CONTROLS  arrow keys rotate the view · F turns the bridge · click a tile to walk there ·
	          R resets · Q or EXIT leaves
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Align = require(ReplicatedStorage.Shared.Align)
local Damp = require(ReplicatedStorage.Shared.Damp)
local Session = require(ReplicatedStorage.Shared.Session)
local Shell = require(ReplicatedStorage.Shared.Shell)

local Hud = require(script.Parent.Hud)
local Graph = require(script.Graph)
local Level = require(script.Level)

local TUNE = {
	fovDeg = 1,
	elevationDeg = 35.264, -- true isometric: atan(1/sqrt(2)). Makes the (1,1,1) joins exact.
	yawDeg = { 45, 135, 225, 315 },
	frameMargin = 1.12, -- the level fills 1/1.12 of the binding axis
	framePad = 1.5, -- a little air around the measured geometry bounds

	--[[ Studs of screen-space separation that still counts as coincident. The bake is an EXACT
	     orthographic projection -- the FOV-1 perspective residual never enters it -- so this only
	     has to absorb floating-point error, not viewing error. At 0.9 it was admitting four
	     coincidences the level never authored, ~0.82 studs apart (about 27 px on screen), which
	     is a visible gap the player would be asked to believe in. ]]
	epsilon = 0.08,
	visibilityRayLength = 400,
	visibilityBackoff = 0.6, -- stop the ray short so a node's own tile is not "in front of" it

	cameraTurnTime = 0.65, -- the rotation IS the mechanic: slow enough to read
	rotorTurnTime = 0.5,
	walkSpeed = 9, -- studs per second along a real edge
	snapPause = 0.12, -- a beat either side of a virtual-edge snap, so the jump reads
	clickRadiusPx = 70,

	characterOffset = Vector3.new(300, 0, 0), -- far outside a ~30-stud frame
}

local Demo4 = {}

Demo4.id = "monument"
Demo4.title = "DEMO 4 — MONUMENT VALLEY TRAVERSAL"
Demo4.blurb = "Baked screen-space connectivity. Rotate the world; impossible joins become real."
Demo4.ready = true
Demo4.region = CFrame.new(0, 12000, 0)

local session: Session.Handle? = nil

function Demo4.stop()
	local live = session
	if live then
		live.stop()
	end
	session = nil
end

function Demo4.start(ctx: Shell.Context): boolean
	local live = Session.new("demo4")
	session = live

	return live.start(function(s: Session.Handle)
		local cam = ctx.camera
		local origin = Demo4.region

		local hud = Hud.new(ctx.playerGui, Demo4.title)
		s.add(hud.destroy)
		hud.fade(0, 0)
		hud.setProgress(0, false, false)

		-- Flat-shaded by intent: at this distance shadows are dead anyway, so the look leans on
		-- raised ambient and hand-picked face colours.
		s.add(ctx.dim({ depthOfField = true, atmosphere = true, fog = true }))

		local level = Level.build(origin, workspace)
		s.add(level.destroy)

		--[[
			The avatar is not the traversal: freeze it and park it far outside the frame.

			LEASED, not fire-and-forget. A respawn hands back a fresh, unfrozen character, so the
			hook below has to take a NEW hold -- and dropping that undo would leave the player
			anchored with WalkSpeed 0 back in the menu with no way out, because the shell has
			disabled the reset button globally.
		]]
		local unfreeze: (() -> ())? = nil
		local function holdAvatar()
			if unfreeze then
				unfreeze()
				unfreeze = nil
			end
			unfreeze = Shell.holdCharacter(ctx.player)
		end
		holdAvatar()
		s.add(function()
			if unfreeze then
				unfreeze()
				unfreeze = nil
			end
		end)
		ctx.place(origin * CFrame.new(TUNE.characterOffset))

		--------------------------------------------------------------------------------
		-- camera states
		--------------------------------------------------------------------------------
		local targetWorld = (origin * CFrame.new(level.centre)).Position

		local function directionFor(stateIndex: number): Vector3
			return Align.fromSpherical(math.rad(TUNE.yawDeg[stateIndex]), math.rad(TUNE.elevationDeg), 1)
		end

		--[[ Fit the whole diorama in every state, against whichever viewport axis binds. ]]
		local function fitDistance(): number
			local halfV = math.tan(math.rad(TUNE.fovDeg) * 0.5)
			local vp = cam.ViewportSize
			local aspect = if vp.Y > 0 then vp.X / vp.Y else 1
			-- The eight corners of the ACTUAL geometry, not the node points: the columns hang below
			-- the tiles they carry, and fitting to nodes alone slices them off the bottom.
			local lo, hi = level.boundsMin, level.boundsMax
			local corners: { Vector3 } = {}
			for _, x in { lo.X, hi.X } do
				for _, y in { lo.Y, hi.Y } do
					for _, z in { lo.Z, hi.Z } do
						table.insert(corners, (origin * CFrame.new(x, y, z)).Position)
					end
				end
			end

			local widest, tallest = 0, 0
			for stateIndex = 1, 4 do
				local probe = CFrame.lookAt(targetWorld + directionFor(stateIndex) * 100, targetWorld)
				local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
				for _, corner in corners do
					local screen = (Graph.project(corner, probe))
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

		local snapshot = {
			cameraType = cam.CameraType,
			cframe = cam.CFrame,
			focus = cam.Focus,
			fov = cam.FieldOfView,
			fovMode = cam.FieldOfViewMode,
		}
		local restored = false
		s.add(function()
			if restored then
				return
			end
			restored = true
			-- CameraType LAST: restoring it first hands control back to the default scripts,
			-- which then fight every property written after it.
			cam.FieldOfViewMode = snapshot.fovMode
			cam.FieldOfView = snapshot.fov
			cam.CFrame = snapshot.cframe
			cam.Focus = snapshot.focus
			cam.CameraType = snapshot.cameraType
		end)

		cam.CameraType = Enum.CameraType.Scriptable
		cam.CameraSubject = nil
		cam.FieldOfViewMode = Enum.FieldOfViewMode.Vertical
		cam.FieldOfView = TUNE.fovDeg
		local distance = fitDistance()

		local function cframeForYaw(yawRad: number): CFrame
			local dir = Align.fromSpherical(yawRad, math.rad(TUNE.elevationDeg), 1)
			return CFrame.lookAt(targetWorld + dir * distance, targetWorld)
		end

		local function cframeFor(stateIndex: number): CFrame
			return cframeForYaw(math.rad(TUNE.yawDeg[stateIndex]))
		end

		-- Only the distance needs recomputing here: the pose is rewritten every frame from it.
		local viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			distance = fitDistance()
		end)
		s.track(viewportConn)

		--------------------------------------------------------------------------------
		-- the bake
		--------------------------------------------------------------------------------
		local visibilityParams = RaycastParams.new()
		--[[
			ONLY BULK GEOMETRY OCCLUDES. The tiles and the rotor carry the nodes themselves, and
			any coincident pair necessarily has one tile in front of the other -- testing against
			them would reject every join by construction, including the ones the level is built
			around. So the test asks the question that actually matters in Monument Valley: is
			this join hidden behind the ARCHITECTURE? The monolith proves it is not a no-op.
		]]
		visibilityParams.FilterType = Enum.RaycastFilterType.Include
		visibilityParams.FilterDescendantsInstances = { level.occluders }
		visibilityParams.RespectCanCollide = false
		visibilityParams.IgnoreWater = true

		local function worldPositions(turns: number): { Vector3 }
			local out: { Vector3 } = {}
			for _, p in Level.positions(turns) do
				table.insert(out, (origin * CFrame.new(p)).Position)
			end
			return out
		end

		local function visibilityFor(dir: Vector3, positions: { Vector3 }): (index: number) -> boolean
			return function(index: number): boolean
				local target = positions[index]
				local from = target + dir * TUNE.visibilityRayLength
				local span = TUNE.visibilityRayLength - TUNE.visibilityBackoff
				return workspace:Raycast(from, -dir * span, visibilityParams) == nil
			end
		end

		local graphs: { [number]: Graph.Baked } = {}
		local function graphKey(camState: number, rotorState: number): number
			return camState * 4 + rotorState
		end

		local function bakeAll()
			for rotorState = 0, 3 do
				-- The rotor is NOT moved for the bake. Node positions come from Level.positions,
				-- not from the instance, and the rotor carries nodes so it is not in the occluder
				-- filter -- moving it would change nothing the raycasts can see.
				local positions = worldPositions(rotorState)
				local realEdges = Level.realEdges(rotorState)
				for camState = 0, 3 do
					local dir = directionFor(camState + 1)
					graphs[graphKey(camState, rotorState)] =
						Graph.bake(positions, realEdges, cframeFor(camState + 1), TUNE.epsilon, visibilityFor(dir, positions))
				end
			end
		end

		--------------------------------------------------------------------------------
		-- state
		--------------------------------------------------------------------------------
		local camState = 1 -- 0-based index into yawDeg; starts on the state that opens the first join
		--[[ Starts UNDOCKED. With the bridge already spanning the gap, turning it could only ever
		     destroy the route, so the sub-model would be a way to lose rather than a move to make.
		     Starting across the gap means pressing F is a step of the solution. ]]
		local rotorState = 1
		local nodeIndex = Level.START_INDEX
		local path: { number } = {}
		local pathAt = 0
		local walkT = 0
		local pauseFor = 0
		local busy = false -- a tween is running, or the puppet is mid-edge
		local turning = 0 -- seconds remaining in a rotation
		local turnFrom, turnTo = 0, 0
		local yawNow = 0 -- the pose actually written this frame
		local rotorFrom, rotorTo = 0, 0
		local turningRotor = false

		level.setRotor(rotorState)

		local function activeGraph(): Graph.Baked
			return graphs[graphKey(camState, rotorState)]
		end

		--------------------------------------------------------------------------------
		-- the puppet: an anchored model, CFramed along edges. No Humanoid, no physics.
		--------------------------------------------------------------------------------
		local puppet = Instance.new("Model")
		puppet.Name = "Puppet"
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Size = Vector3.new(1.1, 1.8, 1.1)
		body.Color = Color3.fromRGB(250, 250, 252)
		body.Material = Enum.Material.SmoothPlastic
		body.Anchored = true
		body.CanCollide = false
		body.CanTouch = false
		body.CanQuery = false
		body.CastShadow = false
		body.Parent = puppet
		puppet.PrimaryPart = body
		local hat = Instance.new("Part")
		hat.Name = "Hat"
		hat.Shape = Enum.PartType.Ball
		hat.Size = Vector3.new(1.0, 1.0, 1.0)
		hat.Color = Color3.fromRGB(226, 92, 106)
		hat.Material = Enum.Material.SmoothPlastic
		hat.Anchored = true
		hat.CanCollide = false
		hat.CanTouch = false
		hat.CanQuery = false
		hat.CastShadow = false
		hat.Parent = puppet
		puppet.Parent = level.folder

		local function nodeWorld(index: number, turns: number): Vector3
			return (origin * CFrame.new(Level.positions(turns)[index])).Position
		end

		local function placePuppet(at: Vector3)
			body.CFrame = CFrame.new(at + Vector3.new(0, 0.9, 0))
			hat.CFrame = CFrame.new(at + Vector3.new(0, 2.2, 0))
		end
		placePuppet(nodeWorld(nodeIndex, rotorState))

		--------------------------------------------------------------------------------
		-- boot report
		--------------------------------------------------------------------------------
		bakeAll()
		level.setRotor(rotorState)

		do
			local nodeCount = #Level.NODES + 3
			print(`[demo4] baked {nodeCount} nodes, camera distance {math.floor(distance)} studs at FOV {TUNE.fovDeg}`)
			local solvedSolo: { string } = {}
			for c = 0, 3 do
				local line = {}
				for r = 0, 3 do
					local g = graphs[graphKey(c, r)]
					local reach = Graph.reachable(g.adj, Level.START_INDEX)
					if reach[Level.GOAL_INDEX] then
						table.insert(solvedSolo, `cam{c}/rotor{r}`)
					end
					local reachCount = 0
					for _ in reach do
						reachCount += 1
					end
					table.insert(line, `r{r}: {g.realCount}real {g.virtualCount}virt {reachCount}reach`)
				end
				print(`[demo4] cam{c} ({TUNE.yawDeg[c + 1]} deg) · {table.concat(line, " | ")}`)
			end
			local hidden = 0
			for _, g in graphs do
				hidden += g.hiddenCount
			end
			print(`[demo4] coincidences rejected as hidden behind architecture: {hidden}`)
			if #solvedSolo > 0 then
				warn(`[demo4] the goal is reachable without rotating: {table.concat(solvedSolo, ", ")} — rotation is decorative`)
			else
				print("[demo4] no single state reaches the goal: rotation is required")
			end
		end

		--------------------------------------------------------------------------------
		-- input
		--------------------------------------------------------------------------------
		local exiting = false
		local function doExit()
			if exiting then
				return
			end
			exiting = true
			hud.fade(0, 0.25)
			task.delay(0.25, ctx.exit)
		end
		hud.exitButton.Activated:Connect(doExit)

		local function setHint()
			hud.setHint("← → rotate view · F turns the bridge · click a tile · R reset · Q leave · wants high graphics")
		end
		setHint()

		local function refuse(message: string)
			hud.setState(message)
		end

		local function startTurn(delta: number)
			if busy then
				refuse("hold — finish moving first")
				return
			end
			turnFrom = math.rad(TUNE.yawDeg[camState + 1])
			camState = (camState + delta) % 4
			turnTo = turnFrom + math.rad(90 * delta)
			turning = TUNE.cameraTurnTime
			turningRotor = false
			busy = true
			hud.setState("rotating")
		end

		local function startRotor()
			if busy then
				refuse("hold — finish moving first")
				return
			end
			rotorFrom = rotorState
			rotorState = (rotorState + 1) % 4
			rotorTo = rotorFrom + 1
			turning = TUNE.rotorTurnTime
			turningRotor = true
			busy = true
			hud.setState("turning the bridge")
		end

		local function resetDemo()
			path = {}
			pathAt = 0
			busy = false
			turning = 0
			nodeIndex = Level.START_INDEX
			camState = 1
			rotorState = 1
			level.setRotor(rotorState)
			placePuppet(nodeWorld(nodeIndex, rotorState))
			hud.setState("")
			setHint()
		end

		--[[
			Click-to-move. Nodes are projected with the ACTUAL camera's WorldToViewportPoint --
			more robust at FOV 1 than unprojecting a screen ray, where a one-pixel error becomes
			metres at 1,700 studs.
		]]
		local function clickAt(screen: Vector2)
			if busy then
				refuse("hold — the view is turning")
				return
			end
			--[[
				Coincident tiles are the POINT of this demo, so the click cannot be resolved by
				nearest-pixel alone: at a join the two nodes are separated by a couple of pixels of
				perspective residual, far below aiming precision, and whichever won would be
				decided by sub-pixel noise rather than by the player. So: gather every candidate
				within the radius, drop the node the puppet is already on, and pick the one with
				the SHORTEST route -- which at a join is the far side, the thing the player meant.
			]]
			local positions = worldPositions(rotorState)
			local candidates: { number } = {}
			for i, world in positions do
				local point, onScreen = cam:WorldToViewportPoint(world)
				if onScreen and (Vector2.new(point.X, point.Y) - screen).Magnitude <= TUNE.clickRadiusPx then
					table.insert(candidates, i)
				end
			end
			if #candidates == 0 then
				return
			end

			local adj = activeGraph().adj
			local best: number? = nil
			local bestLength = math.huge
			local sawSelf = false
			for _, i in candidates do
				if i == nodeIndex then
					sawSelf = true
				else
					local route = Graph.path(adj, nodeIndex, i)
					if route and #route < bestLength then
						best, bestLength = i, #route
					end
				end
			end

			if not best then
				-- Never silent: a dead click at the moment the join fuses is exactly when the demo
				-- looks broken.
				refuse(if sawSelf then "already there — click the far side of the join" else "no route from here in this view")
				return
			end
			local route = Graph.path(adj, nodeIndex, best)
			if not route then
				refuse("no route from here in this view")
				return
			end
			path = route
			pathAt = 1
			walkT = 0
			busy = true
			hud.setState("")
		end

		local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if input.KeyCode == Enum.KeyCode.Left then
				startTurn(-1)
			elseif input.KeyCode == Enum.KeyCode.Right then
				startTurn(1)
			elseif input.KeyCode == Enum.KeyCode.F then
				startRotor()
			elseif input.KeyCode == Enum.KeyCode.R then
				resetDemo()
			elseif input.KeyCode == Enum.KeyCode.Q then
				doExit()
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				clickAt(UserInputService:GetMouseLocation())
			elseif input.UserInputType == Enum.UserInputType.Touch then
				clickAt(Vector2.new(input.Position.X, input.Position.Y))
			end
		end)
		s.track(inputConn)

		ctx.onCharacter(function()
			-- Re-hide and re-park: a respawn returns an unfrozen character at the lobby, and hands
			-- CameraType back to the default scripts.
			holdAvatar()
			Shell.placeCharacter(ctx.player, origin * CFrame.new(TUNE.characterOffset))
			cam.CameraType = Enum.CameraType.Scriptable
		end)

		--------------------------------------------------------------------------------
		-- THE FRAME LOOP
		--------------------------------------------------------------------------------
		cam.CFrame = cframeFor(camState + 1)
		cam.Focus = CFrame.new(targetWorld)

		local bind = ctx.bindName
		RunService:BindToRenderStep(bind, Enum.RenderPriority.Camera.Value + 1, function(rawDt: number)
			local dt = Damp.clampDt(rawDt)

			-- 1. rotation. Connectivity is UNDEFINED mid-rotation, so input is locked and the
			--    puppet is frozen until the tween lands; only then does the graph swap.
			yawNow = math.rad(TUNE.yawDeg[camState + 1])

			if turning > 0 then
				turning = math.max(turning - dt, 0)
				local total = if turningRotor then TUNE.rotorTurnTime else TUNE.cameraTurnTime
				local alpha = Damp.easeOutQuint(1 - turning / total)
				if turningRotor then
					level.setRotor(rotorFrom + (rotorTo - rotorFrom) * alpha)
					-- If the puppet is standing on the rotor, it rides it.
					if nodeIndex > #Level.NODES then
						placePuppet(nodeWorld(nodeIndex, rotorFrom + (rotorTo - rotorFrom) * alpha))
					end
				else
					-- Interpolate the YAW, not the CFrame: lerping position would cut a chord
					-- through the sphere and visibly change the apparent size mid-turn.
					yawNow = turnFrom + (turnTo - turnFrom) * alpha
				end
				if turning <= 0 then
					busy = #path > 0
					if turningRotor then
						level.setRotor(rotorState)
						if nodeIndex > #Level.NODES then
							placePuppet(nodeWorld(nodeIndex, rotorState))
						end
					else
						yawNow = math.rad(TUNE.yawDeg[camState + 1])
					end
					hud.setState("")
				end
			end

			--[[
				THE CAMERA IS WRITTEN EVERY FRAME, unconditionally, before anything can return
				early. Writing it only on transitions meant a respawn -- which hands CameraType
				back to the default scripts -- left the view parked on the avatar 300 studs away
				for the rest of the session, with no path back. Focus goes with it: left alone it
				stays at the lobby, thousands of studs behind the camera.
			]]
			cam.CFrame = cframeForYaw(yawNow)
			cam.Focus = CFrame.new(targetWorld)

			if turning > 0 then
				return -- connectivity is undefined mid-rotation: the puppet is frozen
			end

			-- 2. traversal
			if pauseFor > 0 then
				pauseFor = math.max(pauseFor - dt, 0)
				return
			end

			if #path > 0 and pathAt < #path then
				local fromIndex = path[pathAt]
				local toIndex = path[pathAt + 1]
				local a = nodeWorld(fromIndex, rotorState)
				local b = nodeWorld(toIndex, rotorState)

				if Graph.isVirtual(activeGraph(), fromIndex, toIndex) then
					-- A SNAP, not a slide. Roblox gives no per-object depth sorting, so a puppet
					-- straddling two depths cannot be rendered correctly; Monument Valley
					-- teleports across the seam for the same reason.
					placePuppet(b)
					nodeIndex = toIndex
					pathAt += 1
					pauseFor = TUNE.snapPause
					hud.setState("crossed a join")
				else
					local span = (b - a).Magnitude
					walkT += dt * TUNE.walkSpeed / math.max(span, 0.001)
					if walkT >= 1 then
						placePuppet(b)
						nodeIndex = toIndex
						pathAt += 1
						walkT = 0
					else
						placePuppet(a:Lerp(b, walkT))
					end
				end

				if pathAt >= #path then
					path = {}
					pathAt = 0
					busy = false
					if nodeIndex == Level.GOAL_INDEX then
						hud.setState("GOAL — the join was only there from one angle")
					end
				end
			end
		end)
		s.add(function()
			RunService:UnbindFromRenderStep(bind)
		end)

		hud.fade(1, 0.45)
	end)
end

return Demo4
