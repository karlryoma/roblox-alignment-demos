--!strict
--[[
	Level — demo 4's diorama: three floors and one rotatable sub-model.

	EVERY WALKABLE SURFACE IS A FLOOR, as in demo 3: Roblox gravity is global -Y with no
	per-character override, so walls-become-floors is out while the player is a Humanoid. Same
	deliberate limitation, same reason.

	THE SEAMS ARE EXACT. Under a parallel projection two points coincide precisely when their
	difference is parallel to the view direction, and at the isometric pitch (35.264 deg) the four
	yaw states give the four diagonals. So authoring a join is adding (k,k,k):

	    S_end (-12,-6,-6) -> R_a  (0,6,6)   offset (12,12,12)   live at yaw 45,  rotor 0
	    R_b   (0, 6,-4)   -> T_start (10,16,-14)  offset (10,10,-10)  live at yaw 135, rotor 1

	R_a and R_b belong to the ROTOR, so their world positions and their outward directions both
	turn with it -- which is why a rotor state is half of a graph's identity. The arms are
	deliberately unequal (6 and 4, from a 8x12 deck): equal arms would put a node in the same
	place at two different rotor states and collapse four states into two.

	The route needs a camera rotation AND a sub-model rotation, and neither seam is live in any
	other of the sixteen states. Verified by enumeration at boot.
]]

local Level = {}

export type NodeSpec = {
	id: string,
	surface: string,
	at: Vector3, -- region-local; for rotor nodes this is the rest (state 0) position
	outward: Vector3,
	onRotor: boolean,
}

export type Handle = {
	folder: Folder,
	--[[ One Model per movable unit -- the two slabs and the rotor -- each holding its geometry,
	     its skirt and its seam markers, with the Attachments on the slab inside. PivotTo then
	     moves a whole walkway and its seam as one, which is what the map editor needs. ]]
	models: { [string]: Model },
	surfaces: Folder,
	occluders: Folder,
	origin: CFrame, -- the frame the local coordinates in this file are expressed in
	rotor: Model,
	rotorDeck: BasePart,
	setRotor: (turns: number) -> (),
	--[[ Move the rotor's REST POSE. setRotor re-issues an absolute PivotTo from that pose every
	     time it runs, so a plain PivotTo on the model is erased by the next call -- the map editor
	     has to move the home instead. ]]
	nudgeRotorHome: (delta: Vector3) -> (),
	rotorPivot: CFrame,
	attachments: { [string]: Attachment },
	markers: { [string]: BasePart },
	bars: { BasePart },
	spawnCF: () -> CFrame,
	goal: BasePart,
	centre: Vector3,
	boundsMin: Vector3,
	boundsMax: Vector3,
	destroy: () -> (),
}

Level.COLD = Color3.fromRGB(48, 76, 98)
Level.HOT = Color3.fromRGB(132, 246, 255)

local SAND = Color3.fromRGB(230, 212, 186)
local ROSE = Color3.fromRGB(206, 142, 152)
local TEAL = Color3.fromRGB(110, 174, 178)
local SHADE = Color3.fromRGB(152, 134, 120)

Level.ROTOR_PIVOT = Vector3.new(0, 6, 0)

--[[ Where each movable unit is authored. Kept as data so the map editor can print an export the
     level file can absorb verbatim. ]]
local SURFACE_AT: { [string]: Vector3 } = {
	S = Vector3.new(-12, -6.5, 0),
	T = Vector3.new(10, 15.5, -20),
	R = Vector3.new(0, 6, 0),
}
Level.SURFACE_AT = SURFACE_AT

local NODES: { NodeSpec } = {
	{ id = "S_end", surface = "S", at = Vector3.new(-12, -6, -6), outward = Vector3.new(0, 0, -1), onRotor = false },
	{ id = "T_start", surface = "T", at = Vector3.new(10, 16, -14), outward = Vector3.new(0, 0, 1), onRotor = false },
	{ id = "R_a", surface = "R", at = Vector3.new(0, 6, 6), outward = Vector3.new(0, 0, 1), onRotor = true },
	{ id = "R_b", surface = "R", at = Vector3.new(4, 6, 0), outward = Vector3.new(1, 0, 0), onRotor = true },
}
Level.NODES = NODES

--[[ The pairs the level intends, for the boot assertion and for the map editor's SOLVE. ]]
local INTENDED: { { string } } = {
	{ "S_end", "R_a" },
	{ "R_b", "T_start" },
}
Level.INTENDED = INTENDED

local REAL_EDGES: { { string } } = {}
Level.REAL_EDGES = REAL_EDGES

Level.START_SURFACE = "S"
Level.GOAL_SURFACE = "T"

local trackedMin = Vector3.new(math.huge, math.huge, math.huge)
local trackedMax = Vector3.new(-math.huge, -math.huge, -math.huge)

local function newPart(
	name: string,
	size: Vector3,
	at: Vector3,
	colour: Color3,
	origin: CFrame,
	parent: Instance,
	solid: boolean,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = origin * CFrame.new(at)
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = solid
	p.CanTouch = false
	p.CanQuery = false -- only the occluder folder blocks a seam's sight line
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	trackedMin = trackedMin:Min(at - size * 0.5)
	trackedMax = trackedMax:Max(at + size * 0.5)
	return p
end

function Level.build(origin: CFrame, parent: Instance): Handle
	trackedMin = Vector3.new(math.huge, math.huge, math.huge)
	trackedMax = Vector3.new(-math.huge, -math.huge, -math.huge)

	local folder = Instance.new("Folder")
	folder.Name = "Demo4Level"

	local surfaces = Instance.new("Folder")
	surfaces.Name = "Surfaces"
	surfaces.Parent = folder

	local occluders = Instance.new("Folder")
	occluders.Name = "Occluders"
	occluders.Parent = folder

	local hosts: { [string]: BasePart } = {}
	local models: { [string]: Model } = {}

	local function surfaceModel(name: string, size: Vector3, at: Vector3, colour: Color3, skirtAt: Vector3): BasePart
		local model = Instance.new("Model")
		model.Name = name
		model.Parent = surfaces
		models[name] = model
		local slab = newPart(name, size, at, colour, origin, model, true)
		newPart(name .. "-skirt", Vector3.new(11, 1.6, 11), skirtAt, SHADE, origin, model, false)
		model.WorldPivot = slab.CFrame
		return slab
	end

	-- Painted-on ambient occlusion: at this distance shadows are dead, so the depth cue is colour.
	hosts.S = surfaceModel("S", Vector3.new(12, 1, 12), SURFACE_AT.S, SAND, SURFACE_AT.S - Vector3.new(0, 1.1, 0))
	hosts.T = surfaceModel("T", Vector3.new(12, 1, 12), SURFACE_AT.T, ROSE, SURFACE_AT.T - Vector3.new(0, 1.1, 0))

	--[[ The rotor. 8 x 12, so its two seam edges sit at different radii and the four states are
	     genuinely four states. ]]
	local rotor = Instance.new("Model")
	rotor.Name = "Rotor"
	local deck = newPart("deck", Vector3.new(8, 1, 12), Level.ROTOR_PIVOT - Vector3.new(0, 0.5, 0), TEAL, origin, rotor, true)
	newPart("deck-skirt", Vector3.new(7, 1.6, 11), Level.ROTOR_PIVOT - Vector3.new(0, 1.6, 0), SHADE, origin, rotor, false)
	hosts.R = deck
	-- Queryable so the ride-the-bridge test can find it. Safe: Seam's sight ray is an Include
	-- filter over the occluder folder alone, so the deck can never block a seam.
	deck.CanQuery = true
	rotor.Parent = folder

	-- Mutable: this is the rotor's rest pose, and the map editor edits it.
	local rotorHome = origin * CFrame.new(Level.ROTOR_PIVOT)
	local rotorTurns = 0
	-- No PrimaryPart: with one set, GetPivot returns that part's CFrame and PivotTo would shift
	-- the whole deck by its offset instead of turning about the intended axis.
	rotor.WorldPivot = rotorHome
	models.R = rotor
	local function setRotor(turns: number)
		rotorTurns = turns
		rotor:PivotTo(rotorHome * CFrame.Angles(0, math.rad(90 * turns), 0))
	end
	local function nudgeRotorHome(delta: Vector3)
		rotorHome = rotorHome + delta
		rotor.WorldPivot = rotorHome
		setRotor(rotorTurns)
	end
	setRotor(0)

	-- Columns. These are the ONLY occluders: a seam hidden behind one must not connect.
	-- Kept short deliberately: the camera standoff is FITTED to the geometry, so a column that
	-- hangs twelve studs below its slab costs real frame budget -- and at this range frame budget
	-- is distance, which is the one thing the avatar's level-of-detail cares about.
	newPart("col-S", Vector3.new(2.2, 5, 2.2), Vector3.new(-12, -9.5, 0), SHADE, origin, occluders, false).CanQuery = true
	newPart("col-T", Vector3.new(2.2, 5, 2.2), Vector3.new(10, 12.5, -20), SHADE, origin, occluders, false).CanQuery = true

	local attachments: { [string]: Attachment } = {}
	local markers: { [string]: BasePart } = {}
	local bars: { BasePart } = {}

	for _, node in NODES do
		local host = hosts[node.surface]
		local world = (origin * CFrame.new(node.at)).Position
		local att = Instance.new("Attachment")
		att.Name = node.id
		-- PARENT FIRST. WorldCFrame on an unparented Attachment has no world to be relative to, so
		-- the assignment is kept as the LOCAL frame and every node ends up at host.CFrame times the
		-- intended pose the moment it is parented -- silently, and nowhere near the geometry.
		att.Parent = host
		-- LookVector carries the outward direction and UpVector the surface normal, so a seam on
		-- the rotor turns with it and Seam needs no special case.
		att.WorldCFrame = CFrame.lookAt(world, world + node.outward, Vector3.yAxis)
		attachments[node.id] = att

		local across = Vector3.new(math.abs(node.outward.Z), 0, math.abs(node.outward.X))
		local bar = newPart(
			node.id,
			Vector3.new(0.4, 0.14, 0.4) + across * 4.6,
			node.at + Vector3.new(0, 0.07, 0) - node.outward * 0.3,
			Level.COLD,
			origin,
			models[node.surface],
			false,
			Enum.Material.Neon
		)
		markers[node.id] = bar
		table.insert(bars, bar)
	end

	-- Parented to its surface: a goal left behind in the folder would sit where the walkway used
	-- to be as soon as the map is edited.
	local goal = newPart(
		"Goal",
		Vector3.new(3, 0.3, 3),
		Vector3.new(10, 16.15, -24),
		Color3.fromRGB(255, 210, 120),
		origin,
		models[Level.GOAL_SURFACE],
		false,
		Enum.Material.Neon
	)

	folder.Parent = parent

	local handle: Handle = {
		folder = folder,
		models = models,
		-- Exposed so the editor can turn a moved pole's world pivot back into the local
		-- coordinate this file is written in.
		origin = origin,
		surfaces = surfaces,
		occluders = occluders,
		rotor = rotor,
		rotorDeck = deck,
		setRotor = setRotor,
		nudgeRotorHome = nudgeRotorHome,
		rotorPivot = rotorHome,
		attachments = attachments,
		markers = markers,
		bars = bars,
		-- An offset from the start surface's own pivot, so an edited map spawns on the moved slab.
		-- A FUNCTION of the live pivot: the editor (and the sweep holding a locked join) moves
		-- slab S, and a spawn frozen at build time dropped the player into mid-air at the old
		-- spot, with the fall catch looping them there.
		spawnCF = function()
			return models[Level.START_SURFACE]:GetPivot() * CFrame.new(0, 4, 3)
		end,
		goal = goal,
		centre = Vector3.new(-1, 4.5, -10),
		boundsMin = trackedMin,
		boundsMax = trackedMax,
		destroy = function()
			folder:Destroy()
		end,
	}
	return handle
end

return Level
