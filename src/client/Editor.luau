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

local Players = game:GetService("Players")
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
	--[[ Whether any piece currently carries a tilt. A demo's "faces no longer oppose" hint must
	     only blame a tilt when one exists -- the authored maps have pairs that coincide at some
	     angles with faces ninety degrees apart, and those are nobody's mistake. ]]
	hasTiltWork: () -> boolean,
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
-- Degrees per tilt press, sharing the same coarse/fine index as STEPS.
local TILT_STEPS = { 0.1, 0.25, 0.5, 1, 2 }
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
	-- Total turn applied to a piece, for the readout and the export note.
	local tilted: { [PVInstance]: number } = {}
	--[[ The pose a piece held before the author first touched it. Undo restores this directly:
	     translating by -offset cannot take a TILT back, so undo used to leave a piece rotated. ]]
	local homeCF: { [PVInstance]: CFrame } = {}
	--[[ Notes from the last sweep worth saying out loud -- currently: which pieces a shortfall
	     was delegated to. Success with a side effect, not a failure. Deduplicated: the sweep runs
	     four rounds and a repeating delegation must not stack four copies of itself. ]]
	local sweepNotes: { string } = {}
	local function note(text: string)
		if not table.find(sweepNotes, text) then
			table.insert(sweepNotes, text)
		end
	end
	--[[ |u| of each pin's last delegation THIS reconcile. A re-firing whose ask has not shrunk is
	     ping-pong -- the other piece's own rules pushed it straight back -- and firing again would
	     move geometry every round while reporting nothing. ]]
	local delegateHistory: { [Pin]: number } = {}
	--[[ What the status line should append when the sweep moved a piece the author did not
	     select. Every reconcile caller surfaces this; silence was how a stale note ended up
	     voiced against the WRONG action. ]]
	local function notesSuffix(): string
		if #sweepNotes == 0 then
			return ""
		end
		local extra = if #sweepNotes > 1 then ` (+{#sweepNotes - 1} more)` else ""
		return ` -- {sweepNotes[1]}{extra}`
	end

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
		"ORDER  1-9  cycle a piece     \\  clear this piece     G / H  TILT     C  compose from here",
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
	--[[
		THE COMPOSITION VIEWPOINT -- and why editing is refused without it.

		An alignment means nothing except from the angle it was composed at, and EVERY measurement
		this tool makes is taken from the camera: which pieces overlap, which is in front, which way
		a piece must slide to change that. So if the author orbits away to inspect and then edits,
		the solver dutifully re-establishes every rule FOR THE ANGLE THEY DRIFTED TO and drags the
		geometry somewhere that means nothing from where the shot is actually framed.

		That is not a subtle effect. Demo 3 orbits freely, and a rule re-solved from ninety degrees
		away moves a piece along a completely different eye ray -- which reads, correctly, as "the
		platforms physically moved quite a lot".

		So the viewpoint is captured when the editor opens, every path that can move geometry is
		refused while the live camera has drifted from it, and C re-captures it when the author
		genuinely means to compose from somewhere else.
	]]
	local composeCF: CFrame? = nil
	local COMPOSE_DOT = math.cos(math.rad(0.5))

	local function atComposeView(): boolean
		local held = composeCF
		if not held then
			return true
		end
		--[[ Direction, and only the displacement ACROSS the view. Both demos refit the camera
		     standoff after every edit (onChanged -> fitDistance), which moves the eye 3-12 studs
		     ALONG the view ray -- and motion along the ray does not change the composition under
		     these near-parallel projections (the header says exactly this). A raw position test
		     tripped on that refit, so the tool refused the very next keypress after every nudge
		     and had to be un-stuck with C each time. ]]
		local live = cam:GetRenderCFrame()
		local delta = live.Position - held.Position
		local across = delta - held.LookVector * delta:Dot(held.LookVector)
		if across.Magnitude > 2 then
			return false
		end
		return live.LookVector:Dot(held.LookVector) >= COMPOSE_DOT
	end

	--[[ One answer for every path that moves geometry, so a new one cannot be added without a
	     gate by accident -- which is exactly how moveBy and the tilt keys came to be ungated. ]]
	local function canEdit(): (boolean, string?)
		if not atComposeView() then
			return false, "the view has drifted from the composition -- C composes from here"
		end
		local gate = options.canSolve
		if gate and not gate() then
			return false, "the view is not settled"
		end
		return true, nil
	end

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

	--[[
		Seams the author has declared finished. A locked seam is re-solved after every later
		change, so joins accumulate instead of taking turns breaking one another.

		EACH LOCK REMEMBERS THE VIEW IT WAS COMPOSED AT. These levels are DESIGNED around seams
		that coincide from DIFFERENT views (demo 3: yaw 45 vs yaw 135; demo 4: different
		camera/rotor states), so re-solving every lock from the live camera -- what this used to
		do -- forced them all onto ONE eye ray: composing the second seam physically dragged the
		first walkway ~20 studs to align from the new angle. That was the single largest source of
		"the alignment is very off".

		partnerBase + partnerMovedBase let the join FOLLOW the partner when the author later moves
		it (the moved[] delta since lock time), while ignoring motion the editor did not do --
		demo 4's rotor swinging between states must not drag a slab composed at the other state.
	]]
	--[[ BOTH ends are stored as compose-time bases plus author-moved deltas. The first version
	     shielded only the partner side, and the rotor -- a lockable TARGET whose own nodes swing
	     ~8.5 studs between states -- got its home dragged by the sweep after every F flip: the
	     live node position was solved onto the stored ray as if the swing were an author edit. ]]
	type Lock = {
		eye: Vector3,
		nodeBase: Vector3,
		nodeMovedBase: Vector3,
		partnerBase: Vector3,
		partnerModel: Model?,
		partnerMovedBase: Vector3,
	}
	local locked: { [string]: Lock } = {}

	--[[ Anything the author has actually declared. Until there is some, there is no composition
	     to protect. ]]
	local function hasWork(): boolean
		return next(locked) ~= nil or next(pins) ~= nil or next(moved) ~= nil
	end


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
	local function overlapDepths(a: Instance, b: Instance, wantAInFront: boolean?): (number?, number?, Vector3?)
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
		--[[ WHICH ray of the overlap to measure is a semantic choice, and it took three tries:
		     nearest-to-centre sampled the knife edge where a seam pair's depths converge (panel
		     and solver could sample different rays and contradict each other), and max-|diff|
		     flipped between OPPOSITE-sign extremes under a hundredth of a degree of camera drift
		     -- the same keypress slid a piece six studs or did nothing depending on invisible
		     camera phase -- while a declaration the dominant end already satisfied hid every
		     violation on the minority side, by construction.

		     So the caller states a direction. For a declared rule, measure the ray that most
		     VIOLATES it (max signed da-db for "a in front", the mirror for "behind"): a slide
		     shifts every ray's depth equally, so satisfying the rule at its worst ray satisfies
		     it at every sampled ray -- the invariant max-|diff| only pretended to have. Display
		     of a declared rule reads the same worst ray, so the row and the solver cannot
		     disagree; and a directional extreme never flips ends, only jitters locally. With no
		     direction (undeclared rows) the dominant order is informational: max |diff|. ]]
		local found = false
		local bestScore = -math.huge
		local bestA, bestB = 0, 0
		local bestDir = Vector3.zAxis
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
					local score = if wantAInFront == nil
						then math.abs(da - db)
						elseif wantAInFront then da - db
						else db - da
					if score > bestScore then
						found, bestScore = true, score
						bestA, bestB = da, db
						bestDir = ray.Direction.Unit
					end
				end
			end
		end
		if not found then
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

	--[[ Whether the local player's avatar is standing on this piece: same bounding-box test the
	     demos use. The editor moves geometry by teleporting it, and the avatar does not come
	     along for free -- the solver once slid the start walkway 16 studs and left the author's
	     frozen avatar hanging in the air, to drop onto the pole below mid-composition. ]]
	local function playerStandsOn(inst: PVInstance): boolean
		local character = Players.LocalPlayer.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if not root or not root:IsA("BasePart") then
			return false
		end
		--[[ A raycast straight down, not a bounding-box test: the demos stack pieces (a pole's
		     top sits one stud under the walkway's deck), and a box-with-margins test called the
		     avatar "standing on" the pole below the walkway it was really on -- so a sweep moving
		     the pole dragged an avatar that was not on it. What the first ray down hits IS the
		     floor underfoot, ambiguity-free. ]]
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character :: Instance }
		local hit = workspace:Raycast(root.Position, Vector3.new(0, -10, 0), params)
		if not hit then
			return false
		end
		return hit.Instance == inst or hit.Instance:IsDescendantOf(inst)
	end

	--[[ Move a target without triggering a sweep: the primitive every automatic pass is built
	     from. moveBy is the authored version and reconciles afterwards. ]]
	local function applyDelta(target: Target, delta: Vector3)
		if delta.Magnitude < 1e-6 then
			return
		end
		if not homeCF[target.model] then
			homeCF[target.model] = target.model:GetPivot()
		end
		-- Checked BEFORE the piece moves, or the box has already left the avatar behind.
		local carry = playerStandsOn(target.model)
		local apply = target.apply
		if apply then
			apply(delta)
		else
			target.model:PivotTo(target.model:GetPivot() + delta)
		end
		if carry then
			local character = Players.LocalPlayer.Character
			if character then
				character:PivotTo(character:GetPivot() + delta)
			end
		end
		moved[target.model] = (moved[target.model] or Vector3.zero) + delta
	end

	--[[
		TILT: turn the piece about an axis through its seam node, so the node -- and therefore the
		join -- does not move at all while the rest of the piece swings.

		THIS IS THE DEGREE OF FREEDOM THE ILLUSION ACTUALLY NEEDS, and sliding does not have it.
		A rigid slide shifts every part of a piece by the same depth, so it cannot change how much
		NEARER the piece is at one overlap than at another -- and that difference is the whole
		trick. Only turning it can. The depth spread a tilt buys is the angle times how far apart
		the two overlaps sit on screen, which is why a Penrose triangle is built out of beams that
		are TURNED rather than merely placed.

		Because the node is the pivot, a tilt cannot break a join -- so unlike a hand nudge it does
		not release one.
	]]
	local function applyTilt(target: Target, radians: number): boolean
		if target.apply then
			--[[ Demo 4's rotor re-issues its pose from a stored home every frame, and that hook
			     only accepts a translation. A turn would be erased before the next frame. ]]
			return false
		end
		local seam = target.seams[1]
		local anchor = if seam then seam.node.WorldPosition else target.model:GetPivot().Position
		if not homeCF[target.model] then
			homeCF[target.model] = target.model:GetPivot()
		end
		local carry = playerStandsOn(target.model)
		local before = target.model:GetPivot()
		local turn = CFrame.fromAxisAngle(cam:GetRenderCFrame().UpVector, radians)
		local motion = CFrame.new(anchor) * turn * CFrame.new(-anchor)
		local after = motion * before
		target.model:PivotTo(after)
		if carry then
			-- The same rigid motion the floor made, not just its translation: an avatar at the
			-- slab's far end swings with it instead of being left off the edge press by press.
			local character = Players.LocalPlayer.Character
			if character then
				character:PivotTo(motion * character:GetPivot())
			end
		end
		--[[ Turning about a point away from the pivot DISPLACES the pivot too. The position export
		     has to see that, or the printed numbers will not reproduce the shot. ]]
		moved[target.model] = (moved[target.model] or Vector3.zero) + (after.Position - before.Position)
		tilted[target.model] = (tilted[target.model] or 0) + radians
		return true
	end

	--[[ Where a lock's partner is FOR SOLVING: where it stood at compose time, plus whatever the
	     author has moved it since. The live position is deliberately not consulted -- demo 4's
	     rotor swings its attachments between states, and a lock composed at one state must not
	     chase the swing. ]]
	local function lockPartnerPos(lock: Lock): Vector3
		local pos = lock.partnerBase
		local pm = lock.partnerModel
		if pm then
			pos += (moved[pm] or Vector3.zero) - lock.partnerMovedBase
		end
		return pos
	end

	--[[ Where the lock's OWN node stands in authored terms: compose-time base plus what the
	     author has moved the piece since. For a slab this equals the live position; for the
	     rotor it deliberately does not -- the swing is display, not authoring. ]]
	local function lockNodePos(lock: Lock, target: Target): Vector3
		return lock.nodeBase + (moved[target.model] or Vector3.zero) - lock.nodeMovedBase
	end

	--[[ The same test Seam.build applies -- checked HERE so the tool can warn at the moment a
	     tilt (or a join attempt on a tilted piece) crosses it, instead of the seam silently never
	     arming and the HUD reporting "nothing coincides". ]]
	local function seamOrientationFault(seam: EditorSeam): string?
		return Seam.orientationFault(
			{ id = seam.label, point = seam.node, surface = "" },
			{ id = seam.label, point = seam.partner, surface = "" }
		)
	end

	--[[ Put this seam's node on the ray from the eye through its partner, keeping its own distance
	     from the eye, so the two are drawn on the same pixel. This only ever moves the piece
	     ACROSS the eye ray -- depth is untouched -- which is precisely why it composes with the
	     depth pins instead of fighting them. ]]
	local function solveSeamFrom(target: Target, eye: Vector3, nodePos: Vector3, partnerPos: Vector3): boolean
		local toPartner = partnerPos - eye
		if toPartner.Magnitude < 1e-3 then
			return false
		end
		local reach = (nodePos - eye).Magnitude
		applyDelta(target, (eye + toPartner.Unit * reach) - nodePos)
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
			local declared: string? = nil
			if list then
				for _, pin in list do
					if pin.other.instance == ref.instance then
						declared = if pin.inFront then "front" else "back"
					end
				end
			end
			--[[ A declared rule is read at ITS OWN worst ray -- the exact measurement the solver
			     enforces -- so "ok" means the whole sampled overlap obeys it. Undeclared rows read
			     the dominant order, which is only a hint. ]]
			local mine, theirs = overlapDepths(
				target.model,
				ref.instance,
				if declared == nil then nil else declared == "front"
			)
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

		--[[ Every reads-column value below is sampled from the LIVE camera. Once the author has
		     orbited off the composition view those readings describe the wrong picture -- a rule
		     just solved correctly showed NOT YET beside a success message, which reads as "the
		     tool is lying". Say where to stand instead. ]]
		local awayFromCompose = not atComposeView()
		local lines: { string } = {}
		for i, row in rows do
			local says = if row.declared == "front"
				then "IN FRONT OF"
				elseif row.declared == "back" then "BEHIND     "
				else "--         "
			--[[ What it says next to what it does. A declaration that has not taken effect is the
			     thing the author most needs to see, and it is one glance rather than a query. ]]
			local reads
			if awayFromCompose then
				reads = "orbit back to read"
			elseif not row.overlaps then
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

		--[[ With nothing declared yet there is no composition to protect, so the viewpoint follows
		     the camera. Without this, opening the tool while the orbit was still coasting latched
		     a viewpoint the author never chose and then refused every edit against it. ]]
		if not hasWork() then
			composeCF = cam:GetRenderCFrame()
		end

		--[[ The loudest thing on the panel when it applies: every reading below is taken from the
		     live camera, so once the author has orbited none of it describes the shot. ]]
		title.Text = if atComposeView()
			then "MAP EDITOR                                        M closes"
			else "MAP EDITOR   -- ORBITED AWAY, EDITS PAUSED --   C composes from here"

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
		local turn = tilted[target.model] or 0
		local turnText = if math.abs(turn) > 1e-4 then ("  tilted %.1f deg"):format(math.deg(turn)) else ""
		if offset.Magnitude > 1e-3 or turnText ~= "" then
			table.insert(
				lines,
				("  moved  (%.1f, %.1f, %.1f)%s   step %.2f / %.2f deg"):format(
					offset.X,
					offset.Y,
					offset.Z,
					turnText,
					STEPS[stepIndex],
					TILT_STEPS[stepIndex]
				)
			)
		else
			table.insert(
				lines,
				("  not moved yet   step %.2f / %.2f deg"):format(STEPS[stepIndex], TILT_STEPS[stepIndex])
			)
		end
		editingOut.Text = table.concat(lines, "\n")

		refreshStack(target, rows)
	end

	local function moveBy(delta: Vector3)
		local target = current()
		if not target then
			return
		end
		local editable, blockedBy = canEdit()
		if not editable then
			say(`cannot move: {blockedBy}`, false)
			return
		end
		applyDelta(target, delta)
		--[[ A hand nudge is the author overruling the solver, so EVERY join this piece holds is
		     released rather than snapped straight back on the next sweep -- a surface appears
		     once per seam it carries, and releasing only the selected entry's let the surviving
		     lock re-drag the piece mid-nudge. ENTER re-locks. ]]
		local releasedAny = false
		for _, t in targets do
			local tSeam = t.seams[1]
			if t.model == target.model and tSeam and locked[tSeam.label] then
				locked[tSeam.label] = nil
				releasedAny = true
			end
		end
		if runSolver then
			runSolver()
		else
			options.onChanged()
		end
		--[[ Voiced AFTER the sweep, so the note describes THIS action -- read before it, the line
		     always narrated the previous keypress's delegation and swallowed this one's. ]]
		if releasedAny then
			say(`moved by hand -- joins released, ENTER re-locks{notesSuffix()}`, true)
		elseif #sweepNotes > 0 then
			say(sweepNotes[1], true)
		end
		refresh()
	end

	--[[ Tilt, then re-establish everything. A tilt pivots on the seam node, so a locked join
	     survives it untouched -- which is why this does not release one the way a nudge does. ]]
	local function tiltBy(radians: number)
		local target = current()
		if not target then
			return
		end
		local editable, blockedBy = canEdit()
		if not editable then
			say(`cannot tilt: {blockedBy}`, false)
			return
		end
		if not applyTilt(target, radians) then
			say(`{target.id} cannot be tilted -- the demo drives its pose`, false)
			return
		end
		if runSolver then
			runSolver()
		else
			options.onChanged()
		end
		--[[ A tilt rotates the whole MODEL, and past Seam's opposition tolerance a pair is
		     disqualified AT EVERY ANGLE even though it still lines up on screen. The old failure
		     was silent: the editor read 0 px while the game said "nothing coincides from here".
		     Every seam the model carries is checked -- a piece with two joins degrades them at
		     different rates under the same tilt, and the selected entry's can survive a press
		     that kills the other. ]]
		local faulted: string? = nil
		for _, t in targets do
			local tSeam = t.seams[1]
			if t.model == target.model and tSeam and seamOrientationFault(tSeam) then
				faulted = t.joinsTo
			end
		end
		if faulted then
			say(`TILTED TOO FAR -- the join to {faulted} cannot connect any more (BACKSPACE)`, false)
		elseif #sweepNotes > 0 then
			say(sweepNotes[1], true)
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
		local editable, blockedBy = canEdit()
		if not editable then
			say(`cannot join: {blockedBy}`, false)
			return
		end
		if locked[seam.label] then
			locked[seam.label] = nil
			say(`join to {target.joinsTo} released -- it will drift again`, true)
			refresh()
			return
		end
		if seamOrientationFault(seam) then
			-- Lining the pixels up would succeed and the seam would STILL never arm.
			say("cannot join: the faces no longer oppose (tilted too far -- BACKSPACE puts it back)", false)
			return
		end
		--[[ Declaring the join, not performing it once. The sweep holds it from here on -- FROM
		     THIS VIEW -- so later work on other pieces, composed from other views, cannot pull
		     this one apart again. ]]
		local partnerModel = seam.partner:FindFirstAncestorOfClass("Model")
		locked[seam.label] = {
			eye = cam:GetRenderCFrame().Position,
			nodeBase = seam.node.WorldPosition,
			nodeMovedBase = moved[target.model] or Vector3.zero,
			partnerBase = seam.partner.WorldPosition,
			partnerModel = partnerModel,
			partnerMovedBase = if partnerModel then (moved[partnerModel] or Vector3.zero) else Vector3.zero,
		}
		local ok: boolean = true
		local why: string? = nil
		if runSolver then
			ok, why = runSolver()
		end
		say(
			if ok
				then `joined to {target.joinsTo} -- it will stay joined{notesSuffix()}`
				else `joined, but: {why}{notesSuffix()}`,
			ok
		)
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
		local editable, blockedBy = canEdit()
		if not editable then
			say(`cannot flip: {blockedBy}`, false)
			return
		end
		--[[ Mirror about the seam's OWN view when it is locked: the flip then keeps the node on
		     the lock's ray and the join survives it exactly, as the sweep expects. ]]
		local lock = locked[seam.label]
		local eye = if lock then lock.eye else cam:GetRenderCFrame().Position
		local partnerPos = if lock then lockPartnerPos(lock) else seam.partner.WorldPosition
		local nodePos = if lock then lockNodePos(lock, target) else seam.node.WorldPosition
		local toNode = nodePos - eye
		local mine = toNode.Magnitude
		local theirs = (partnerPos - eye).Magnitude
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
		--[[ Straight through applyDelta rather than moveBy. A flip mirrors the node along the SAME
		     eye ray, so a joined node stays on the eye-to-partner ray and the join is preserved
		     exactly -- going via moveBy released it, which is the one thing a flip does not do. ]]
		local wanted = eye + toNode.Unit * wantedDistance
		-- The delta is computed in the same frame the mirror was: authored positions for a locked
		-- seam, live for a free one. Mixing them dragged a locked rotor by its swing.
		applyDelta(target, wanted - nodePos)
		if runSolver then
			runSolver()
		end
		if #sweepNotes > 0 then
			say(sweepNotes[1], true)
		end
		refresh()
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

	--[[ The lock-aware slide axis, shared by applyOne for the pinned piece AND for a piece a
	     shortfall gets delegated to. Along the lock's stored ray when locked (the join survives
	     the slide exactly), the live eye ray otherwise. ]]
	local function slideAxisFor(target: Target): Vector3
		local seam = target.seams[1]
		local lock = if seam then locked[seam.label] else nil
		if seam and lock then
			local along = lockNodePos(lock, target) - lock.eye
			if along.Magnitude > 1e-3 then
				return along.Unit
			end
		end
		return slideAxis(target)
	end

	local function targetFor(inst: Instance): Target?
		--[[ A model can appear as several entries (one per seam it carries), and their slide axes
		     differ once one is locked: prefer the LOCKED entry, so a delegated slide runs along
		     the ray that keeps its join -- the first-listed entry is otherwise arbitrary. ]]
		local fallback: Target? = nil
		for _, t in targets do
			if t.model == inst then
				local tSeam = t.seams[1]
				if tSeam and locked[tSeam.label] then
					return t
				end
				fallback = fallback or t
			end
		end
		return fallback
	end

	local function applyOne(target: Target, allowDelegate: boolean): (boolean, string?)
		local list = pins[target.model]
		conflicts[target.model] = nil
		if not list or #list == 0 then
			return true, nil
		end
		--[[ A LOCKED piece must slide along its lock's stored ray, not the live eye ray. Sliding
		     along the stored ray keeps the node on it -- the join survives EXACTLY -- while still
		     changing depth at the overlaps; sliding along the live ray (composed from another
		     view, the rays can be near-perpendicular) knocked the node off the stored ray, the
		     lock pass dragged it back, and the two passes fought to a draw: the pin landed studs
		     short of what it reported. ]]
		--[[ A piece pinned both IN FRONT OF and BEHIND the same reference is a contradiction, not
		     a solve: hand-typed attributes make it easy to write, and feeding it to the delegation
		     below marched both pieces toward the camera a few studs per keypress, forever, while
		     reporting success. Refuse by name instead. ]]
		local wantFront: { [Instance]: boolean } = {}
		for _, pin in list do
			local seen = wantFront[pin.other.instance]
			if seen ~= nil and seen ~= pin.inFront then
				conflicts[target.model] = { [pin.other.instance] = true }
				return false, `{target.id} is pinned both in front of and behind {pin.other.name} -- remove one`
			end
			wantFront[pin.other.instance] = pin.inFront
		end

		local dir = slideAxisFor(target)
		local lowest, highest = -math.huge, math.huge
		local blocked: string? = nil
		local dropped: { string } = {}
		local clash: { [Instance]: boolean } = {}
		local short = 0

		for _, pin in list do
			local mine, theirs, rayDir = overlapDepths(target.model, pin.other.instance, pin.inFront)
			if not mine or not theirs or not rayDir then
				-- Nothing shares pixels here yet, so there is nothing to enforce. Skipped rather
				-- than failed: the author declared an intention, not a claim about right now.
				continue
			end
			local k = dir:Dot(rayDir)
			--[[ 0.05, not epsilon: a locked piece slides along its lock's ray, which can sit near
			     ninety degrees to this overlap's live ray -- k then shrinks toward sin^2(pitch)
			     and the division below would amplify a sub-stud depth need into a slide of tens of
			     studs. Refusing with the existing message beats teleporting the piece. ]]
			if math.abs(k) < 0.05 then
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
				--[[ Sliding THIS piece cannot satisfy the set -- but the ordering is a statement
				     about a PAIR, and the other piece can usually supply what this one cannot.
				     The user's own case: "high walkway behind the start walkway, in front of its
				     pole" needs +20 studs of depth with only +6 of headroom, and no tilt of the
				     walkway can close it (its two overlap regions sit 5 studs apart -- the tilt
				     would need 175 degrees). Sliding the START walkway 14 studs toward the camera
				     solves it exactly, invisibly from this view. So the shortfall is DELEGATED:
				     this piece takes its headroom, the other piece slides the remainder along its
				     own (lock-aware) axis. The next sweep round re-measures honestly. ]]
				local delegated = false
				local other = if allowDelegate then targetFor(pin.other.instance) else nil
				if other and other ~= target then
					local axisO = slideAxisFor(other)
					local kO = axisO:Dot(rayDir)
					local boundary = if (pin.inFront and k > 0) or (not pin.inFront and k < 0)
						then lowest -- this pin wanted the ceiling; the floor is what stands
						else highest
					if math.abs(kO) >= 0.05 and math.abs(boundary) ~= math.huge then
						-- Move `theirs` so this pin's limit lands exactly on the boundary.
						local u = (k * (boundary - limit)) / kO
						--[[ Only while the ask is SHRINKING. The other piece's own rules run after
						     this and can slide it straight back; re-firing at full size every round
						     is that fight, not progress, and the verification pass below will name
						     the loser honestly. ]]
						local prev = delegateHistory[pin]
						local converging = prev == nil or math.abs(u) < prev * 0.75
						if math.abs(u) <= 25 and converging then
							delegateHistory[pin] = math.abs(u)
							applyDelta(other, axisO * u)
							if (pin.inFront and k > 0) or (not pin.inFront and k < 0) then
								highest = math.min(highest, boundary)
							else
								lowest = math.max(lowest, boundary)
							end
							note(
								`moved {other.id} {("%.1f"):format(math.abs(u))} studs to put {target.id} {if pin.inFront then "in front of" else "behind"} it`
							)
							delegated = true
						end
					end
				end
				if not delegated then
					short = math.max(short, lo - hi)
					table.insert(
						dropped,
						if pin.inFront then `in front of {pin.other.name}` else `behind {pin.other.name}`
					)
					clash[pin.other.instance] = true
				end
			else
				lowest, highest = lo, hi
			end
		end

		if blocked then
			return false, blocked
		end
		local t = math.clamp(0, lowest, highest)
		if math.abs(t) > 25 then
			-- A rule that wants the piece moved this far is geometry fighting the view, not an
			-- ordering nudge; name it rather than fling the piece off screen.
			conflicts[target.model] = clash
			return false, `satisfying this rule would slide {target.id} {("%.0f"):format(math.abs(t))} studs -- refusing`
		end
		if math.abs(t) > 1e-4 then
			applyDelta(target, dir * t)
		end
		if #dropped > 0 then
			conflicts[target.model] = clash
			--[[ Naming the way out, not just the refusal. Sliding cannot reconcile these; turning
			     the piece can, because that is what changes its depth from one overlap to the
			     next. See applyTilt. ]]
			--[[ No more "tilt to make room" as a blanket promise -- in the case that prompted all
			     this, the tilt needed was 175 degrees. If delegation could not do it either, the
			     honest answer is that this arrangement is not reachable from here. ]]
			return false,
				`{target.id} cannot be {table.concat(dropped, " and ")} from this angle -- {("%.1f"):format(short)} studs short, even moving the other piece`
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
		--[[ The one place geometry actually moves, so it is guarded here as well as at every entry
		     point above: an attribute edited from Studio reaches this without passing any of them. ]]
		local editable, blockedBy = canEdit()
		if not editable then
			return false, blockedBy
		end
		table.clear(sweepNotes)
		table.clear(delegateHistory)
		local problem: string? = nil
		for _ = 1, 4 do
			for _, target in targets do
				local seam = target.seams[1]
				local lock = if seam then locked[seam.label] else nil
				if seam and lock then
					--[[ From the lock's own stored eye, against where the partner was at compose
					     time plus whatever the AUTHOR has moved it since. The live camera and the
					     rotor's live swing play no part -- this is what lets two seams composed
					     from different views coexist. ]]
					solveSeamFrom(target, lock.eye, lockNodePos(lock, target), lockPartnerPos(lock))
				end
			end
			for _, target in targets do
				applyOne(target, true)
			end
		end
		--[[ THE VERIFICATION PASS decides what is true. A delegated move can be reverted by the
		     other piece's own rules later in the same round, and a round-4 delegation was never
		     re-measured at all -- so the sweep used to report success on arrangements it had not
		     achieved, with the row reading NOT YET under a status line saying it worked. This
		     pass folds every interval honestly, with delegation off: whatever cannot stand is
		     dropped, marked on its row, and named in the return. ]]
		problem = nil
		for _, target in targets do
			local ok, why = applyOne(target, false)
			if not ok then
				problem = why
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
		local editable, blockedBy = canEdit()
		if not editable then
			say(`cannot reorder: {blockedBy}`, false)
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
		-- The solver moving a piece the author did not select is never silent -- on failure too.
		say(if ok then `{target.id} is {said}{notesSuffix()}` else `{why}{notesSuffix()}`, ok)
		refresh()
	end

	local function undo()
		local target = current()
		if not target then
			return
		end
		--[[ Gated BEFORE anything is touched. This used to clear the lock, wipe both attributes and
		     drop the offset record, and only THEN call moveBy -- which refuses when the view has
		     drifted. The piece stayed put, every rule on it was gone, and the panel said "put
		     back". Unrecoverable, so the check comes first. ]]
		local editable, blockedBy = canEdit()
		if not editable then
			say(`cannot undo: {blockedBy}`, false)
			return
		end
		local home = homeCF[target.model]
		local offset = moved[target.model]
		if not home and not offset then
			return
		end

		-- Release what was declared first, or the sweep re-establishes it and undo looks inert.
		-- EVERY join this piece carries: a surface appears once per seam (demo 3's high walkway
		-- holds two), and releasing only the selected entry's let the sweep re-drag the piece.
		for _, t in targets do
			local tSeam = t.seams[1]
			if t.model == target.model and tSeam then
				locked[tSeam.label] = nil
			end
		end
		target.model:SetAttribute(ATTR_FRONT, "")
		target.model:SetAttribute(ATTR_BACK, "")
		syncPins()

		if home and not target.apply then
			-- The whole pose, so a tilt comes back too -- and the avatar comes with the floor,
			-- exactly as every applyDelta-driven move carries it: BACKSPACE used to reintroduce
			-- the hanging-in-the-air drop this direct PivotTo bypassed.
			local carry = playerStandsOn(target.model)
			local before = target.model:GetPivot()
			target.model:PivotTo(home)
			if carry then
				local character = Players.LocalPlayer.Character
				if character then
					character:PivotTo(character:GetPivot() + (home.Position - before.Position))
				end
			end
		elseif offset then
			-- Demo 4's rotor takes a translation only; its pose is re-issued from a stored home.
			applyDelta(target, -offset)
		end
		moved[target.model] = nil
		tilted[target.model] = nil
		homeCF[target.model] = nil

		reconcile()
		say(`{target.id} put back -- its join and rules were released{notesSuffix()}`, true)
		refresh()
	end

	local function printExport()
		print("---- map edits ----")
		local any = false
		local done: { [PVInstance]: boolean } = {}
		for _, target in targets do
			local offset = moved[target.model] or Vector3.zero
			local turn = tilted[target.model]
			--[[ Tilt counts as an edit on its own: a tilt about an axis close to the pivot leaves
			     the accumulated offset near zero, and the piece was silently missing from P. ]]
			local edited = offset.Magnitude > 1e-4 or (turn ~= nil and math.abs(turn) > 1e-4)
			if edited and not done[target.model] then
				done[target.model] = true
				any = true
				print(("-- %s moved by (%.2f, %.2f, %.2f)"):format(target.id, offset.X, offset.Y, offset.Z))
				if turn and math.abs(turn) > 1e-4 then
					--[[ A tilted piece is no longer described by a position alone, so print the
					     whole orientation rather than leaving the reader to rebuild it. ]]
					local rx, ry, rz = target.model:GetPivot():ToEulerAnglesYXZ()
					print(
						("--   tilted %.2f deg -- orientation CFrame.Angles(math.rad(%.3f), math.rad(%.3f), math.rad(%.3f))"):format(
							math.deg(turn),
							math.deg(rx),
							math.deg(ry),
							math.deg(rz)
						)
					)
					--[[ Live this state is recoverable -- BACKSPACE. Pasted into the level file it
					     boots that way permanently, so the paste-block itself carries the flag. ]]
					for _, t in targets do
						local tSeam = t.seams[1]
						if t.model == target.model and tSeam and seamOrientationFault(tSeam) then
							print(
								`--   WARNING: this tilt puts the join to {t.joinsTo} past the crossing tolerance -- pasted back, that seam will never connect`
							)
						end
					end
				end
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
			elseif code == Enum.KeyCode.C then
				composeCF = cam:GetRenderCFrame()
				say("composing from here now -- earlier joins keep the views they were made from", true)
				refresh()
			elseif code == Enum.KeyCode.G then
				tiltBy(-math.rad(TILT_STEPS[stepIndex]))
			elseif code == Enum.KeyCode.H then
				tiltBy(math.rad(TILT_STEPS[stepIndex]))
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
					say(`cleared every rule on {target.id}{notesSuffix()}`, true)
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
							if #sweepNotes > 0 then
								-- A Studio-typed rule can delegate too; that move is never silent.
								say(sweepNotes[1], true)
							end
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
			--[[ Whatever is on screen when the tool opens is what the shot is being framed from --
			     but ONLY while nothing has been declared yet: recapturing over existing work
			     silently rebased every pin onto whatever angle the author happened to reopen at
			     (C stays the one explicit way to re-compose). The nil case exists because rules
			     typed into Studio's Properties BEFORE the first open make hasWork() true with no
			     view ever captured -- and a nil composeCF read as "at the composition view"
			     forever, so nothing gated and the rows never deferred. ]]
			if open and (composeCF == nil or not hasWork()) then
				composeCF = cam:GetRenderCFrame()
			end
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

		hasTiltWork = function(): boolean
			return next(tilted) ~= nil
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
