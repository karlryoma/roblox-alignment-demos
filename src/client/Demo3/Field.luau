--!strict
--[[
	Field — demo 3's exterior: three platforms, two anchor pairs, and the connectors that
	alignment creates.

	AUTHORING RULE THAT SHAPES EVERY NUMBER HERE: the anchors of a pair differ in DEPTH, never in
	height. The connector is a real 3D line, so a pair separated vertically would produce a
	"bridge" that looked flat from the locking seat and is a steep ramp in world space -- still
	traversable (Humanoid.MaxSlopeAngle defaults to 89 deg) but wrong to walk. Depth separation is
	also the STRONGER illusion, because depth is exactly what the eye cannot judge. Both pairs are
	dead level and Field.slopeDeg asserts it at boot.

	The second rule: the anchor line sits 1.2 studs above the decks. That is the sight corridor --
	the occlusion ray to the near anchor runs the length of the deck the player is standing on, so
	anything taller than 1.2 studs placed along it would make the demo read BLOCKED at exactly the
	moment the player gets it right. Demo 2 shipped that bug with its hanger rods. Nothing is
	built inside the corridor.

	LOCAL COORDINATES. Decks are at y = 0 (top surface).
	  A  x[-9, 9]  z[-10,  14]   start
	  B  x[-9, 9]  z[-66, -50]   across connector 1
	  C  x[44,60]  z[-66, -50]   across connector 2, the goal
]]

local Field = {}

export type Pair = {
	near: BasePart, -- the ring: the aperture, nearer the eye at the solution
	far: BasePart, -- the pip: the bead seen through it
	glow: { BasePart },
	--[[ Everything the ray to an anchor must not be blocked by -- which includes the plinths,
	     because they sit directly under the anchor line. ]]
	markers: { Instance },
	--[[ Its own folder, so a reset destroys every part the pair created rather than the handful
	     the handle happens to name. ]]
	folder: Folder,
	destroy: () -> (),
}

export type Connector = {
	model: Model,
	segments: { BasePart },
	destroy: () -> (),
}

export type Handle = {
	folder: Folder,
	markers: { Instance }, -- excluded from occlusion rays; grows when stage 2 is created
	stage1: Pair,
	spawnCF: CFrame,
	goal: BasePart,
	safeParts: { BasePart },
	destroy: () -> (),
}

Field.COLD = Color3.fromRGB(42, 80, 104)
Field.HOT = Color3.fromRGB(126, 244, 255)
Field.GOLD = Color3.fromRGB(255, 206, 120)

local DECK = Color3.fromRGB(58, 62, 72)
local EDGE = Color3.fromRGB(38, 41, 48)

local ANCHOR_Y = 1.2
local RING_R = 0.6
local BEAD = 0.12
local PIP = 0.7

-- Stage 1: 40 studs of depth between the near and far anchors.
Field.S1_NEAR = Vector3.new(0, ANCHOR_Y, -10)
Field.S1_FAR = Vector3.new(0, ANCHOR_Y, -50)
-- Stage 2: 35 studs. Platform C sits far enough east that the camera -- which can swing about
-- 10.5 studs past the player -- can never reach the pair's midpoint.
Field.S2_NEAR = Vector3.new(9, ANCHOR_Y, -58)
Field.S2_FAR = Vector3.new(44, ANCHOR_Y, -58)

function Field.slopeDeg(a: Vector3, b: Vector3): number
	local run = math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
	if run < 1e-4 then
		return 90
	end
	return math.deg(math.atan(math.abs(b.Y - a.Y) / run))
end

local function newPart(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material,
	canQuery: boolean,
	parent: Instance
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = canQuery
	p.CanTouch = false
	p.CanQuery = canQuery
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--[[
	One anchor: a ring of beads facing along the pair's axis, or a solid pip. Markers are
	CanQuery = false so the occlusion ray drawn TO them cannot be blocked BY them.
]]
local function ring(origin: CFrame, at: Vector3, axis: Vector3, parent: Instance, pair: Pair): Part
	local hub = newPart("RingHub", Vector3.new(0.2, 0.2, 0.2), origin * CFrame.new(at), Field.HOT, Enum.Material.Neon, false, parent)
	hub.Transparency = 1
	table.insert(pair.markers, hub)

	local frame = CFrame.lookAt(at, at + axis)
	for i = 1, 16 do
		local a = (i / 16) * math.pi * 2
		local b = newPart(
			"Bead",
			Vector3.new(BEAD, BEAD, BEAD),
			origin * (frame * CFrame.new(math.cos(a) * RING_R, math.sin(a) * RING_R, 0)),
			Field.COLD,
			Enum.Material.Neon,
			false,
			parent
		)
		b.Shape = Enum.PartType.Ball
		table.insert(pair.markers, b)
		table.insert(pair.glow, b)
	end
	-- The plinth. Its top face used to be flush with the anchor line, which put it exactly on the
	-- sight ray to its own anchor -- the demo-2 hanger-rod bug, rebuilt. Two independent fixes,
	-- because this one is fatal and silent: it is short enough that the whole ring clears it, AND
	-- it goes in the exclusion list so it could not block the ray even if it were taller.
	local plinth = newPart(
		"Plinth",
		Vector3.new(3, 0.4, 1.2),
		origin * CFrame.new(at - Vector3.new(0, 1.0, 0)),
		EDGE,
		Enum.Material.Metal,
		true,
		parent
	)
	table.insert(pair.markers, plinth)
	return hub
end

local function pip(origin: CFrame, at: Vector3, parent: Instance, pair: Pair): Part
	local p = newPart("Pip", Vector3.new(PIP, PIP, PIP), origin * CFrame.new(at), Field.COLD, Enum.Material.Neon, false, parent)
	p.Shape = Enum.PartType.Ball
	table.insert(pair.markers, p)
	table.insert(pair.glow, p)
	local plinth = newPart(
		"Plinth",
		Vector3.new(3, 0.4, 1.2),
		origin * CFrame.new(at - Vector3.new(0, 1.0, 0)),
		EDGE,
		Enum.Material.Metal,
		true,
		parent
	)
	table.insert(pair.markers, plinth)
	return p
end

--[[ Builds one anchor pair. Stage 2 goes through here lazily, at advance() time. ]]
function Field.pair(origin: CFrame, nearAt: Vector3, farAt: Vector3, parent: Instance): Pair
	local folder = Instance.new("Folder")
	folder.Name = "Pair"
	folder.Parent = parent

	local pairHandle: Pair = {
		near = nil :: any,
		far = nil :: any,
		glow = {},
		markers = {},
		folder = folder,
		destroy = function()
			folder:Destroy()
		end,
	}
	local axis = (nearAt - farAt).Unit
	pairHandle.near = ring(origin, nearAt, axis, folder, pairHandle)
	pairHandle.far = pip(origin, farAt, folder, pairHandle)
	return pairHandle
end

--[[
	THE CONNECTOR, and the one art decision that decides whether this demo reads as clever or as
	broken.

	From the locking seat it is foreshortened to nothing -- that is the illusion. From every other
	angle it is a long beam hanging in space, and that cannot be hidden. So it is deliberately
	STYLISED: a chain of floating slabs with a Neon spine, materialising in sequence from the near
	anchor to the far one. A concrete plank bridge read off-angle looks like a bug; a light bridge
	that assembled itself reads as something the player cast.

	Collision is switched on per segment as it lands, so nothing can shove a player standing at
	the near end while the far end is still arriving.
]]
function Field.connector(origin: CFrame, from: Vector3, to: Vector3, parent: Instance): Connector
	local model = Instance.new("Model")
	model.Name = "Connector"

	local span = (to - from).Magnitude
	local count = math.max(4, math.round(span / 4.2))
	local segLength = span / count
	local dir = (to - from).Unit
	local segments: { BasePart } = {}

	for i = 1, count do
		local centre = from + dir * (segLength * (i - 0.5))
		local cf = origin * CFrame.lookAt(centre, centre + dir)
		local slab = newPart(
			"Slab",
			Vector3.new(6, 0.5, segLength * 0.86),
			cf,
			Color3.fromRGB(70, 78, 92),
			Enum.Material.SmoothPlastic,
			false, -- collision is enabled as each segment materialises
			model
		)
		slab.Transparency = 1

		local spine = newPart(
			"Spine",
			Vector3.new(0.5, 0.16, segLength * 0.86),
			cf * CFrame.new(0, 0.33, 0),
			Field.HOT,
			Enum.Material.Neon,
			false,
			model
		)
		spine.Transparency = 1

		table.insert(segments, slab)
		table.insert(segments, spine)
	end

	model.Parent = parent
	return {
		model = model,
		segments = segments,
		destroy = function()
			model:Destroy()
		end,
	}
end

function Field.build(origin: CFrame, parent: Instance): Handle
	local folder = Instance.new("Folder")
	folder.Name = "Demo3Field"

	local safeParts: { BasePart } = {}
	local function deck(name: string, size: Vector3, at: Vector3): BasePart
		local p = newPart(name, size, origin * CFrame.new(at), DECK, Enum.Material.Slate, true, folder)
		table.insert(safeParts, p)
		-- A lip, purely so the edge reads at a distance. Kept off the sight corridor: it sits on
		-- the perimeter, never across the axis of a pair.
		return p
	end

	deck("PlatformA", Vector3.new(18, 1, 24), Vector3.new(0, -0.5, 2))
	deck("PlatformB", Vector3.new(18, 1, 16), Vector3.new(0, -0.5, -58))
	deck("PlatformC", Vector3.new(16, 1, 16), Vector3.new(52, -0.5, -58))

	-- Pylons, so the platforms read as standing in a void rather than floating arbitrarily.
	for _, at in { Vector3.new(0, -12, 2), Vector3.new(0, -12, -58), Vector3.new(52, -12, -58) } do
		newPart("Pylon", Vector3.new(4, 23, 4), origin * CFrame.new(at), EDGE, Enum.Material.Concrete, true, folder)
	end

	local stage1 = Field.pair(origin, Field.S1_NEAR, Field.S1_FAR, folder)

	local goal = newPart(
		"Goal",
		Vector3.new(3, 0.4, 3),
		origin * CFrame.new(52, 0.2, -58),
		Field.GOLD,
		Enum.Material.Neon,
		false,
		folder
	)

	local light = Instance.new("PointLight")
	light.Brightness = 2
	light.Range = 24
	light.Color = Field.GOLD
	light.Shadows = false
	light.Parent = goal

	folder.Parent = parent

	local markers: { Instance } = {}
	for _, m in stage1.markers do
		table.insert(markers, m)
	end
	table.insert(markers, goal)

	local handle: Handle = {
		folder = folder,
		markers = markers,
		stage1 = stage1,
		-- No rotation: a CFrame's LookVector is -Z, which is already toward the platforms. The
		-- 180-degree turn that used to be here faced the player at the empty half of the field.
		spawnCF = origin * CFrame.new(0, 3.5, 8),
		goal = goal,
		safeParts = safeParts,
		destroy = function()
			folder:Destroy()
		end,
	}
	return handle
end

return Field
