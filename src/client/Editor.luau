--!strict
--[[
	Editor — a live map editor for the alignment demos.

	WHY THIS EXISTS. These illusions are composed by eye. The maths that makes two points coincide
	is exact and easy; deciding WHICH two things should appear to touch, from WHICH angle, so that
	the shot reads well, is a judgement about a picture. Authoring those numbers blind produces
	geometry that is arithmetically perfect and visually wrong. So this hands the composition back
	to a person and keeps the arithmetic here.

	THE ONE IDEA WORTH KNOWING, and the tool is built around it: moving a surface ALONG THE LINE
	FROM THE EYE changes almost nothing on screen -- it only scales what you see. Motion across
	that line is what changes an alignment. So the nudge keys are screen-relative: left/right and
	up/down move the picture, in/out moves depth nearly for free.

	WHICH IS ALSO HOW YOU CHOOSE WHAT IS IN FRONT. Roblox has no per-object draw order: occlusion
	is decided entirely by distance from the camera. So "put this walkway in front of that one" is
	the same operation as "move it toward the eye" -- and under these near-parallel projections
	that is nearly free in screen terms.

	ORDERING IS A SET OF CONSTRAINTS, NOT A NUDGE. "In front of the pole but behind that platform"
	is a statement about several objects at once, and satisfying one at a time silently undoes the
	others. So IN FRONT OF and BEHIND set constraints, and all of them are re-solved together every
	time any one changes: each becomes an interval of allowed travel along the eye ray, the
	intervals are intersected, and the surface moves the shortest distance into the result.

	DEPTH IS COMPARED WHERE THE TWO THINGS ACTUALLY OVERLAP ON SCREEN, and that is what makes
	CYCLES possible -- A in front of B, B in front of the pole, the pole in front of A. A z-buffer
	does not sort objects, it sorts PIXELS: if the three overlaps happen at three different places
	in frame, each can resolve its own way and the cycle is perfectly renderable. That is precisely
	how a Penrose triangle is built out of three ordinary beams.

	An earlier version compared each object's whole depth RANGE, which forces a single total order
	along the view axis and makes every cycle "impossible" -- a limit of the tool, not of the
	engine. Now each constraint is measured by casting a ray from the eye through the centre of
	that pair's screen overlap and comparing where it enters each object. Pairs that do not overlap
	on screen cannot occlude each other at all, and are reported rather than solved.

	SOLVE is the point of the whole tool. Frame the shot you want, select the surface that should
	appear to meet another, press it, and the surface moves the exact amount that puts its seam
	point on the ray from your eye through the partner -- the same pixel, from where you are
	standing. No eyeballing, no fitting.

	MEASURED IN THE REAL PROJECTION, not an idealised one. The readout is the angle the two points
	subtend at the eye, which is zero exactly when they are drawn on the same pixel. An earlier
	version measured the parallel projection and would print "coincident" for a seam the user
	could plainly see was apart, because perspective separates points by roughly
	(distance from frame centre) x (depth between them) / (camera distance). A tool that lies
	about the thing you are composing is worse than no tool.

	Nothing here writes to disk -- a client cannot. EXPORT prints a paste-ready block to the
	Output; the numbers go back into the level file, which is what Rojo syncs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Seam = require(ReplicatedStorage.Shared.Seam)

local Editor = {}

export type EditorSeam = {
	--[[ The point on THIS target that should appear to touch `partner`. ]]
	node: Attachment,
	partner: Attachment,
	label: string,
}

export type Target = {
	--[[ Plain names, both of them: this panel is read by someone composing a picture. ]]
	id: string,
	joinsTo: string,
	model: Model,
	--[[ How a move is applied. Defaults to PivotTo. A demo overrides it when the model's pose is
	     re-issued from a stored home every frame -- demo 4's rotor -- because a PivotTo would then
	     be erased before the next frame and the panel would report a move that did not happen. ]]
	apply: ((delta: Vector3) -> ())?,
	seams: { EditorSeam },
	--[[ Formats the current pose as something to paste back into the level file. The demo owns
	     this because only the demo knows how its own table is written. ]]
	export: (offset: Vector3) -> { string },
}

export type Handle = {
	toggle: () -> (),
	isOpen: () -> boolean,
	step: (dt: number) -> (),
	destroy: () -> (),
}

--[[ Anything the ordering commands can be placed relative to: surfaces, poles, scenery. The demo
     curates this -- a raw descendant walk would bury the list in skirts and marker bars. ]]
export type Reference = {
	name: string,
	instance: Instance,
}

export type Options = {
	--[[ Called after any edit, so the demo can rebuild whatever it caches (a settled graph, a
	     bake). Edits are rare and this is cheap. ]]
	onChanged: () -> (),
	--[[ Opening and closing the editor is a mode change: the demo freezes the avatar and stops
	     arming crossings, because being walked or teleported mid-nudge is indistinguishable from
	     the map being wrong. ]]
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
	--[[ Whether authoring is legal right now -- demo 4 says no mid-rotation, because the camera is
	     then showing an angle the game can never settle at. ]]
	canSolve: (() -> boolean)?,
	references: { Reference }?,
	camera: Camera,
	playerGui: Instance,
}

local STEPS = { 0.25, 0.5, 1, 2, 5 }
-- Tab is not safe for a game to own, so selection lives on the bracket keys and the step size on
-- minus/equals.

local INK = Color3.fromRGB(228, 236, 248)
local DIM = Color3.fromRGB(126, 140, 158)
local WARN = Color3.fromRGB(255, 196, 110)
local GOOD = Color3.fromRGB(130, 246, 190)

function Editor.new(targets: { Target }, options: Options): Handle
	local cam = options.camera
	local open = false
	local selected = 1
	local stepIndex = 3
	-- Keyed by MODEL, not by entry: several entries can steer the same surface (one per seam it
	-- carries), and they must share one accumulated offset.
	local moved: { [Model]: Vector3 } = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "MapEditor"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Enabled = false
	gui.Parent = options.playerGui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 24, 1, -24)
	panel.Size = UDim2.fromOffset(470, 340)
	panel.BackgroundColor3 = Color3.fromRGB(16, 18, 23)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = WARN
	stroke.Transparency = 0.5
	stroke.Parent = panel

	local function label(y: number, size: number, colour: Color3): TextLabel
		local t = Instance.new("TextLabel")
		t.Position = UDim2.fromOffset(16, y)
		t.Size = UDim2.fromOffset(400, 18)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.Code
		t.TextSize = size
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextColor3 = colour
		t.Text = ""
		t.Parent = panel
		return t
	end

	local title = label(10, 15, WARN)
	title.Text = "MAP EDITOR                                        M closes"

	--[[ Three plain sections rather than six dense lines. The panel is read while composing a
	     picture, so it says what is happening in sentences and keeps the keys for each job next
	     to that job. ]]
	local editingOut = label(34, 13, INK)
	editingOut.Size = UDim2.fromOffset(470, 74)
	editingOut.TextYAlignment = Enum.TextYAlignment.Top

	local stackTitle = label(114, 12, WARN)
	stackTitle.Text = "WHAT IS IN FRONT      nearest the camera first"
	local stackOut = label(132, 12, DIM)
	stackOut.Size = UDim2.fromOffset(470, 66)
	stackOut.TextYAlignment = Enum.TextYAlignment.Top

	local orderOut = label(200, 12, DIM)
	orderOut.Size = UDim2.fromOffset(470, 34)
	orderOut.TextYAlignment = Enum.TextYAlignment.Top

	local status = label(238, 13, GOOD)
	status.Size = UDim2.fromOffset(470, 18)

	local help = label(262, 12, DIM)
	help.Size = UDim2.fromOffset(470, 60)
	help.TextYAlignment = Enum.TextYAlignment.Top
	help.Text = table.concat({
		"MOVE   arrows  across the screen        PgUp / PgDn  toward / away from camera",
		"       -  =  step size                  Z  swap this join front / back",
		"       BACKSPACE  undo this piece       P  print the numbers to paste back",
	}, "\n")

	--[[
		Markers in the WORLD, not just names in a list. Without them the panel talks about "the
		start walkway" and the author has to guess which slab that is -- which is most of why the
		tool was hard to follow. White floats over what is being edited, amber over the reference.
	]]
	local function newMarker(colour: Color3): BasePart
		local marker = Instance.new("Part")
		marker.Name = "EditorMarker"
		marker.Size = Vector3.new(1.6, 1.6, 1.6)
		marker.Color = colour
		marker.Material = Enum.Material.Neon
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanTouch = false
		marker.CanQuery = false
		marker.CastShadow = false
		marker.Transparency = 0.15
		marker.Parent = workspace
		return marker
	end
	local selectedMarker = newMarker(Color3.fromRGB(255, 255, 255))
	local referenceMarker = newMarker(WARN)

	local function parkMarker(marker: BasePart, inst: Instance?)
		if not inst then
			marker.Transparency = 1
			return
		end
		local cf: CFrame, size: Vector3
		if inst:IsA("Model") then
			cf, size = inst:GetBoundingBox()
		elseif inst:IsA("BasePart") then
			cf, size = inst.CFrame, inst.Size
		else
			marker.Transparency = 1
			return
		end
		marker.Transparency = 0.15
		marker.CFrame = cf * CFrame.new(0, size.Y * 0.5 + 2.2, 0)
	end

	local function current(): Target?
		return targets[selected]
	end

	local references: { Reference } = options.references or {}
	local reference = 1
	--[[ Ordering rules, one record per surface. Solved as a set, never one at a time. ]]
	type Rule = { front: Reference?, back: Reference? }
	local constraints: { [Model]: Rule } = {}

	--[[
		How much of the view axis an object occupies. Used for the stack display and for framing;
		ordering uses the per-overlap measurement below, because a range comparison cannot express
		a cycle.
	]]
	local function depthRange(inst: Instance, camCF: CFrame): (number, number)
		local cf: CFrame, size: Vector3
		if inst:IsA("Model") then
			cf, size = inst:GetBoundingBox()
		elseif inst:IsA("BasePart") then
			cf, size = inst.CFrame, inst.Size
		else
			return math.huge, -math.huge
		end
		local half = size * 0.5
		local lo, hi = math.huge, -math.huge
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local at = cf * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)
					local depth = -(camCF:PointToObjectSpace(at.Position).Z)
					lo = math.min(lo, depth)
					hi = math.max(hi, depth)
				end
			end
		end
		return lo, hi
	end

	--[[ Screen-space bounding box of an object, in the live camera's viewport pixels. ]]
	local function screenBox(inst: Instance): (Vector2, Vector2, boolean)
		local cf: CFrame, size: Vector3
		if inst:IsA("Model") then
			cf, size = inst:GetBoundingBox()
		elseif inst:IsA("BasePart") then
			cf, size = inst.CFrame, inst.Size
		else
			return Vector2.zero, Vector2.zero, false
		end
		local half = size * 0.5
		local lo = Vector2.new(math.huge, math.huge)
		local hi = Vector2.new(-math.huge, -math.huge)
		local anyInFront = false
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local at = (cf * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)).Position
					local point, onScreen = cam:WorldToViewportPoint(at)
					if point.Z > 0 then
						anyInFront = true
						local flat = Vector2.new(point.X, point.Y)
						lo = Vector2.new(math.min(lo.X, flat.X), math.min(lo.Y, flat.Y))
						hi = Vector2.new(math.max(hi.X, flat.X), math.max(hi.Y, flat.Y))
					end
					local _ = onScreen
				end
			end
		end
		return lo, hi, anyInFront
	end

	--[[ Where a ray enters an object, as a distance from the eye. Analytic slab test against the
	     object's own oriented box -- no CanQuery, no physics, nothing to misconfigure. ]]
	local function rayEntry(inst: Instance, origin: Vector3, direction: Vector3): number?
		local cf: CFrame, size: Vector3
		if inst:IsA("Model") then
			cf, size = inst:GetBoundingBox()
		elseif inst:IsA("BasePart") then
			cf, size = inst.CFrame, inst.Size
		else
			return nil
		end
		local localOrigin = cf:PointToObjectSpace(origin)
		local localDir = cf:VectorToObjectSpace(direction)
		local half = size * 0.5
		local near, far = -math.huge, math.huge
		for _, axis in { "X", "Y", "Z" } do
			local o = (localOrigin :: any)[axis]
			local d = (localDir :: any)[axis]
			local h = (half :: any)[axis]
			if math.abs(d) < 1e-9 then
				if o < -h or o > h then
					return nil
				end
			else
				local t1 = (-h - o) / d
				local t2 = (h - o) / d
				if t1 > t2 then
					t1, t2 = t2, t1
				end
				near = math.max(near, t1)
				far = math.min(far, t2)
				if near > far then
					return nil
				end
			end
		end
		return if far < 0 then nil else math.max(near, 0)
	end

	--[[
		The depths that decide whether one object draws in front of another: measured along a ray
		through the centre of their screen overlap, which is the only place the comparison is
		visible. Returns nil when they do not overlap in frame -- they cannot occlude each other
		there, so there is nothing to order.
	]]
	local function overlapDepths(a: Instance, b: Instance): (number?, number?, Vector3?)
		local aLo, aHi, aOk = screenBox(a)
		local bLo, bHi, bOk = screenBox(b)
		if not aOk or not bOk then
			return nil, nil, nil
		end
		local lo = Vector2.new(math.max(aLo.X, bLo.X), math.max(aLo.Y, bLo.Y))
		local hi = Vector2.new(math.min(aHi.X, bHi.X), math.min(aHi.Y, bHi.Y))
		if lo.X > hi.X or lo.Y > hi.Y then
			return nil, nil, nil
		end
		--[[
			The centre of two overlapping bounding BOXES usually lies on neither object -- two thin
			bars crossing diagonally have boxes that overlap over a huge region and geometry that
			meets at a point. So the region is SAMPLED for a pixel that actually lands on both, and
			the one nearest the centre wins. Testing only the centre made the tool report "these do
			not overlap" for exactly the crossings a Penrose figure is made of.
		]]
		local best: (Vector2?) = nil
		local bestDistance = math.huge
		local bestA, bestB = 0, 0
		local bestDir = Vector3.zAxis
		local centre = (lo + hi) * 0.5
		local GRID = 6
		for ix = 0, GRID do
			for iy = 0, GRID do
				local at = Vector2.new(
					lo.X + (hi.X - lo.X) * (ix / GRID),
					lo.Y + (hi.Y - lo.Y) * (iy / GRID)
				)
				local ray = cam:ViewportPointToRay(at.X, at.Y)
				local da = rayEntry(a, ray.Origin, ray.Direction)
				local db = rayEntry(b, ray.Origin, ray.Direction)
				if da and db then
					local distance = (at - centre).Magnitude
					if distance < bestDistance then
						best, bestDistance = at, distance
						bestA, bestB = da, db
						bestDir = ray.Direction.Unit
					end
				end
			end
		end
		if not best then
			return nil, nil, nil
		end
		return bestA, bestB, bestDir
	end

	--[[ The direction to slide along so the thing being composed keeps its pixel: the ray from the
	     eye through the seam point, or through the model's centre when there is no seam. ]]
	local function slideAxis(target: Target): (Vector3, Vector3)
		local eye = cam:GetRenderCFrame().Position
		local seam = target.seams[1]
		local anchor = if seam then seam.node.WorldPosition else target.model:GetPivot().Position
		local dir = anchor - eye
		if dir.Magnitude < 1e-3 then
			return cam:GetRenderCFrame().LookVector, anchor
		end
		return dir.Unit, anchor
	end

	--[[
		How far apart the two points are IN THE PICTURE: the angle they subtend at the eye, and
		the same figure in pixels of the live viewport. Zero exactly when they are drawn on the
		same pixel -- which is the thing being composed.
	]]
	local function separation(seam: EditorSeam): (number, number)
		local camCF = cam:GetRenderCFrame()
		local deg = Seam.separationDeg(camCF.Position, seam.node.WorldPosition, seam.partner.WorldPosition)
		return deg, Seam.degToPixels(deg, cam.FieldOfView, cam.ViewportSize.Y)
	end

	--[[
		Distance from the eye to each end of the seam. The nearer one is the one drawn in front,
		because that is the only thing Roblox sorts on.
	]]
	local function depths(seam: EditorSeam): (number, number)
		local eye = cam:GetRenderCFrame().Position
		return (seam.node.WorldPosition - eye).Magnitude, (seam.partner.WorldPosition - eye).Magnitude
	end

	local function refreshStack(target: Target)
		local rule = constraints[target.model]
		local front = if rule then rule.front else nil
		local back = if rule then rule.back else nil

		if #references == 0 then
			stackOut.Text = "  (this demo lists nothing to order against)"
			orderOut.Text = ""
			return
		end

		local camCF = cam:GetRenderCFrame()
		local rows: { { name: string, lo: number, isRef: boolean, isMe: boolean, laps: boolean } } = {}
		for i, ref in references do
			local lo = depthRange(ref.instance, camCF)
			if lo ~= math.huge then
				--[[ Only pieces whose pixels actually meet the edited one can be ordered against it.
				     Saying so on the row is the difference between "this rule did nothing" and
				     understanding that there was no overlap to order in the first place. ]]
				local mine = overlapDepths(target.model, ref.instance)
				table.insert(rows, {
					name = ref.name,
					lo = lo,
					isRef = i == reference,
					isMe = ref.instance == target.model,
					laps = mine ~= nil,
				})
			end
		end
		table.sort(rows, function(x, y)
			return x.lo < y.lo
		end)

		local lines: { string } = {}
		for _, row in rows do
			local mark = if row.isRef then ">" else " "
			local tag
			if row.isMe then
				tag = "   <- editing this"
			elseif not row.laps then
				tag = "   (does not overlap it on screen — nothing to order)"
			elseif row.isRef then
				tag = "   <- the reference"
			else
				tag = ""
			end
			table.insert(lines, ("  %s %s%s"):format(mark, row.name, tag))
		end
		stackOut.Text = table.concat(lines, "\n")

		local chosen = references[reference]
		local refName = if chosen then chosen.name else "nothing"
		if front or back then
			orderOut.Text = ("  RULE: this piece must be%s%s%s        \\  clears the rule"):format(
				if front then ` in front of {front.name}` else "",
				if front and back then " and" else "",
				if back then ` behind {back.name}` else ""
			)
		else
			orderOut.Text = ("  HOME  put this in front of %s        ; '  pick another\n  END   put this behind %s"):format(
				refName,
				refName
			)
		end
	end

	local function refresh()
		local target = current()
		if not target then
			editingOut.Text = "nothing here can be edited"
			stackOut.Text = ""
			orderOut.Text = ""
			parkMarker(selectedMarker, nil)
			parkMarker(referenceMarker, nil)
			return
		end

		parkMarker(selectedMarker, target.model)
		local chosen = references[reference]
		parkMarker(referenceMarker, if chosen then chosen.instance else nil)

		local offset = moved[target.model] or Vector3.zero
		local lines: { string } = {}
		table.insert(lines, ("EDITING  %s          %d of %d    [ ]  picks another"):format(target.id, selected, #targets))

		local seam = target.seams[1]
		if seam then
			local _, px = separation(seam)
			table.insert(lines, ("  should look joined to  %s"):format(target.joinsTo))
			if px < 2 then
				table.insert(lines, "  they are on the same pixel from here — that join is done")
			else
				table.insert(lines, ("  they are %.0f px apart on screen        ENTER lines them up"):format(px))
			end
			local mine, theirs = depths(seam)
			local scale = if theirs > 1e-3 then math.abs(mine - theirs) / theirs * 100 else 0
			table.insert(
				lines,
				("  in front at the join: %s        crossing pops the avatar %.0f%%"):format(
					if mine < theirs then target.id else target.joinsTo,
					scale
				)
			)
		else
			table.insert(lines, "  this piece has no join to line up")
		end
		if offset.Magnitude > 1e-3 then
			table.insert(
				lines,
				("  moved so far  (%.1f, %.1f, %.1f)   step %.2f"):format(offset.X, offset.Y, offset.Z, STEPS[stepIndex])
			)
		else
			table.insert(lines, ("  not moved yet   step %.2f"):format(STEPS[stepIndex]))
		end
		editingOut.Text = table.concat(lines, "\n")

		refreshStack(target)
	end

	local function moveBy(delta: Vector3)
		local target = current()
		if not target then
			return
		end
		local apply = target.apply
		if apply then
			apply(delta)
		else
			target.model:PivotTo(target.model:GetPivot() + delta)
		end
		moved[target.model] = (moved[target.model] or Vector3.zero) + delta
		options.onChanged()
		refresh()
	end

	--[[
		Put this surface's seam point on the RAY from the eye through its partner, keeping its own
		distance from the eye. The two are then drawn on the same pixel exactly -- in the real
		projection, not an idealised one -- and the surface has moved as little as it can to get
		there.
	]]
	local function solve()
		local target = current()
		local seam = if target then target.seams[1] else nil
		if not target or not seam then
			return
		end
		local gate = options.canSolve
		if gate and not gate() then
			status.Text = "cannot solve from here -- the view is not settled"
			return
		end
		local eye = cam:GetRenderCFrame().Position
		local toPartner = seam.partner.WorldPosition - eye
		if toPartner.Magnitude < 1e-3 then
			return
		end
		local reach = (seam.node.WorldPosition - eye).Magnitude
		local wanted = eye + toPartner.Unit * reach
		moveBy(wanted - seam.node.WorldPosition)
	end

	--[[
		FLIP: mirror this surface to the other side of its partner along the eye ray, so whichever
		was in front now is not. The screen ray is unchanged, so the picture keeps its alignment;
		only the occlusion order and the apparent size change. That is the only lever there is --
		Roblox sorts by distance and nothing else.
	]]
	local function flipDepth()
		local target = current()
		local seam = if target then target.seams[1] else nil
		if not target or not seam then
			return
		end
		local gate = options.canSolve
		if gate and not gate() then
			status.Text = "cannot flip from here -- the view is not settled"
			return
		end
		local eye = cam:GetRenderCFrame().Position
		local toNode = seam.node.WorldPosition - eye
		local mine, theirs = depths(seam)
		if toNode.Magnitude < 1e-3 or theirs < 1e-3 then
			return
		end
		-- Mirrored across the partner's distance: same direction from the eye, other side of it.
		local wantedDistance = 2 * theirs - mine
		if wantedDistance < 5 then
			-- The mirror would land on top of the camera, or behind it. Refuse rather than fling
			-- the surface through the lens.
			status.Text = "cannot flip: the far side is behind the camera -- move it closer first"
			return
		end
		local wanted = eye + toNode.Unit * wantedDistance
		moveBy(wanted - seam.node.WorldPosition)
	end

	--[[
		Solve every ordering constraint at once, measured where each pair actually overlaps.

		For one constraint, sliding the target by t along its eye ray changes its entry depth at
		that pair's overlap ray by t * k, where k is how much of the slide points along that ray.
		So each constraint is a linear inequality in t, the set of them is an interval, and the
		move is the shortest one that lands inside it.

		Because every pair is measured at its OWN overlap, a cycle is expressible: A can be in
		front of B over here while the pole is in front of A over there. A z-buffer sorts pixels,
		not objects, so nothing about that is a trick -- it is just what the hardware already does.
	]]
	local MARGIN = 0.5

	local function applyOne(target: Target): (boolean, string?)
		local rule = constraints[target.model]
		if not rule or (not rule.front and not rule.back) then
			return true, nil
		end
		local dir = slideAxis(target)
		local lowest, highest = -math.huge, math.huge
		local blocked: string? = nil

		local function fold(ref: Reference?, inFront: boolean)
			if not ref or blocked then
				return
			end
			local mine, theirs, rayDir = overlapDepths(target.model, ref.instance)
			if not mine or not theirs or not rayDir then
				blocked = `{ref.name} does not overlap this on screen -- nothing to order`
				return
			end
			local k = dir:Dot(rayDir)
			if math.abs(k) < 1e-3 then
				blocked = `moving {target.id} does not change its depth against {ref.name} from here`
				return
			end
			-- entry depth after travelling t:  mine + t*k
			local limit = (theirs + (if inFront then -MARGIN else MARGIN) - mine) / k
			if (inFront and k > 0) or (not inFront and k < 0) then
				highest = math.min(highest, limit)
			else
				lowest = math.max(lowest, limit)
			end
		end

		fold(rule.front, true)
		fold(rule.back, false)
		if blocked then
			return false, blocked
		end
		if lowest > highest then
			return false, "it cannot be in front of one and behind the other from this angle"
		end
		local t = math.clamp(0, lowest, highest)
		if math.abs(t) > 1e-4 then
			moveBy(dir * t)
		end
		return true, nil
	end

	--[[
		Relaxation: moving one object changes what another's constraint is measured against, so the
		whole set is swept until it stops moving. A few passes is plenty for a handful of objects,
		and failing to settle is itself the answer -- it means the arrangement is not renderable
		and the author needs to move something else.
	]]
	local function solveAll(): (boolean, string?)
		local problem: string? = nil
		for _ = 1, 6 do
			for _, target in targets do
				local ok, why = applyOne(target)
				if not ok then
					problem = why
				end
			end
		end
		return problem == nil, problem
	end

	local function order(inFront: boolean)
		local target = current()
		local ref = references[reference]
		if not target or not ref then
			return
		end
		local gate = options.canSolve
		if gate and not gate() then
			status.Text = "cannot reorder from here -- the view is not settled"
			return
		end
		local rule: Rule = constraints[target.model] or {}
		if inFront then
			rule.front = ref
		else
			rule.back = ref
		end
		constraints[target.model] = rule

		local ok, why = solveAll()
		status.Text = if ok
			then ("ordered: %s"):format(if inFront then `in front of {ref.name}` else `behind {ref.name}`)
			else `cannot: {why}`
		refresh()
	end

	local function undo()
		local target = current()
		if not target then
			return
		end
		local offset = moved[target.model]
		if offset then
			moveBy(-offset)
			moved[target.model] = nil
			refresh()
		end
	end

	local function printExport()
		print("---- map edits ----")
		local any = false
		local done: { [Model]: boolean } = {}
		for _, target in targets do
			local offset = moved[target.model]
			if offset and offset.Magnitude > 1e-4 and not done[target.model] then
				done[target.model] = true
				any = true
				print(("-- %s moved by (%.2f, %.2f, %.2f)"):format(target.id, offset.X, offset.Y, offset.Z))
				for _, line in target.export(offset) do
					print("   " .. line)
				end
			end
		end
		if not any then
			print("-- nothing moved yet")
		end
		print("-------------------")
	end

	local connections: { RBXScriptConnection } = {}

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed or not open then
				return
			end
			local code = input.KeyCode
			local camCF = cam:GetRenderCFrame()
			local step = STEPS[stepIndex]

			if code == Enum.KeyCode.LeftBracket then
				selected = ((selected - 2) % math.max(#targets, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.RightBracket then
				selected = (selected % math.max(#targets, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.Minus then
				stepIndex = math.max(stepIndex - 1, 1)
				refresh()
			elseif code == Enum.KeyCode.Equals then
				stepIndex = math.min(stepIndex + 1, #STEPS)
				refresh()
			elseif code == Enum.KeyCode.Left then
				moveBy(-camCF.RightVector * step)
			elseif code == Enum.KeyCode.Right then
				moveBy(camCF.RightVector * step)
			elseif code == Enum.KeyCode.Up then
				moveBy(camCF.UpVector * step)
			elseif code == Enum.KeyCode.Down then
				moveBy(-camCF.UpVector * step)
			elseif code == Enum.KeyCode.PageUp then
				-- Along the view axis: free under a parallel projection, and the readout proves it.
				moveBy(camCF.LookVector * step)
			elseif code == Enum.KeyCode.PageDown then
				moveBy(-camCF.LookVector * step)
			elseif code == Enum.KeyCode.Return then
				solve()
			elseif code == Enum.KeyCode.Z then
				flipDepth()
			elseif code == Enum.KeyCode.Semicolon then
				reference = ((reference - 2) % math.max(#references, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.Quote then
				reference = (reference % math.max(#references, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.Home then
				order(true)
			elseif code == Enum.KeyCode.End then
				order(false)
			elseif code == Enum.KeyCode.BackSlash then
				local target = current()
				if target then
					constraints[target.model] = nil
					status.Text = "constraints cleared"
					refresh()
				end
			elseif code == Enum.KeyCode.Backspace then
				undo()
			elseif code == Enum.KeyCode.P then
				printExport()
			end
		end)
	)

	local handle: Handle = {
		toggle = function()
			open = not open
			gui.Enabled = open
			if open then
				if options.onOpen then
					options.onOpen()
				end
				refresh()
				print("[editor] open — ARROWS move on screen, ENTER solves, P prints the edits")
			else
				-- The markers live in the world, so they have to go when the panel does.
				parkMarker(selectedMarker, nil)
				parkMarker(referenceMarker, nil)
				if options.onClose then
					options.onClose()
				end
			end
		end,

		isOpen = function(): boolean
			return open
		end,

		step = function(_dt: number)
			if open then
				refresh()
			end
		end,

		destroy = function()
			for _, c in connections do
				c:Disconnect()
			end
			table.clear(connections)
			selectedMarker:Destroy()
			referenceMarker:Destroy()
			gui:Destroy()
		end,
	}
	return handle
end

return Editor
