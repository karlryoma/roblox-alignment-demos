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

	WHAT THE AUTHOR EDITS IS STATEMENTS, AND STATEMENTS DO NOT EXPIRE. Two kinds: a JOIN ("these
	two ends should meet") and an ORDER ("this should be above these, under those"). Both are
	re-established by a sweep after EVERY later change, so a composition accumulates instead of
	coming apart as soon as the next piece moves.

	ORDER IS STATED PER PIECE, NOT PER PAIR, and lives in two attributes ON the piece --
	AlignInFrontOf and AlignBehind, each a comma-separated list of piece names. One key per listed
	piece cycles it: in front -> behind -> don't care. There is no pair cursor and nothing to
	navigate, and because the field belongs to the Instance, Studio's Properties window is an
	equally good way in.

	That is the lesson from Monument Valley, whose team built the hand-maintained version of this
	first: "as soon as you wanted to modify that or iterate on it, you'd have to do it all over
	again." Their fix was to derive the order from camera depth automatically -- and they credit
	that automation with making levels easy to build at all. So the order every pair currently
	reads is DERIVED from the live camera and shown; pins are only for the pairs that read wrong.

	The two statement kinds are nearly orthogonal, which is why the sweep settles: a join is
	satisfied by moving ACROSS the eye ray, a pin by moving ALONG it. Pins are per PAIR and a
	surface carries as many as it likes, so "in front of the pole but behind that platform" is one
	solve -- each pin an interval of allowed travel along the eye ray, all intersected, and the
	surface moved the shortest distance into the result.

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
	--[[ PVInstance, not Model: the occluder poles are single BaseParts and they must be movable
	     too. A rule the author cannot satisfy by moving the piece it names is a dead end -- and
	     "put the walkway behind that one but in front of the pole" is often only reachable by
	     moving the pole. Everything here needs is GetPivot/PivotTo, which both classes have. ]]
	model: PVInstance,
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

--[[ One key per listed piece. A table rather than arithmetic on KeyCode.Value, so the mapping is
     visible and cannot drift if Roblox ever renumbers anything. ]]
local DIGITS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
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
	local moved: { [PVInstance]: Vector3 } = {}

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
	stackTitle.Text = "THIS PIECE SHOULD BE"
	local stackOut = label(132, 12, DIM)
	-- Five rows: demo 3 lists six pieces and one of them is always the piece being edited.
	stackOut.Size = UDim2.fromOffset(470, 72)
	stackOut.TextYAlignment = Enum.TextYAlignment.Top

	local orderOut = label(206, 12, DIM)
	orderOut.Size = UDim2.fromOffset(470, 34)
	orderOut.TextYAlignment = Enum.TextYAlignment.Top

	local status = label(244, 13, GOOD)
	status.Size = UDim2.fromOffset(470, 18)

	--[[ A refusal printed in the success colour reads as success at a glance -- which is exactly
	     what happened when the solver started reporting conflicts. Outcome picks the colour. ]]
	local function say(text: string, good: boolean)
		status.Text = text
		status.TextColor3 = if good then GOOD else WARN
	end

	local help = label(268, 12, DIM)
	help.Size = UDim2.fromOffset(470, 60)
	help.TextYAlignment = Enum.TextYAlignment.Top
	help.Text = table.concat({
		"ORDER  1-9  cycle a piece        \\  clear this piece",
		"JOIN   ENTER  join these ends and KEEP them joined     Z  swap which side is in front",
		"MOVE   arrows  across the screen    K / I  depth    -  =  step    [ ]  another piece",
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

	--[[
		ORDERING IS DERIVED; THE AUTHOR ONLY STATES THE EXCEPTIONS.

		An earlier version had the author declare "in front of X" and "behind Y" -- one of each,
		per surface -- and re-solved only when a rule itself changed. Every later nudge silently
		invalidated the rules already set, so composing a shot meant re-stating them after every
		move. ustwo hit exactly this on Monument Valley and threw the hand-authored version away:
		they derived the order from camera depth instead, and said the automation was what made
		levels easy to build.

		So the true order is read off the live camera and shown, the author PINS only the pairs
		that read the wrong way round, and every pin is re-established after every change. A pin
		is per PAIR and a surface may carry any number of them -- which is what lets a CYCLE be
		expressed at all.
	]]
	type Pin = { other: Reference, inFront: boolean }
	local pins: { [PVInstance]: { Pin } } = {}

	--[[
		WHERE THE ORDERING ACTUALLY LIVES: two attributes on the piece itself, each a plain
		comma-separated list of piece names.

		    AlignInFrontOf = "high walkway, pole under the goal"
		    AlignBehind    = "goal walkway"

		That is the whole model -- per piece, what it should be above and what it should be under.
		Nothing is stated pair-by-pair and there is no cursor to drive.

		Attributes rather than a table in this module because they are the same data seen from both
		sides: the panel below writes them, and Roblox Studio's Properties window edits them
		directly, with the game stopped, saving into the place file. So this is already the Studio
		integration -- the in-game panel is a convenience over it, not the only way in.
	]]
	--[[ The amber marker has no cursor to follow any more, so it sits on whatever the author
	     last changed -- which is the piece they are thinking about. ]]
	local lastTouched: Instance? = nil

	local ATTR_FRONT = "AlignInFrontOf"
	local ATTR_BACK = "AlignBehind"

	--[[ Which of a piece's rules could not be honoured on the last sweep, so its row can say so
	     instead of leaving the author to work out why nothing moved. ]]
	local conflicts: { [PVInstance]: { [Instance]: boolean } } = {}

	local function refByName(name: string): Reference?
		for _, ref in references do
			if ref.name == name then
				return ref
			end
		end
		return nil
	end

	--[[ Names that match nothing are skipped rather than treated as an error: this field is meant
	     to be typed by hand in Studio, where a half-finished list is a normal thing to look at. ]]
	local function parseList(raw: any, inFront: boolean, out: { Pin })
		if typeof(raw) ~= "string" then
			return
		end
		for piece in string.gmatch(raw, "[^,]+") do
			local name = string.match(piece, "^%s*(.-)%s*$")
			local ref = if name then refByName(name) else nil
			if ref then
				table.insert(out, { other = ref, inFront = inFront })
			end
		end
	end

	local function syncPins()
		table.clear(pins)
		for _, target in targets do
			local list: { Pin } = {}
			parseList(target.model:GetAttribute(ATTR_FRONT), true, list)
			parseList(target.model:GetAttribute(ATTR_BACK), false, list)
			if #list > 0 then
				pins[target.model] = list
			end
		end
	end

	local function writePins(model: PVInstance, list: { Pin })
		local front: { string } = {}
		local back: { string } = {}
		for _, pin in list do
			table.insert(if pin.inFront then front else back, pin.other.name)
		end
		model:SetAttribute(ATTR_FRONT, table.concat(front, ", "))
		model:SetAttribute(ATTR_BACK, table.concat(back, ", "))
	end

	--[[ Seams the author has declared finished. A locked seam is re-solved after every later
	     change, so joins accumulate instead of taking turns breaking one another. ]]
	local locked: { [string]: boolean } = {}

	--[[ Assigned once the solver below exists. Declared here because moveBy, which sits above it,
	     has to trigger a sweep after every hand nudge. ]]
	local runSolver: (() -> (boolean, string?))? = nil

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

	--[[ Move a target without triggering a sweep: the primitive every automatic pass is built
	     from. moveBy is the authored version and reconciles afterwards. ]]
	local function applyDelta(target: Target, delta: Vector3)
		if delta.Magnitude < 1e-6 then
			return
		end
		local apply = target.apply
		if apply then
			apply(delta)
		else
			target.model:PivotTo(target.model:GetPivot() + delta)
		end
		moved[target.model] = (moved[target.model] or Vector3.zero) + delta
	end

	--[[ Put this seam's node on the ray from the eye through its partner, keeping its own distance
	     from the eye, so the two are drawn on the same pixel. This only ever moves the piece
	     ACROSS the eye ray -- depth is untouched -- which is precisely why it composes with the
	     depth pins instead of fighting them. ]]
	local function solveSeamRaw(target: Target, seam: EditorSeam): boolean
		local eye = cam:GetRenderCFrame().Position
		local toPartner = seam.partner.WorldPosition - eye
		if toPartner.Magnitude < 1e-3 then
			return false
		end
		local reach = (seam.node.WorldPosition - eye).Magnitude
		applyDelta(target, (eye + toPartner.Unit * reach) - seam.node.WorldPosition)
		return true
	end

	type Row = { ref: Reference, overlaps: boolean, inFront: boolean, declared: string?, clashes: boolean }

	--[[ Every other piece, with what the author has DECLARED about it and how it currently READS.
	     Non-overlapping pieces stay in the list -- the author is stating an intention, and a pair
	     that does not share pixels yet may well do so once something moves. ]]
	local function rowsFor(target: Target): { Row }
		local out: { Row } = {}
		local list = pins[target.model]
		local clash = conflicts[target.model]
		for _, ref in references do
			if ref.instance == target.model then
				continue
			end
			local mine, theirs = overlapDepths(target.model, ref.instance)
			local declared: string? = nil
			if list then
				for _, pin in list do
					if pin.other.instance == ref.instance then
						declared = if pin.inFront then "front" else "back"
					end
				end
			end
			local inFront = false
			if mine and theirs then
				inFront = mine < theirs
			end
			table.insert(out, {
				ref = ref,
				overlaps = mine ~= nil and theirs ~= nil,
				inFront = inFront,
				declared = declared,
				clashes = clash ~= nil and clash[ref.instance] == true,
			})
		end
		return out
	end

	local function refreshStack(target: Target, rows: { Row })
		if #rows == 0 then
			stackOut.Text = "  nothing else here to order against"
			orderOut.Text = ""
			return
		end

		local lines: { string } = {}
		for i, row in rows do
			local says = if row.declared == "front"
				then "IN FRONT OF"
				elseif row.declared == "back" then "BEHIND     "
				else "--         "
			--[[ What it says next to what it does. A declaration that has not taken effect is the
			     thing the author most needs to see, and it is one glance rather than a query. ]]
			local reads
			if not row.overlaps then
				reads = "no overlap yet"
			elseif row.declared == nil then
				reads = if row.inFront then "(in front)" else "(behind)"
			elseif row.clashes then
				reads = "CLASHES - ignored"
			elseif (row.declared == "front") == row.inFront then
				reads = "ok"
			else
				reads = "NOT YET"
			end
			table.insert(lines, ("  %d %s %-28s %s"):format(i, says, row.ref.name, reads))
		end
		stackOut.Text = table.concat(lines, "\n")
		orderOut.Text = ("  press 1-%d to cycle a piece:  in front  ->  behind  ->  don't care\n  \\  clears every rule on %s"):format(
			#rows,
			target.id
		)
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
		-- Scanned once per frame and shared with refreshStack below; it is the costly part here.
		local rows = rowsFor(target)
		parkMarker(referenceMarker, lastTouched)

		local offset = moved[target.model] or Vector3.zero
		local lines: { string } = {}
		table.insert(lines, ("EDITING  %s          %d of %d    [ ]  picks another"):format(target.id, selected, #targets))

		local seam = target.seams[1]
		if seam then
			local _, px = separation(seam)
			table.insert(lines, ("  should look joined to  %s"):format(target.joinsTo))
			if locked[seam.label] then
				table.insert(lines, ("  JOINED and held (%.0f px)        ENTER releases it"):format(px))
			elseif px < 2 then
				table.insert(lines, "  on the same pixel        ENTER joins them for good")
			else
				table.insert(lines, ("  %.0f px apart on screen        ENTER joins them"):format(px))
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

		refreshStack(target, rows)
	end

	local function moveBy(delta: Vector3)
		local target = current()
		if not target then
			return
		end
		applyDelta(target, delta)
		--[[ A hand nudge is the author overruling the solver, so the join this piece was holding
		     is released rather than snapped straight back on the next sweep. ENTER re-locks it. ]]
		local seam = target.seams[1]
		if seam and locked[seam.label] then
			locked[seam.label] = nil
			say("moved by hand -- join released, ENTER re-locks it", true)
		end
		if runSolver then
			runSolver()
		else
			options.onChanged()
		end
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
			say("cannot solve from here -- the view is not settled", false)
			return
		end
		if locked[seam.label] then
			locked[seam.label] = nil
			say(`join to {target.joinsTo} released -- it will drift again`, true)
			refresh()
			return
		end
		--[[ Declaring the join, not performing it once. The sweep holds it from here on, so later
		     work on other pieces cannot quietly pull this one apart again. ]]
		locked[seam.label] = true
		local ok: boolean = true
		local why: string? = nil
		if runSolver then
			ok, why = runSolver()
		end
		say(if ok then `joined to {target.joinsTo} -- it will stay joined` else `joined, but: {why}`, ok)
		refresh()
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
			say("cannot flip from here -- the view is not settled", false)
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
			say("cannot flip: the far side is behind the camera -- move it closer first", false)
			return
		end
		local wanted = eye + toNode.Unit * wantedDistance
		moveBy(wanted - seam.node.WorldPosition)
	end

	--[[
		Satisfy every pin at once, each measured where its pair actually overlaps.

		For one pin, sliding the target by t along its eye ray changes its entry depth at that
		pair's overlap ray by t * k, where k is how much of the slide points along that ray. So
		each pin is a linear inequality in t, the set of them is an interval, and the move is the
		shortest one that lands inside it. A surface carries a LIST of pins, not one front and one
		back, so "in front of the pole but behind that platform" is a single solve.

		Because every pair is measured at its OWN overlap, a cycle is expressible: A can be in
		front of B over here while the pole is in front of A over there. A z-buffer sorts pixels,
		not objects, so nothing about that is a trick -- it is what the hardware already does.
	]]
	local MARGIN = 0.5

	local function applyOne(target: Target): (boolean, string?)
		local list = pins[target.model]
		conflicts[target.model] = nil
		if not list or #list == 0 then
			return true, nil
		end
		local dir = slideAxis(target)
		local lowest, highest = -math.huge, math.huge
		local blocked: string? = nil
		local dropped: { string } = {}
		local clash: { [Instance]: boolean } = {}

		for _, pin in list do
			local mine, theirs, rayDir = overlapDepths(target.model, pin.other.instance)
			if not mine or not theirs or not rayDir then
				-- Nothing shares pixels here yet, so there is nothing to enforce. Skipped rather
				-- than failed: the author declared an intention, not a claim about right now.
				continue
			end
			local k = dir:Dot(rayDir)
			if math.abs(k) < 1e-3 then
				blocked = `moving {target.id} does not change its depth against {pin.other.name} from here`
				break
			end
			-- entry depth after travelling t:  mine + t*k
			local limit = (theirs + (if pin.inFront then -MARGIN else MARGIN) - mine) / k
			--[[ Fold this rule in only if it leaves somewhere to stand. One that empties the
			     interval is DROPPED AND NAMED, so the piece still moves as far as its other rules
			     allow. Refusing to move at all and reporting "cannot satisfy all of its pins" left
			     the author with a piece that had not budged and no idea which rule was at fault. ]]
			local lo, hi = lowest, highest
			if (pin.inFront and k > 0) or (not pin.inFront and k < 0) then
				hi = math.min(highest, limit)
			else
				lo = math.max(lowest, limit)
			end
			if lo > hi then
				table.insert(
					dropped,
					if pin.inFront then `in front of {pin.other.name}` else `behind {pin.other.name}`
				)
				clash[pin.other.instance] = true
			else
				lowest, highest = lo, hi
			end
		end

		if blocked then
			return false, blocked
		end
		local t = math.clamp(0, lowest, highest)
		if math.abs(t) > 1e-4 then
			applyDelta(target, dir * t)
		end
		if #dropped > 0 then
			conflicts[target.model] = clash
			return false, `{target.id} cannot also be {table.concat(dropped, " and ")} from here -- ignoring that`
		end
		return true, nil
	end

	--[[
		EVERYTHING THE AUTHOR HAS DECLARED, RE-ESTABLISHED AFTER EVERY CHANGE. This is the point
		of the whole design: statements accumulate instead of quietly expiring the moment anything
		moves.

		The two kinds of statement are very nearly orthogonal -- a locked seam is satisfied by
		moving ACROSS the eye ray (screen position), a pin by moving ALONG it (depth) -- so
		sweeping them alternately converges in a couple of passes rather than fighting. It is a
		sweep and not a single pass because moving one piece changes what another pin measures
		against.

		Failing to settle is itself the answer: the arrangement is not renderable from here, and
		something the author has not pinned needs to move.
	]]
	local function reconcile(): (boolean, string?)
		local problem: string? = nil
		for _ = 1, 4 do
			for _, target in targets do
				local seam = target.seams[1]
				if seam and locked[seam.label] then
					solveSeamRaw(target, seam)
				end
			end
			problem = nil
			for _, target in targets do
				local ok, why = applyOne(target)
				if not ok then
					problem = why
				end
			end
		end
		options.onChanged()
		return problem == nil, problem
	end
	runSolver = reconcile

	--[[ One key per piece: in front -> behind -> don't care. The result is written straight to the
	     model's attributes, so the in-game panel and Studio's Properties window are editing the
	     same field. ]]
	local function cycleRelation(index: number)
		local target = current()
		if not target then
			return
		end
		local gate = options.canSolve
		if gate and not gate() then
			say("cannot reorder from here -- the view is not settled", false)
			return
		end
		local rows = rowsFor(target)
		local row = rows[index]
		if not row then
			return
		end

		local kept: { Pin } = {}
		local existing = pins[target.model]
		if existing then
			for _, pin in existing do
				if pin.other.instance ~= row.ref.instance then
					table.insert(kept, pin)
				end
			end
		end
		local nextState: string? = if row.declared == nil
			then "front"
			elseif row.declared == "front" then "back"
			else nil
		if nextState then
			table.insert(kept, { other = row.ref, inFront = nextState == "front" })
		end

		writePins(target.model, kept)
		syncPins()
		lastTouched = row.ref.instance

		local ok, why = reconcile()
		local said = if nextState == "front"
			then `in front of {row.ref.name}`
			elseif nextState == "back" then `behind {row.ref.name}`
			else `no longer ordered against {row.ref.name}`
		say(if ok then `{target.id} is {said}` else `{why}`, ok)
		refresh()
	end

	local function undo()
		local target = current()
		if not target then
			return
		end
		local offset = moved[target.model]
		if offset then
			--[[ Drop what the author declared about this piece BEFORE moving it back. A locked
			     join or a pin would otherwise be re-established by the sweep inside moveBy and
			     put the piece straight back where it was, which reads as "undo does nothing". ]]
			local seam = target.seams[1]
			if seam then
				locked[seam.label] = nil
			end
			target.model:SetAttribute(ATTR_FRONT, "")
			target.model:SetAttribute(ATTR_BACK, "")
			syncPins()
			moveBy(-offset)
			moved[target.model] = nil
			say(`{target.id} put back -- its join and pins were released`, true)
			refresh()
		end
	end

	local function printExport()
		print("---- map edits ----")
		local any = false
		local done: { [PVInstance]: boolean } = {}
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
			elseif code == Enum.KeyCode.I then
				--[[ Along the view axis: free under a parallel projection, and the readout proves it.
				     I/K, not PageUp/PageDown -- Studio claims those for the Explorer and yanks focus
				     out of the play view before the game ever sees the key. Same reason as F2. ]]
				moveBy(camCF.LookVector * step)
			elseif code == Enum.KeyCode.K then
				moveBy(-camCF.LookVector * step)
			elseif code == Enum.KeyCode.Return then
				solve()
			elseif code == Enum.KeyCode.Z then
				flipDepth()
			elseif DIGITS[code] then
				cycleRelation(DIGITS[code])
			elseif code == Enum.KeyCode.BackSlash then
				local target = current()
				if target then
					-- Clear the whole piece: both attributes, one key.
					target.model:SetAttribute(ATTR_FRONT, "")
					target.model:SetAttribute(ATTR_BACK, "")
					syncPins()
					reconcile()
					say(`cleared every rule on {target.id}`, true)
					refresh()
				end
			elseif code == Enum.KeyCode.Backspace then
				undo()
			elseif code == Enum.KeyCode.P then
				printExport()
			end
		end)
	)

	--[[ Attributes are the source of truth, so start from whatever the place file already carries
	     -- including anything typed into Studio's Properties window with the game stopped. ]]
	syncPins()

	--[[ ...and keep following them. Editing AlignInFrontOf in Studio while the demo runs re-solves
	     the shot immediately, which is the whole point of keeping this in a field Studio owns. ]]
	do
		local seen: { [PVInstance]: boolean } = {}
		for _, target in targets do
			if seen[target.model] then
				continue
			end
			seen[target.model] = true
			for _, attr in { ATTR_FRONT, ATTR_BACK } do
				table.insert(
					connections,
					target.model:GetAttributeChangedSignal(attr):Connect(function()
						syncPins()
						if open then
							reconcile()
							refresh()
						end
					end)
				)
			end
		end
	end

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
