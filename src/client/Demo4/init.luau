--!strict
--[[
	DEMO 4 — LOCKED ISOMETRIC (the capstone)

	Demo 4 is demo 3 with the camera taken away from the player.

	Demo 3 gives a free orbit and makes screen-space connections live only after the camera
	settles. Here the camera snaps between four fixed isometric angles, so it is ALWAYS settled:
	there is nothing to wait for, and the connections are live the instant a rotation completes.
	Same real player character, same normal Humanoid walking, same Seam traversal core.

	WHAT THE FOUR STATES BUY: because the camera has finitely many poses and the sub-model has
	four, EVERY connectivity graph can be computed up front -- sixteen of them, baked at start().
	That is the architectural point, and it decouples two things that look coupled: the RENDERING
	is an approximation of an orthographic projection, while the LOGIC is exact (Seam.project has
	no perspective divide in it at all). The illusion being imperfect can never leak into
	correctness.

	THE RENDERING BUDGET, DERIVED NOT COPIED. FieldOfView is clamped to [1, 120] and
	H = 2*D*tan(FOV/2). This level projects to about 54 studs of on-screen height across the four
	states -- not the 40 a smaller diorama would -- so the standoff works out at:

	    FOV 1 -> 3,468 studs, seam residual 1.3 px, apparent size change per crossing 0.6%
	    FOV 2 -> 1,734 studs, 2.6 px, 1.2%
	    FOV 3 -> 1,156 studs, 3.9 px, 1.8%
	    FOV 4 ->   867 studs, 5.2 px, 2.4%

	FOV 3 is chosen. Every one of those residuals is inside the ~10 px budget, so the deciding
	factor is DISTANCE, not orthographic purity: Roblox's level-of-detail is distance-based, not
	screen-size-based. The engine does not know the character occupies 89 px; it sees an avatar
	1,156 studs away and may simplify it, and graphics quality is a client setting a script cannot
	override -- settings() is plugin-security and throws in a live game. FOV 3 is the smallest
	standoff that still reads as parallel.

	I COULD NOT TEST THAT. Nothing in this repo has run in Studio, so how the avatar actually
	renders at 1,156 studs is unverified. If it degrades, TUNE.fovDeg is the single number to
	change: 4 costs 867 studs and 5.2 px, 6 costs 578 studs and 7.7 px.

	CONTROLS  walk with WASD · LEFT/RIGHT rotate the view · F turns the bridge · R reset ·
	          Q or EXIT leaves.  Q stays the exit key here, as in every other demo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Align = require(ReplicatedStorage.Shared.Align)
local Damp = require(ReplicatedStorage.Shared.Damp)
local Seam = require(ReplicatedStorage.Shared.Seam)
local Session = require(ReplicatedStorage.Shared.Session)
local Shell = require(ReplicatedStorage.Shared.Shell)

local Feedback = require(script.Parent.Feedback)
local Hud = require(script.Parent.Hud)
local Editor = require(script.Parent.Editor)
local Level = require(script.Level)

local TUNE = {
	fovDeg = 3,
	elevationDeg = 35.264, -- true isometric: the four yaw states then give the four diagonals
	yawDeg = { 45, 135, 225, 315 },
	frameMargin = 1.12,
	framePad = 2.0,

	--[[ Slack as the angle the pair subtends at the eye: zero exactly when they are drawn on the
	     same pixel. 0.07 deg is about 25 px of a 1080p frame at FOV 3. ]]
	epsilonDeg = 0.07,
	--[[ The rotation IS the mechanic. Fast enough not to drag, slow enough that the player
	     watches the join arrive. ]]
	turnTime = 0.65,
	rotorTime = 0.6,
	walkSpeed = 16,
	fallY = -40,
}

local Demo4 = {}

Demo4.id = "isometric"
Demo4.title = "DEMO 4 — LOCKED ISOMETRIC"
Demo4.blurb = "Four fixed angles, a turning bridge, sixteen baked graphs. Always settled."
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

		-- Flat-shaded on purpose: shadows are dead at this range, so the look leans on raised
		-- ambient and hand-picked face colours.
		s.add(ctx.dim({ depthOfField = true, atmosphere = true, fog = true }))

		local level = Level.build(origin, workspace)
		s.add(level.destroy)
		ctx.place(level.spawnCF)

		--------------------------------------------------------------------------------
		-- camera: four fixed poses, written every frame
		--------------------------------------------------------------------------------
		local focusWorld = (origin * CFrame.new(level.centre)).Position

		local function directionFor(yawRad: number): Vector3
			return Align.fromSpherical(yawRad, math.rad(TUNE.elevationDeg), 1)
		end

		local function fitDistance(): number
			local halfV = math.tan(math.rad(TUNE.fovDeg) * 0.5)
			local vp = cam.ViewportSize
			local aspect = if vp.Y > 0 then vp.X / vp.Y else 1
			--[[ Measured from the LIVE geometry, not from bounds captured at build time: the map
			     editor moves surfaces, and a stale box crops the frame or wastes it. ]]
			local lo = Vector3.new(math.huge, math.huge, math.huge)
			local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
			for _, item in level.folder:GetDescendants() do
				if item:IsA("BasePart") then
					lo = lo:Min(item.Position - item.Size * 0.5)
					hi = hi:Max(item.Position + item.Size * 0.5)
				end
			end
			local corners: { Vector3 } = {}
			for _, x in { lo.X, hi.X } do
				for _, y in { lo.Y, hi.Y } do
					for _, z in { lo.Z, hi.Z } do
						table.insert(corners, Vector3.new(x, y, z))
					end
				end
			end
			local widest, tallest = 0, 0
			for i = 1, 4 do
				local dir = directionFor(math.rad(TUNE.yawDeg[i]))
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
			return TUNE.frameMargin * math.max(tallest * 0.5 / halfV, widest * 0.5 / (halfV * aspect))
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
			-- CameraType LAST: restoring it first hands control back to the default scripts, which
			-- then fight every property written after it.
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

		local viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			distance = fitDistance()
		end)
		s.track(viewportConn)

		local function cframeForYaw(yawRad: number): CFrame
			return CFrame.lookAt(focusWorld + directionFor(yawRad) * distance, focusWorld)
		end

		--------------------------------------------------------------------------------
		-- seams
		--------------------------------------------------------------------------------
		local nodes: { Seam.Node } = {}
		local indexById: { [string]: number } = {}
		for _, spec in Level.NODES do
			table.insert(nodes, { id = spec.id, point = level.attachments[spec.id], surface = spec.surface })
			indexById[spec.id] = #nodes
		end

		local seamOptions = Seam.defaults()
		seamOptions.epsilonDeg = TUNE.epsilonDeg
		seamOptions.occluders = { level.occluders }

		local traverser = Seam.newTraverser(nodes, Seam.traverserDefaults())

		--------------------------------------------------------------------------------
		-- the bake: sixteen graphs, computed up front
		--------------------------------------------------------------------------------
		local graphs: { [number]: Seam.Graph } = {}
		local function key(camState: number, rotorState: number): number
			return camState * 4 + rotorState
		end

		local function bakeAll()
			for rotorState = 0, 3 do
				-- The rotor must PHYSICALLY be in each state: Seam reads live Attachment
				-- WorldCFrames, which is exactly what makes a rotated seam correct.
				level.setRotor(rotorState)
				for camState = 0, 3 do
					graphs[key(camState, rotorState)] =
						Seam.build(nodes, cframeForYaw(math.rad(TUNE.yawDeg[camState + 1])), seamOptions)
				end
			end
		end

		--------------------------------------------------------------------------------
		-- character
		--------------------------------------------------------------------------------
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

		local function setWalkable(on: boolean)
			local character = ctx.player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid then
				humanoid.WalkSpeed = if on then TUNE.walkSpeed else 0
			end
		end

		--------------------------------------------------------------------------------
		-- state
		--------------------------------------------------------------------------------
		local camState = 1 -- the route needs 0 first, so the player must rotate to reach it
		local rotorState = 0
		local turning = 0
		local turningRotor = false
		local fromYaw, toYaw = 0, 0
		local rotorFrom, rotorTo = 0, 0
		local rotorPrevCF = level.rotor:GetPivot()
		local riding = false
		local yawNow = math.rad(TUNE.yawDeg[camState + 1])
		local lastSafe = level.spawnCF
		local solved = false
		local resetQueued = false
		local prox = 0

		local liveBars: { [BasePart]: boolean } = {}
		local flashFor = 0
		local editing = false

		local fx = Feedback.new()
		s.add(fx.destroy)
		fx.add(function(p: number, dt: number)
			flashFor = math.max(flashFor - dt, 0)
			local flash = flashFor / 0.3
			for _, bar in level.bars do
				if liveBars[bar] then
					local lit = Level.COLD:Lerp(Level.HOT, p)
					bar.Color = if flash > 0 then lit:Lerp(Color3.new(1, 1, 1), flash) else lit
				else
					bar.Color = Level.COLD
				end
			end
		end)

		local function installGraph()
			local graph = graphs[key(camState, rotorState)]
			-- Never armed while the map is being edited.
			traverser.setGraph(if editing then nil else graph, ctx.player.Character)
			table.clear(liveBars)
			for _, edge in graph.edges do
				local barA = level.markers[nodes[edge.a].id]
				local barB = level.markers[nodes[edge.b].id]
				if barA then
					liveBars[barA] = true
				end
				if barB then
					liveBars[barB] = true
				end
			end
			flashFor = 0.3
			-- Always restored to something true: guarding this on `not solved` left the line reading
			-- "rotating" forever after the first post-solve rotation.
			hud.setState(
				if solved
					then "SOLVED — one angle, one turn, one route"
					elseif #graph.edges > 0 then `{#graph.edges} seam(s) live`
					else "nothing coincides from here"
			)
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

		local function beginTurn(delta: number)
			if turning > 0 then
				return
			end
			fromYaw = math.rad(TUNE.yawDeg[camState + 1])
			camState = (camState + delta) % 4
			toYaw = fromYaw + math.rad(90 * delta)
			turning = TUNE.turnTime
			turningRotor = false
			-- Connectivity is undefined mid-rotation, and the camera-relative movement basis is
			-- swinging under the player's fingers. Freeze both; Monument Valley pauses too.
			traverser.setGraph(nil, nil)
			table.clear(liveBars)
			setWalkable(false)
			hud.setState("rotating")
		end

		local function beginRotor()
			if turning > 0 then
				return
			end
			rotorFrom = rotorState
			rotorState = (rotorState + 1) % 4
			rotorTo = rotorFrom + 1
			turning = TUNE.rotorTime
			turningRotor = true
			rotorPrevCF = level.rotor:GetPivot()

			-- Is the player standing ON the bridge? If so they ride it, which is the Monument
			-- Valley behaviour and much better than refusing the rotation.
			riding = false
			local character = ctx.player.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if root and root:IsA("BasePart") then
				-- Tested against the deck's own frame rather than by raycast: a query depends on
				-- CanQuery being set on every part it might hit, and this is the demo's headline
				-- mechanic -- it should not be one flag away from silently never running.
				local deck = level.rotorDeck
				local p = deck.CFrame:PointToObjectSpace(root.Position)
				local half = deck.Size * 0.5
				riding = math.abs(p.X) <= half.X + 1
					and math.abs(p.Z) <= half.Z + 1
					and p.Y > 0
					and p.Y < 8
			end

			traverser.setGraph(nil, nil)
			table.clear(liveBars)
			setWalkable(false)
			hud.setState("turning the bridge")
		end

		local function resetDemo()
			turning = 0
			camState = 1
			rotorState = 0
			solved = false
			level.setRotor(rotorState)
			rotorPrevCF = level.rotor:GetPivot()
			yawNow = math.rad(TUNE.yawDeg[camState + 1])
			ctx.place(level.spawnCF)
			lastSafe = level.spawnCF
			setWalkable(true)
			installGraph()
			hud.setHint("← → turn the view · F turns the bridge · M edits the map · R reset · Q to leave")
		end

		--------------------------------------------------------------------------------
		-- the map editor
		--
		-- One entry per (surface, seam), including the rotor: moving a unit moves its geometry and
		-- its seam markers together, and SOLVE places it so that seam coincides exactly from the
		-- camera state you are looking from. Composing the shot is a judgement about a picture;
		-- the arithmetic is the part that belongs in code.
		--------------------------------------------------------------------------------
		--[[ Plain names: the panel is read by a person, not by the level file. ]]
		local FRIENDLY: { [string]: string } = {
			S = "start slab",
			T = "goal slab",
			R = "turning bridge",
			["col-S"] = "pole under the start",
			["col-T"] = "pole under the goal",
		}
		local function friendly(name: string): string
			return FRIENDLY[name] or name
		end

		local editorTargets: { Editor.Target } = {}
		for _, pair in Level.INTENDED do
			for _, ends in { { pair[1], pair[2] }, { pair[2], pair[1] } } do
				local nodeId, partnerId = ends[1], ends[2]
				local surfaceName, partnerSurface = "", ""
				for _, candidate in Level.NODES do
					if candidate.id == nodeId then
						surfaceName = candidate.surface
					end
					if candidate.id == partnerId then
						partnerSurface = candidate.surface
					end
				end
				table.insert(editorTargets, {
					id = friendly(surfaceName),
					joinsTo = friendly(partnerSurface),
					model = level.models[surfaceName],
					--[[ The rotor is re-posed from a stored home every time setRotor runs, so a
					     PivotTo on the model would be erased within the frame. Move the home. ]]
					apply = if surfaceName == "R" then level.nudgeRotorHome else nil,
					seams = {
						{
							node = level.attachments[nodeId],
							partner = level.attachments[partnerId],
							label = `{nodeId}~{partnerId}`,
						},
					},
					export = function(offset: Vector3): { string }
						local lines: { string } = {}
						if surfaceName == "R" then
							--[[ The rotor is placed by ROTOR_PIVOT and its nodes are authored in the
							     rotor's own rest frame, so they do not move with it: one line. ]]
							local moved = Level.ROTOR_PIVOT + offset
							table.insert(
								lines,
								("Level.ROTOR_PIVOT = Vector3.new(%.2f, %.2f, %.2f)"):format(moved.X, moved.Y, moved.Z)
							)
							return lines
						end
						local at = Level.SURFACE_AT[surfaceName]
						if at then
							local moved = at + offset
							table.insert(
								lines,
								("SURFACE_AT %s = Vector3.new(%.2f, %.2f, %.2f)"):format(surfaceName, moved.X, moved.Y, moved.Z)
							)
						end
						for _, candidate in Level.NODES do
							if candidate.surface == surfaceName then
								local point = candidate.at + offset
								table.insert(
									lines,
									("NODES %s: at = Vector3.new(%.2f, %.2f, %.2f)"):format(candidate.id, point.X, point.Y, point.Z)
								)
							end
						end
						return lines
					end,
				})
			end
		end

		--[[ What the ordering commands can place things relative to: every walkable surface and
		     every pole. Curated rather than a descendant walk, which would bury the list in
		     skirts and marker bars. ]]
		local editorReferences: { Editor.Reference } = {}
		for name, model in level.models do
			table.insert(editorReferences, { name = friendly(name), instance = model :: Instance })
		end
		for _, pole in level.occluders:GetChildren() do
			table.insert(editorReferences, { name = friendly(pole.Name), instance = pole :: Instance })
		end

		local editor = Editor.new(editorTargets, {
			camera = cam,
			playerGui = ctx.playerGui,
			references = editorReferences,
			-- Sixteen graphs are a snapshot of the geometry, so a moved surface invalidates all of
			-- them. Re-baking is milliseconds and it keeps the lit seams honest.
			onChanged = function()
				distance = fitDistance()
				bakeAll()
				level.setRotor(rotorState)
				installGraph()
			end,
			onOpen = function()
				editing = true
				traverser.setGraph(nil, nil)
				setWalkable(false)
			end,
			onClose = function()
				editing = false
				setWalkable(turning <= 0)
				installGraph()
			end,
			-- Mid-rotation the camera is showing an angle the game can never settle at, so
			-- authoring against it would bake a state that does not exist.
			canSolve = function(): boolean
				return turning <= 0
			end,
		})
		s.add(editor.destroy)

		local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			local code = input.KeyCode

			--[[ M, not F2. Studio binds F2 to Rename and eats it before the game sees it, and this
			     is a tool you only ever use inside Studio. F2 remains an alias elsewhere. ]]
			if code == Enum.KeyCode.M or code == Enum.KeyCode.F2 then
				-- Everything the mode change implies lives in the editor's open/close hooks.
				editor.toggle()
				return
			end

			--[[ While the editor is open the arrow keys belong to it, so view rotation moves to
			     comma/period. One branch, so the two bindings cannot drift apart. ]]
			local turnDelta = 0
			if editor.isOpen() then
				if code == Enum.KeyCode.Comma then
					turnDelta = -1
				elseif code == Enum.KeyCode.Period then
					turnDelta = 1
				end
			elseif code == Enum.KeyCode.Left then
				turnDelta = -1
			elseif code == Enum.KeyCode.Right then
				turnDelta = 1
			end
			if turnDelta ~= 0 then
				beginTurn(turnDelta)
				return
			end

			--[[ Past the view turn, an open editor owns the keyboard: F would drive the rotor
			     against the very home pose being edited, and Q/R would drop the work. ]]
			if editor.isOpen() then
				return
			end

			if code == Enum.KeyCode.F then
				beginRotor()
			elseif code == Enum.KeyCode.R then
				resetQueued = true
			elseif code == Enum.KeyCode.Q then
				doExit()
			end
		end)
		s.track(inputConn)

		ctx.onCharacter(function()
			prepareCharacter()
			Shell.placeCharacter(ctx.player, lastSafe)
			cam.CameraType = Enum.CameraType.Scriptable
			-- prepareCharacter hands a fresh Humanoid its walking speed back, which would lift the
			-- rotation freeze for the rest of the tween -- with no graph installed and the movement
			-- basis still swinging. The freeze is the authority here.
			setWalkable(turning <= 0)
			riding = false
		end)

		--------------------------------------------------------------------------------
		-- bake and report
		--------------------------------------------------------------------------------
		bakeAll()
		level.setRotor(rotorState)

		do
			print(
				("[demo4] FOV %d, fitted standoff %.0f studs -> %.1f px per stud at 1080p"):format(
					TUNE.fovDeg,
					distance,
					(1080 / 2) / (distance * math.tan(math.rad(TUNE.fovDeg) * 0.5))
				)
			)
			--[[ For each authored pair, the view direction that makes it coincide -- which is just
			     the direction of the offset between them. Printed so the angle to look from is a
			     stated fact rather than something to hunt for. ]]
			--[[ A rotor seam only exists at the rotor state that puts it there, so the angle has to
			     be measured per rotor state, not at whatever state happens to be current. ]]
			for _, pair in Level.INTENDED do
				for r = 0, 3 do
					level.setRotor(r)
					local a = level.attachments[pair[1]]
					local b = level.attachments[pair[2]]
					if a and b then
						local offset = b.WorldPosition - a.WorldPosition
						local yaw, pitch = Align.toSpherical(offset)
						if math.deg(pitch) < 0 then
							yaw, pitch = Align.toSpherical(-offset)
						end
						local yawDeg = (math.deg(yaw) + 360) % 360
						for _, stateYaw in TUNE.yawDeg do
							if math.abs(yawDeg - stateYaw) < 6 then
								print(
									("[demo4] seam %s~%s: rotor %d, coincides at yaw %.1f deg, pitch %.1f deg (%.1f studs deep)"):format(
										pair[1],
										pair[2],
										r,
										yawDeg,
										math.deg(pitch),
										offset.Magnitude
									)
								)
							end
						end
					end
				end
			end
			level.setRotor(rotorState)

			local soloSolve: string? = nil
			for c = 0, 3 do
				local row = {}
				for r = 0, 3 do
					local graph = graphs[key(c, r)]
					local reach = Seam.reachableSurfaces(nodes, Level.REAL_EDGES, graph, Level.START_SURFACE)
					local names = {}
					for _, edge in graph.edges do
						table.insert(names, `{nodes[edge.a].id}~{nodes[edge.b].id}`)
					end
					if reach[Level.GOAL_SURFACE] then
						soloSolve = `cam{c}/rotor{r}`
					end
					local flags = ""
					if graph.rejectedOrientation > 0 then
						flags ..= `!orient x{graph.rejectedOrientation}`
					end
					if graph.rejectedHidden > 0 then
						flags ..= `!hidden x{graph.rejectedHidden}`
					end
					table.insert(row, `r{r}:{if #names > 0 then table.concat(names, "+") else "-"}{flags}`)
				end
				print(`[demo4] cam{c} ({TUNE.yawDeg[c + 1]} deg) {table.concat(row, " | ")}`)
			end
			if soloSolve then
				warn(`[demo4] {soloSolve} reaches the goal on its own -- rotation is decorative`)
			else
				print("[demo4] no single state reaches the goal: both rotations are required")
				print("[demo4] press M in-game for the map editor (F2 also works outside Studio)")
			end
		end

		installGraph()
		hud.setHint("← → turn the view · F turns the bridge · M edits the map · R reset · Q to leave · wants high graphics")

		--------------------------------------------------------------------------------
		-- THE FRAME LOOP
		--------------------------------------------------------------------------------
		local bind = ctx.bindName
		RunService:BindToRenderStep(bind, Enum.RenderPriority.Camera.Value + 1, function(rawDt: number)
			local dt = Damp.clampDt(rawDt)
			editor.step(dt)

			if resetQueued then
				resetQueued = false
				resetDemo()
			end

			if turning > 0 then
				turning = math.max(turning - dt, 0)
				local total = if turningRotor then TUNE.rotorTime else TUNE.turnTime
				local alpha = Damp.easeOutQuint(1 - turning / total)
				if turningRotor then
					level.setRotor(rotorFrom + (rotorTo - rotorFrom) * alpha)
					local nowCF = level.rotor:GetPivot()
					if riding then
						local character = ctx.player.Character
						if character then
							-- Carried by the same rigid delta the deck moved through, so the player
							-- turns with the bridge instead of being left behind by it.
							character:PivotTo(nowCF * rotorPrevCF:Inverse() * character:GetPivot())
						end
					end
					rotorPrevCF = nowCF
				else
					yawNow = fromYaw + (toYaw - fromYaw) * alpha
				end
				if turning <= 0 then
					if turningRotor then
						level.setRotor(rotorState)
						rotorPrevCF = level.rotor:GetPivot()
						riding = false
					else
						yawNow = math.rad(TUNE.yawDeg[camState + 1])
					end
					setWalkable(true)
					installGraph()
				end
			end

			-- Written every frame, before anything can return early: a respawn hands CameraType
			-- back to the default scripts, and a camera written only on transitions never recovers.
			cam.CFrame = cframeForYaw(yawNow)
			cam.Focus = CFrame.new(focusWorld)

			local character = ctx.player.Character
			if character and turning <= 0 then
				local crossed = traverser.step(dt, character)
				if crossed and not solved then
					hud.setState(("CROSSED — %.0f studs of depth, invisibly"):format(crossed.depthDelta))
				end

				local root = character:FindFirstChild("HumanoidRootPart")
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if root and root:IsA("BasePart") then
					local localPos = origin:PointToObjectSpace(root.Position)

					-- Against the goal's LIVE position: it rides its surface, so an edited map must
					-- still be completable.
					local toGoal = root.Position - level.goal.Position
					if not solved and math.abs(toGoal.X) < 2.5 and math.abs(toGoal.Z) < 2.5 and math.abs(toGoal.Y) < 6 then
						solved = true
						flashFor = 0.3
						hud.setState("SOLVED — one angle, one turn, one route")
					end

					if localPos.Y < TUNE.fallY then
						Shell.placeCharacter(ctx.player, lastSafe)
					elseif not crossed and humanoid and humanoid.FloorMaterial ~= Enum.Material.Air then
						--[[
							Never latch a pose that the ROTOR carries. A world CFrame recorded on the
							deck stops describing a floor the moment the bridge turns, and the fall
							catch would then teleport the player back into the same patch of empty
							air every time.
						]]
						local deck = level.rotorDeck
						local onDeck = deck.CFrame:PointToObjectSpace(root.Position)
						local half = deck.Size * 0.5
						local carried = math.abs(onDeck.X) <= half.X + 1
							and math.abs(onDeck.Z) <= half.Z + 1
							and onDeck.Y > 0
							and onDeck.Y < 8
						local inside = math.abs(localPos.X) < 40 and math.abs(localPos.Z) < 40 and localPos.Y > -20
						if inside and not carried then
							lastSafe = character:GetPivot()
						end
					end
				end
			end

			-- The meter tracks what is actually live, so the bars are not pinned at full glow in
			-- states where nothing coincides.
			local anyLive = next(liveBars) ~= nil
			local target = if turning > 0 then 0 elseif anyLive then 1 else 0.25
			prox = Damp.damp(prox, target, dt, 0.12)
			hud.setProgress(prox, anyLive, solved)
			fx.render(prox, dt)
		end)
		s.add(function()
			RunService:UnbindFromRenderStep(bind)
		end)

		hud.fade(1, 0.45)
	end)
end

return Demo4
