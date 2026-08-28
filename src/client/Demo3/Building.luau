--!strict
--[[
	Building — demo 3's Monument Valley-ish structure and its seam nodes.

	EVERY WALKABLE SURFACE IS A FLOOR. Roblox gravity is global -Y with no per-character
	override, so Monument Valley's walls-become-floors moments are out unless the Humanoid is
	abandoned -- which is the entire thing this design exists to keep. Surfaces sit at various
	heights and yaws; none of them is a wall. Most MV traversal is flat walkway anyway, so the
	illusion still reads. It is a limitation, not an oversight, and the README says so.

	THE SEAMS ARE EXACT, NOT FITTED. Under a parallel projection two points coincide exactly when
	their difference is parallel to the view direction. At the isometric pitch (35.264 deg) the
	view direction at yaw 45 is (1,1,1)/sqrt(3), so authoring a join is adding (k,k,k) to a point:

	    A_end   (0,  0, -8)  ->  B_start (12, 12,  4)   offset (12,12,12)   live at yaw 45
	    B_end   (15, 12, -2) ->  C_start ( 7,  4,  6)   offset (-8,-8, 8)   live at yaw 135

	Nothing is fitted and no epsilon is chased; the tolerance only has to absorb the player's
	aim. Neither seam is live at the other's angle, so the route needs both -- the camera is the
	puzzle.

	Node outward directions are opposite within each pair, which is what makes the crossing a
	pure translation (see Seam's header). Seam.orientationFault asserts it at boot.
]]

local Building = {}

export type NodeSpec = {
	id: string,
	surface: string,
	local_: Vector3, -- position in region-local coordinates
	outward: Vector3,
}

export type Handle = {
	folder: Folder,
	--[[ One Model per walkable surface, holding its slab, its skirt and its seam markers, with
	     the seam Attachments on the slab inside it. That grouping is what makes a surface an
	     EDITABLE UNIT: PivotTo moves the walkway, its lights and its seam together, so nudging a
	     map by eye cannot desync the geometry from the graph. ]]
	models: { [string]: Model },
	boundsMin: Vector3,
	boundsMax: Vector3,
	surfaces: Folder,
	occluders: Folder, -- ONLY these block a seam's sight line
	origin: CFrame, -- the frame the local coordinates in this file are expressed in
	markers: { [string]: BasePart }, -- the Neon bar at each seam mouth
	attachments: { [string]: Attachment },
	glow: { BasePart },
	spawnCF: CFrame,
	goal: BasePart,
	centre: Vector3,
	destroy: () -> (),
}

Building.COLD = Color3.fromRGB(46, 74, 96)
Building.HOT = Color3.fromRGB(130, 245, 255)

local SAND = Color3.fromRGB(228, 210, 184)
local ROSE = Color3.fromRGB(204, 140, 150)
local TEAL = Color3.fromRGB(108, 172, 176)
local SHADE = Color3.fromRGB(150, 132, 118)

--[[ Surfaces: name, size, centre. All floors, all axis-aligned. ]]
local SURFACES: { { name: string, size: Vector3, at: Vector3, colour: Color3 } } = {
	{ name = "A", size = Vector3.new(6, 1, 16), at = Vector3.new(0, -0.5, 0), colour = SAND },
	{ name = "B", size = Vector3.new(6, 1, 12), at = Vector3.new(12, 11.5, -2), colour = TEAL },
	{ name = "C", size = Vector3.new(12, 1, 4), at = Vector3.new(13, 3.5, 6), colour = ROSE },
}

Building.SURFACES = SURFACES

local NODES: { NodeSpec } = {
	{ id = "A_end", surface = "A", local_ = Vector3.new(0, 0, -8), outward = Vector3.new(0, 0, -1) },
	{ id = "B_start", surface = "B", local_ = Vector3.new(12, 12, 4), outward = Vector3.new(0, 0, 1) },
	{ id = "B_end", surface = "B", local_ = Vector3.new(15, 12, -2), outward = Vector3.new(1, 0, 0) },
	{ id = "C_start", surface = "C", local_ = Vector3.new(7, 4, 6), outward = Vector3.new(-1, 0, 0) },
}
Building.NODES = NODES

--[[ The pairs the level intends. Asserted at boot, and reported per angle. ]]
Building.INTENDED = {
	{ "A_end", "B_start" },
	{ "B_end", "C_start" },
}

--[[ No two surfaces touch: every connection in this building is a seam. ]]
local REAL_EDGES: { { string } } = {}
Building.REAL_EDGES = REAL_EDGES

Building.START_SURFACE = "A"
Building.GOAL_SURFACE = "C"

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
	-- Seam markers must not block the ray drawn to themselves; surfaces are not occluders
	-- either (see Seam's header on what counts as one).
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	trackedMin = trackedMin:Min(at - size * 0.5)
	trackedMax = trackedMax:Max(at + size * 0.5)
	return p
end

function Building.build(origin: CFrame, parent: Instance): Handle
	trackedMin = Vector3.new(math.huge, math.huge, math.huge)
	trackedMax = Vector3.new(-math.huge, -math.huge, -math.huge)

	local folder = Instance.new("Folder")
	folder.Name = "Demo3Building"

	local surfaces = Instance.new("Folder")
	surfaces.Name = "Surfaces"
	surfaces.Parent = folder

	local occluders = Instance.new("Folder")
	occluders.Name = "Occluders"
	occluders.Parent = folder

	local byName: { [string]: BasePart } = {}
	local models: { [string]: Model } = {}
	for _, spec in SURFACES do
		local model = Instance.new("Model")
		model.Name = spec.name
		model.Parent = surfaces
		models[spec.name] = model

		local part = newPart(spec.name, spec.size, spec.at, spec.colour, origin, model, true)
		byName[spec.name] = part
		-- A darker skirt under each slab: at this distance shadows are weak, so the ambient
		-- occlusion is painted on.
		newPart(
			spec.name .. "-skirt",
			spec.size - Vector3.new(0.6, -1.6, 0.6),
			spec.at - Vector3.new(0, 1.3, 0),
			SHADE,
			origin,
			model,
			false
		)
		-- Pivot on the slab, so an editor's exported offset is the slab's offset.
		model.WorldPivot = part.CFrame
	end

	-- Support columns. These ARE occluders: a seam hidden behind one must not connect.
	newPart("col-A", Vector3.new(2.2, 10, 2.2), Vector3.new(0, -6, 4), SHADE, origin, occluders, false).CanQuery = true
	-- Under B's far half, NOT its middle: at z = 0 this column sits exactly on the sight line to
	-- C_start in the 135-degree state and silently kills the second seam. Verified against every
	-- node ray at both live angles.
	newPart("col-B", Vector3.new(2.2, 10, 2.2), Vector3.new(12, 6, -4), SHADE, origin, occluders, false).CanQuery = true
	newPart("col-C", Vector3.new(2.2, 8, 2.2), Vector3.new(16, -1, 6), SHADE, origin, occluders, false).CanQuery = true

	local markers: { [string]: BasePart } = {}
	local attachments: { [string]: Attachment } = {}
	local glow: { BasePart } = {}

	for _, node in NODES do
		local host = byName[node.surface]
		-- The attachment lives ON its surface, so it travels with the part. Demo 4 rotates a
		-- sub-model and its seams have to go with it.
		local att = Instance.new("Attachment")
		att.Name = node.id
		local world = (origin * CFrame.new(node.local_)).Position
		-- PARENT FIRST. WorldCFrame on an unparented Attachment is stored as the LOCAL frame, so
		-- assigning it before parenting silently places every node at host.CFrame times the pose
		-- that was meant to be absolute.
		att.Parent = host
		-- The CFrame carries the orientation as well as the point: LookVector is the outward
		-- direction, UpVector the surface normal.
		att.WorldCFrame = CFrame.lookAt(world, world + node.outward, Vector3.yAxis)
		attachments[node.id] = att

		-- A Neon bar across the seam mouth, laid flat on the surface. Neon is unlit, so it reads
		-- regardless of lighting technology at this distance.
		local across = Vector3.new(math.abs(node.outward.Z), 0, math.abs(node.outward.X))
		local size = Vector3.new(0.4, 0.12, 0.4) + across * 4.6
		local bar = newPart(
			node.id,
			size,
			node.local_ + Vector3.new(0, 0.06, 0) - node.outward * 0.3,
			Building.COLD,
			origin,
			folder,
			false,
			Enum.Material.Neon
		)
		bar.Parent = models[node.surface] -- rides with its surface when the map is edited
		markers[node.id] = bar
		table.insert(glow, bar)
	end

	-- Parented to its surface, so an edited map keeps its goal: a goal left behind in the folder
	-- would sit where the walkway used to be and the route could never be completed.
	local goal = newPart(
		"Goal",
		Vector3.new(3, 0.3, 3),
		Vector3.new(17, 4.15, 6),
		Color3.fromRGB(255, 208, 116),
		origin,
		models[Building.GOAL_SURFACE],
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
		boundsMin = trackedMin,
		boundsMax = trackedMax,
		surfaces = surfaces,
		occluders = occluders,
		markers = markers,
		attachments = attachments,
		glow = glow,
		-- On surface A, facing -Z: the first seam is at the far end of the walkway. Expressed as an
		-- offset from the surface's own pivot below, so an edited map spawns on the moved walkway.
		spawnCF = models[Building.START_SURFACE]:GetPivot() * CFrame.new(0, 4, 6),
		goal = goal,
		centre = Vector3.new(7.5, 6, 0),
		destroy = function()
			folder:Destroy()
		end,
	}
	return handle
end

return Building
