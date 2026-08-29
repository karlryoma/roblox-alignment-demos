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
local Editor = require(script.Parent.Editor)
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

	--[[ Slack, as the angle the two points subtend at the eye -- which is zero exactly when they
	     are drawn on the same pixel. 0.13 deg is about 23 px of a 1080p frame at FOV 6: wide
	     enough that a settle within ~3 degrees of the exact angle takes, narrow enough that the
	     player is genuinely hunting for it. Viewport-independent by construction. ]]
	epsilonDeg = 0.13,

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
		ctx.place(building.spawnCF())

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
		seamOptions.epsilonDeg = TUNE.epsilonDeg
		seamOptions.occluders = { building.occluders }

		-- Authoring assertion: a pair whose orientations do not match cannot be crossed by a pure
		-- translation, and would silently mangle the player's velocity.
		for _, pair in Building.INTENDED do
			local a, b = nodes[indexById[pair[1]]], nodes[indexById[pair[2]]]
			local fault = Seam.orientationFault(a, b)
			if fault then
				--[[ A warning, not an error: a pasted POSE line can now carry a tilt past the
				     crossing tolerance, and refusing to BOOT over it turned a recoverable
				     authoring state into a hand-edit-the-file lockout. The settle HUD and the
				     editor's tilt warning both name the problem at runtime. ]]
				warn(`[demo3] intended seam {pair[1]}-{pair[2]} is not crossable as authored: {fault}`)
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
			--[[ Measured from the LIVE geometry, not from bounds captured at build time: the map
			     editor moves surfaces, and a stale box crops the frame or wastes it. ]]
			local lo = Vector3.new(math.huge, math.huge, math.huge)
			local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
			for _, item in building.folder:GetDescendants() do
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

		local lastSafe = building.spawnCF()
		--[[ Assigned in the editor wiring below. A respawn hands the fresh Humanoid its walking
		     speed back, which silently discarded the editor's WalkSpeed-0 freeze mid-edit. ]]
		local refreezeForEditor: (() -> ())? = nil
		ctx.onCharacter(function()
			prepareCharacter()
			refreshCameraFilter()
			Shell.placeCharacter(ctx.player, lastSafe)
			if refreezeForEditor then
				refreezeForEditor()
			end
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
		local editing = false
		-- Assigned in the editor wiring below; settle() is defined before the editor exists.
		local editorHasTilt: (() -> boolean)? = nil
		local stillFor = 0
		--[[ The camera boots exactly on target, so the first settle lands at t = dwellTime --
		     the same moment the entry fade ends -- and its hint overwrote the intro line (the
		     only on-screen mention of M) before anyone could read it. The intro hint stands
		     until the player has actually orbited once. ]]
		local hasDragged = false
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

		--[[
			SNAP ON SETTLE — what makes the crossing actually seamless.

			A weave is legal anywhere inside epsilonDeg (0.13 deg = 23 px at 1080p), and the
			crossing teleports the avatar by exactly the node-to-partner delta -- so every pixel
			of legal residual became a visible sideways JUMP at the moment of crossing. Monument
			Valley's answer: recalculate only at snap positions, and make the snap exact. When
			the camera settles and a seam is within epsilon, the surface the player is NOT
			standing on is nudged the last fraction of a stud so the two nodes sit on the same
			eye ray EXACTLY -- at most ~1 stud, imperceptible from the composed angle because the
			move is across the residual only. Undone the moment the settle breaks, so orbiting
			shows the honest geometry and the editor never sees a snapped world.
		]]
		local snapped: { [Model]: Vector3 } = {}
		local standingOn: (model: Model) -> boolean
		local function revertSnaps()
			for model, delta in snapped do
				--[[ Carry the player with the floor. A successful crossing always LANDS on the
				     snapped surface (the snap deliberately moves the side the player is not on),
				     so the settle-breaking orbit that follows every crossing used to slide the
				     ground out from under them by up to a stud. Same rule as the snap itself,
				     applied in reverse. ]]
				if standingOn(model) then
					local character = ctx.player.Character
					if character then
						character:PivotTo(character:GetPivot() - delta)
					end
				end
				model:PivotTo(model:GetPivot() - delta)
			end
			table.clear(snapped)
		end

		function standingOn(model: Model): boolean
			local character = ctx.player.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if not root or not root:IsA("BasePart") then
				return false
			end
			local cf, size = model:GetBoundingBox()
			local p = cf:PointToObjectSpace(root.Position)
			return math.abs(p.X) <= size.X / 2 + 3 and math.abs(p.Z) <= size.Z / 2 + 3 and p.Y >= 0 and p.Y <= size.Y / 2 + 8
		end

		local function unsettle()
			if not settled then
				return
			end
			settled = false
			liveEdges = 0
			table.clear(liveBars)
			traverser.setGraph(nil, nil)
			-- The snap only ever exists inside a settle: orbiting away shows honest geometry.
			revertSnaps()
			if not solved then
				hud.setState("")
				--[[ Until the first drag this is the intro line, M mention included: R triggers
				     unsettle without any drag, and the bare version stranded a player who had not
				     yet found the orbit with no M and no what-next. ]]
				hud.setHint(
					if hasDragged
						then "hold the camera still to weave"
						else "hold the camera still to weave · M edits the map"
				)
			end
		end

		local function settle()
			settled = true
			stillFor = 0
			settleYaw, settlePitch = orbit.get()
			-- Measure the honest geometry: a re-settle (editor onChanged) must not snap on top
			-- of a previous snap.
			revertSnaps()
			local graph = Seam.build(nodes, cam:GetRenderCFrame(), seamOptions)
			if not editing then
				local eye = cam:GetRenderCFrame().Position
				for _, edge in graph.edges do
					local na, nb = nodes[edge.a], nodes[edge.b]
					local ma, mb = building.models[na.surface], building.models[nb.surface]
					-- The ground under the player's feet must not shift: move the other side.
					local movePoint, fixedPoint, moveModel = na.point, nb.point, ma
					if standingOn(ma) then
						movePoint, fixedPoint, moveModel = nb.point, na.point, mb
					end
					local toFixed = fixedPoint.WorldPosition - eye
					if toFixed.Magnitude > 1e-3 then
						local wanted = eye + toFixed.Unit * (movePoint.WorldPosition - eye).Magnitude
						local delta = wanted - movePoint.WorldPosition
						--[[ The legal residual is ANGULAR, so its stud size scales with distance:
						     epsilon at this range, plus a quarter of slack. A fixed cap silently
						     stopped snapping on portrait viewports, where the fitted standoff
						     grows and a legal residual can exceed 1.4 studs. ]]
						local maxSnap = toFixed.Magnitude * math.tan(math.rad(TUNE.epsilonDeg)) * 1.25
						if delta.Magnitude > 1e-4 and delta.Magnitude <= maxSnap then
							moveModel:PivotTo(moveModel:GetPivot() + delta)
							snapped[moveModel] = (snapped[moveModel] or Vector3.zero) + delta
						end
					end
				end
			end
			-- Handing the character in disarms any node whose mouth already contains it, which is
			-- the fix for the case that would otherwise read as a bug: settling while standing ON
			-- a seam that goes live. It is per-node and self-releasing, so unlike a blanket timer
			-- it never eats a crossing the player is legitimately walking into.
			-- Never armed while the map is being edited: being teleported mid-nudge is
			-- indistinguishable from the map being wrong.
			traverser.setGraph(if editing then nil else graph, ctx.player.Character)
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
				if hasDragged then
					hud.setHint("walk into a lit seam")
				end
			elseif graph.rejectedOrientation > 0 and editorHasTilt ~= nil and editorHasTilt() then
				--[[ A pair LINES UP from here but its faces no longer oppose, AND a tilt exists to
				     blame. The tilt condition matters: three authored pairs coincide at reachable
				     angles with faces ninety degrees apart, and blaming a tilt on a pristine map
				     would send the author undoing edits they never made. ]]
				hud.setState("SETTLED — a seam lines up here but its faces no longer oppose")
				if hasDragged then
					hud.setHint("a tilted piece? M opens the editor, BACKSPACE puts it back")
				end
			elseif graph.rejectedHidden > 0 then
				hud.setState("SETTLED — a seam lines up here but a pole hides it")
				if hasDragged then
					hud.setHint("try another angle · M edits the map")
				end
			else
				hud.setState("SETTLED — nothing coincides from here")
				if hasDragged then
					hud.setHint("try another angle · drag orbits · M edits the map")
				end
			end
		end

		local function resetDemo()
			unsettle()
			solved = false
			ctx.place(building.spawnCF())
			lastSafe = building.spawnCF()
			orbit.set(math.rad(TUNE.startYawDeg), math.rad(TUNE.startPitchDeg))
			prevYaw, prevPitch = orbit.get()
			stillFor = 0
		end

		--------------------------------------------------------------------------------
		-- the map editor
		--
		-- These illusions are composed by eye, so the composition belongs to a person. One entry
		-- per (surface, seam): moving a surface moves its walkway, its skirt and its seam marker
		-- together, and SOLVE places it so that seam coincides exactly from wherever the camera
		-- is standing right now.
		--------------------------------------------------------------------------------
		--[[ Plain names. The panel is read by a person composing a picture, so it should never
		     show an internal id like "A" or "col-B". ]]
		local FRIENDLY: { [string]: string } = {
			A = "start walkway",
			B = "high walkway",
			C = "goal walkway",
			["col-A"] = "pole under the start",
			["col-B"] = "pole under the high walkway",
			["col-C"] = "pole under the goal",
		}
		local function friendly(name: string): string
			return FRIENDLY[name] or name
		end

		local editorTargets: { Editor.Target } = {}
		for _, pair in Building.INTENDED do
			for _, ends in { { pair[1], pair[2] }, { pair[2], pair[1] } } do
				local nodeId, partnerId = ends[1], ends[2]
				local spec: Building.NodeSpec? = nil
				for _, candidate in Building.NODES do
					if candidate.id == nodeId then
						spec = candidate
					end
				end
				local surfaceName = (spec :: Building.NodeSpec).surface
				local partnerSurface = surfaceName
				for _, candidate in Building.NODES do
					if candidate.id == partnerId then
						partnerSurface = candidate.surface
					end
				end
				table.insert(editorTargets, {
					id = friendly(surfaceName),
					joinsTo = friendly(partnerSurface),
					model = building.models[surfaceName] :: PVInstance,
					seams = {
						{
							node = building.attachments[nodeId],
							partner = building.attachments[partnerId],
							label = `{nodeId}~{partnerId}`,
						},
					},
					export = function(offset: Vector3): { string }
						local lines: { string } = {}
						--[[ A TILTED piece cannot round-trip through the position-only tables: the
						     tilt pivots on the seam node, so `at + offset` misplaces BOTH nodes by
						     the pivot's displacement (~0.1-0.2 studs per 2 deg, and the coincidence
						     pose drifts with it). One absolute POSE line reproduces the whole
						     thing -- Building.build applies it by PivotTo, exactly like the live
						     edit. ]]
						-- Origin-relative, like every other exported number: the live pivot carries
						-- the demo's region offset (thousands of studs), and baking that into the
						-- file would break the one convention the origin parameter exists for.
						local pose = building.origin:ToObjectSpace(building.models[surfaceName]:GetPivot())
						local rx, ry, rz = pose:ToEulerAnglesYXZ()
						if math.max(math.abs(rx), math.abs(ry), math.abs(rz)) > 1e-4 then
							table.insert(
								lines,
								(
									'Building.POSE["%s"] = CFrame.new(%.3f, %.3f, %.3f) * CFrame.fromEulerAnglesYXZ(%.6f, %.6f, %.6f)'
								):format(surfaceName, pose.X, pose.Y, pose.Z, rx, ry, rz)
							)
							return lines
						end
						for _, surface in Building.SURFACES do
							if surface.name == surfaceName then
								local at = surface.at + offset
								table.insert(
									lines,
									("SURFACES %s: at = Vector3.new(%.2f, %.2f, %.2f)"):format(surface.name, at.X, at.Y, at.Z)
								)
							end
						end
						for _, candidate in Building.NODES do
							if candidate.surface == surfaceName then
								local at = candidate.local_ + offset
								table.insert(
									lines,
									("NODES %s: local_ = Vector3.new(%.2f, %.2f, %.2f)"):format(candidate.id, at.X, at.Y, at.Z)
								)
							end
						end
						return lines
					end,
				})
			end
		end

		local editorFreeze: (() -> ())? = nil
		--[[ Zero the CURRENT humanoid's WalkSpeed and remember how to give it back. A function
		     because two moments need it: opening the editor, and a respawn while it is open --
		     the fresh Humanoid arrives walking, and the old freeze holds a dead reference. ]]
		local function freezeAvatar()
			local character = ctx.player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid then
				local walk = humanoid.WalkSpeed
				humanoid.WalkSpeed = 0
				editorFreeze = function()
					if humanoid.Parent then
						humanoid.WalkSpeed = walk
					end
				end
			end
		end
		--[[ What the ordering commands can place things relative to: every walkable surface and
		     every pole. Curated rather than a descendant walk, which would bury the list in
		     skirts and marker bars. ]]
		local editorReferences: { Editor.Reference } = {}
		for name, model in building.models do
			table.insert(editorReferences, { name = friendly(name), instance = model :: Instance })
		end
		for _, pole in building.occluders:GetChildren() do
			table.insert(editorReferences, { name = friendly(pole.Name), instance = pole :: Instance })
		end

		--[[ The poles are editable pieces too, not just things to be ordered against. A rule like
		     "behind that walkway but in front of this pole" is often only satisfiable by moving the
		     POLE, so a pole the author cannot select is a dead end in the middle of composing.
		     They carry no seam, and the panel already handles a piece with no join. ]]
		for _, pole in building.occluders:GetChildren() do
			if not pole:IsA("BasePart") then
				continue
			end
			local part = pole
			table.insert(editorTargets, {
				id = friendly(part.Name),
				joinsTo = "nothing -- scenery",
				model = part :: PVInstance,
				seams = {},
				export = function(_offset: Vector3): { string }
					-- Straight from the live pivot, back into the frame this file is written in.
					local at = building.origin:PointToObjectSpace(part.Position)
					return {
						('newPart("%s", ... , Vector3.new(%.2f, %.2f, %.2f), ...)'):format(
							part.Name,
							at.X,
							at.Y,
							at.Z
						),
					}
				end,
			})
		end

		local editor = Editor.new(editorTargets, {
			camera = cam,
			playerGui = ctx.playerGui,
			references = editorReferences,
			-- A moved surface invalidates whatever was settled: rebuild it so the lit seams and
			-- the readout always describe the geometry as it is now.
			onChanged = function()
				opts.distance = fitDistance()
				if settled then
					settle()
				end
			end,
			onOpen = function()
				editing = true
				traverser.setGraph(nil, nil)
				-- The author edits the real map, never the snapped one.
				revertSnaps()
				freezeAvatar()
			end,
			onClose = function()
				editing = false
				if editorFreeze then
					editorFreeze()
					editorFreeze = nil
				end
				if settled then
					settle()
				end
			end,
		})
		s.add(function()
			if editorFreeze then
				editorFreeze()
				editorFreeze = nil
			end
		end)
		s.add(editor.destroy)
		refreezeForEditor = function()
			if editor.isOpen() then
				freezeAvatar()
			end
		end
		editorHasTilt = editor.hasTiltWork

		local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			--[[ M, not F2. Studio binds F2 to Rename and swallows it before the game sees it, and
			     this is a tool you only ever use inside Studio. F2 stays as an alias for anyone
			     running a published place. ]]
			if input.KeyCode == Enum.KeyCode.M or input.KeyCode == Enum.KeyCode.F2 then
				-- Everything the mode change implies lives in the editor's own open/close hooks,
				-- so a later edit cannot quietly re-arm what this switched off.
				editor.toggle()
				return
			end

			--[[ While the editor is open every other key here belongs to it. Without this, Q would
			     still quit the demo mid-edit and R would throw away the work. One guard beats
			     teaching each branch about the editor. ]]
			if editor.isOpen() then
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
				--[[ The offset direction IS the view direction that makes the pair coincide, so the
				     angle to hunt for is not a mystery: print it. ]]
				--[[ The line through the pair has two directions and only one of them is a camera
				     the player can reach; print the one inside the pitch clamp. ]]
				local yaw, pitch = Align.toSpherical(offset)
				if math.deg(pitch) < TUNE.minPitchDeg then
					yaw, pitch = Align.toSpherical(-offset)
				end
				print(
					("[demo3] seam %s~%s: offset (%.0f, %.0f, %.0f), %.1f studs deep · coincides at yaw %.1f deg, pitch %.1f deg"):format(
						pair[1],
						pair[2],
						offset.X,
						offset.Y,
						offset.Z,
						offset.Magnitude,
						(math.deg(yaw) + 360) % 360,
						math.deg(pitch)
					)
				)
				--[[ Assert the pair CONNECTS at its own pose, not just that it coincides. The
				     aggregate sweep below cannot tell two live seams from one seam counted at two
				     angles, and its healthy-reading summary printed identically for a completable
				     route and a dead one. A pair can coincide yet be rejected -- pole in the way,
				     faces no longer opposed, pose outside the pitch clamp -- and each of those is
				     a different authoring mistake, so name it. ]]
				if math.deg(pitch) < TUNE.minPitchDeg or math.deg(pitch) > TUNE.maxPitchDeg then
					warn(
						("[demo3] INTENDED seam %s~%s coincides only at pitch %.1f deg -- outside the [%d, %d] clamp: unreachable"):format(
							pair[1],
							pair[2],
							math.deg(pitch),
							TUNE.minPitchDeg,
							TUNE.maxPitchDeg
						)
					)
				else
					local probe = CFrame.lookAt(
						focusWorld + Align.fromSpherical(yaw, pitch, 1) * opts.distance,
						focusWorld
					)
					local g = Seam.build(nodes, probe, seamOptions)
					local connected = false
					for _, edge in g.edges do
						local ea, eb = nodes[edge.a].id, nodes[edge.b].id
						if (ea == pair[1] and eb == pair[2]) or (ea == pair[2] and eb == pair[1]) then
							connected = true
						end
					end
					if not connected then
						warn(
							("[demo3] INTENDED seam %s~%s does NOT connect at its own pose (rejected: %d hidden, %d orientation) -- the route may be uncompletable"):format(
								pair[1],
								pair[2],
								g.rejectedHidden,
								g.rejectedOrientation
							)
						)
					end
				end
			end
			print(`[demo3] {#nodes} nodes, {found} intended seams, all orientation-checked`)
			print("[demo3] press M in-game for the map editor (F2 also works outside Studio)")
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

			editor.step(dt)

			local f = drag.consume()
			if f.dx ~= 0 or f.dy ~= 0 then
				hasDragged = true
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
					-- Measured against the goal part's LIVE position, not the authored literal: the
					-- goal rides its surface, so an edited map must still be completable.
					local toGoal = root.Position - building.goal.Position
					if not solved and math.abs(toGoal.X) < 2.5 and math.abs(toGoal.Z) < 2.5 and math.abs(toGoal.Y) < 6 then
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

		hud.setHint("hold the camera still to weave · M edits the map")
		hud.fade(1, 0.45)
	end)
end

return Demo3
