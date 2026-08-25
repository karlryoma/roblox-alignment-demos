--!strict
--[[
	Level — demo 4's diorama, its node set, and the rotatable sub-model.

	Authored as the MECHANIC, not as Monument Valley's levels: a tribute tech study is normal,
	but reproducing ustwo's actual level designs is both the version that attracts a takedown
	and the smaller claim. "I rebuilt their system" beats "I rebuilt their level".

	Everything is axis-aligned boxes on purpose, so the geometry can be verified outside Roblox
	by mirroring the same numbers.

	FLAT-SHADED BY DESIGN. At ~1,700 studs shadows are effectively dead under any lighting
	technology, so the look leans on SmoothPlastic with hand-picked per-face colours to fake the
	ambient occlusion that the renderer will not provide, plus Neon for anything that must read
	regardless. That is Monument Valley's look anyway.

	COORDINATES are local to the region. The node set was chosen so that the impossible joins
	are EXACT under the isometric projection: two nodes coincide on screen in the 45-degree state
	exactly when their difference is parallel to (1,1,1), in the 135-degree state when it is
	parallel to (1,1,-1), and so on. Authoring a join is therefore adding (k,k,k) to a node --
	no fitting, no epsilon-chasing.
]]

local Level = {}

export type Node = {
	id: string,
	pos: Vector3, -- local; the walkable surface
}

export type Handle = {
	folder: Folder,
	--[[ The AABB of every part actually built, in LOCAL coordinates. The camera fit is measured
	     against this rather than against the node points: the columns hang below the tiles they
	     carry, and a fit that only sees nodes slices them off the bottom of the frame. ]]
	boundsMin: Vector3,
	boundsMax: Vector3,
	tiles: Folder, -- excluded from the visibility ray: see the note in init
	occluders: Folder, -- bulk geometry that DOES hide a join
	rotor: Model,
	setRotor: (turns: number) -> (), -- fractional turns, for the tween
	centre: Vector3,
	destroy: () -> (),
}

-- Static nodes, in a fixed order: every graph is indexed by these positions.
local NODES: { Node } = {
	{ id = "start", pos = Vector3.new(0, 0, 0) },
	{ id = "walk-1", pos = Vector3.new(0, 0, -4) },
	{ id = "walk-2", pos = Vector3.new(0, 0, -8) },
	{ id = "stair-1", pos = Vector3.new(4, 4, -12) },
	{ id = "stair-2", pos = Vector3.new(4, 6, -16) },
	{ id = "stair-3", pos = Vector3.new(4, 8, -20) },
	{ id = "ledge", pos = Vector3.new(10, 8, -20) },
	{ id = "upper-1", pos = Vector3.new(16, 14, -14) },
	{ id = "upper-2", pos = Vector3.new(16, 14, -10) },
	{ id = "goal", pos = Vector3.new(16, 14, -6) },
	{ id = "lookout", pos = Vector3.new(-4, 4, -12) },
	{ id = "spur", pos = Vector3.new(-7, 7, -9) },
	--[[ Two decoy stones that coincide in the 225-degree state, with one of them hidden behind
	     the stair's own support column from exactly that angle -- so the bake REJECTS the join.
	     They exist to prove the visibility rule is load-bearing rather than a no-op.

	     Two things are deliberate. They are paired with EACH OTHER rather than with a walkable
	     node, because rejecting a coincidence means hiding one of its ends and hiding a node the
	     puppet stands on would hide the puppet. And the thing that hides one of them is the
	     EXISTING stair column, not a prop added for the purpose -- so the demonstration costs no
	     extra geometry and no frame budget. ]]
	{ id = "decoy-near", pos = Vector3.new(0, 5, -18) },
	{ id = "decoy-far", pos = Vector3.new(4, 1, -14) },
}
Level.NODES = NODES

-- Physical adjacency, by index into NODES. It holds in every state.
local REAL: { { number } } = {
	{ 1, 2 },
	{ 2, 3 },
	{ 4, 5 },
	{ 5, 6 },
	{ 8, 9 },
	{ 9, 10 },
}
Level.REAL = REAL

Level.ROTOR_PIVOT = Vector3.new(7, 8, -20)
--[[ Deliberately unequal. A straight bridge across a gap necessarily docks in both its 0 and 2
     positions -- that is what "spans the gap" means -- but unequal arms at least make the four
     states tell themselves apart on screen. ]]
Level.ROTOR_ARM_A = 2.4
Level.ROTOR_ARM_C = 2.8
Level.DOCK_DISTANCE = 2.5
Level.START_INDEX = 1
Level.GOAL_INDEX = 10

--[[ The rotor's three nodes at a given whole-turn state. Appended after the static ones. ]]
function Level.rotorNodes(turns: number): { Vector3 }
	local rot = CFrame.Angles(0, math.rad(90 * turns), 0)
	local a = rot * Vector3.new(-Level.ROTOR_ARM_A, 0, 0)
	local c = rot * Vector3.new(Level.ROTOR_ARM_C, 0, 0)
	return { Level.ROTOR_PIVOT + a, Level.ROTOR_PIVOT, Level.ROTOR_PIVOT + c }
end

--[[ Every node position for a rotor state: static ones first, then the rotor's. ]]
function Level.positions(turns: number): { Vector3 }
	local out: { Vector3 } = {}
	for _, node in NODES do
		table.insert(out, node.pos)
	end
	for _, p in Level.rotorNodes(turns) do
		table.insert(out, p)
	end
	return out
end

--[[
	Real edges for a rotor state: the authored ones, the rotor's own spine, plus DOCKING --
	a rotor end close enough to a static node counts as physically joined. Docking is what makes
	the sub-model a mechanism rather than scenery: turned across the gap it bridges two nodes,
	turned along it, it bridges nothing.
]]
function Level.realEdges(turns: number): { { number } }
	local out: { { number } } = {}
	for _, pair in REAL do
		table.insert(out, { pair[1], pair[2] })
	end
	local base = #NODES
	table.insert(out, { base + 1, base + 2 })
	table.insert(out, { base + 2, base + 3 })

	local rotor = Level.rotorNodes(turns)
	for offset, endPos in { [1] = rotor[1], [3] = rotor[3] } do
		for i, node in NODES do
			if (node.pos - endPos).Magnitude <= Level.DOCK_DISTANCE then
				table.insert(out, { base + offset, i })
			end
		end
	end
	return out
end

local SAND = Color3.fromRGB(226, 206, 178)
local ROSE = Color3.fromRGB(206, 142, 150)
local TEAL = Color3.fromRGB(112, 176, 176)
local SHADE = Color3.fromRGB(158, 140, 124)
local GOLD = Color3.fromRGB(255, 208, 112)

local trackedMin = Vector3.new(math.huge, math.huge, math.huge)
local trackedMax = Vector3.new(-math.huge, -math.huge, -math.huge)

local function box(
	name: string,
	size: Vector3,
	at: Vector3,
	colour: Color3,
	origin: CFrame,
	parent: Instance,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = origin * CFrame.new(at)
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false -- nothing here is walked on by a Humanoid; the puppet is CFramed
	p.CanTouch = false
	p.CanQuery = true -- the visibility bake raycasts against these
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

	local tiles = Instance.new("Folder")
	tiles.Name = "Tiles"
	tiles.Parent = folder

	local occluders = Instance.new("Folder")
	occluders.Name = "Occluders"
	occluders.Parent = folder

	-- One tile per node, its TOP face at the node's height.
	for i, node in NODES do
		local colour = if i == Level.GOAL_INDEX then GOLD elseif i >= 11 then TEAL else SAND
		local tile = box(
			node.id,
			Vector3.new(4, 0.6, 4),
			node.pos - Vector3.new(0, 0.3, 0),
			colour,
			origin,
			tiles,
			if i == Level.GOAL_INDEX then Enum.Material.Neon else nil
		)
		-- A skirt under each tile, in a darker tone: the whole look is fake ambient occlusion.
		if i ~= Level.GOAL_INDEX then
			box(node.id .. "-skirt", Vector3.new(3.6, 1.4, 3.6), node.pos - Vector3.new(0, 1.3, 0), SHADE, origin, tiles)
		end
		tile.Name = node.id
	end

	-- Support columns, so the diorama reads as architecture rather than floating tiles. They are
	-- OCCLUDERS: a join hidden behind one is correctly rejected by the bake.
	-- Kept short on purpose: the camera distance is fitted to the geometry, so a column that
	-- hangs 8 studs below the lowest tile costs real frame budget for decoration.
	box("col-start", Vector3.new(2.4, 3, 2.4), Vector3.new(0, -1.8, -4), ROSE, origin, occluders)
	box("col-stair", Vector3.new(2.4, 6, 2.4), Vector3.new(4, 1.4, -16), ROSE, origin, occluders)
	box("col-upper", Vector3.new(2.4, 10, 2.4), Vector3.new(16, 8.7, -10), ROSE, origin, occluders)
	box("col-ledge", Vector3.new(2.0, 6, 2.0), Vector3.new(10, 4.7, -20), TEAL, origin, occluders)

	-- The rotatable sub-model: a bridge that spans the gap in two of its four positions.
	local rotor = Instance.new("Model")
	rotor.Name = "Rotor"
	box("hub", Vector3.new(1.6, 1.0, 1.6), Level.ROTOR_PIVOT - Vector3.new(0, 0.5, 0), TEAL, origin, rotor)
	-- NO PrimaryPart. Model:GetPivot returns the PrimaryPart's CFrame when one is set, which
	-- would make PivotTo(home * rot) place the HUB at home and lift the whole bridge by the hub's
	-- half-height -- putting the geometry half a stud above the nodes the graph is built from.
	-- With no PrimaryPart the pivot is WorldPivot, which is exactly the axis we want.
	-- 0.05 below the tile tops it meets. Exactly coplanar faces z-fight badly at ~1,900 studs,
	-- where the depth buffer is coarse; the puppet stands on rotorNodes, not on this surface.
	box("deck", Vector3.new(5.6, 0.5, 2.2), Level.ROTOR_PIVOT - Vector3.new(0, 0.30, 0), TEAL, origin, rotor)
	box("rail", Vector3.new(5.6, 0.5, 0.3), Level.ROTOR_PIVOT + Vector3.new(0, 0.4, 1.1), SAND, origin, rotor)
	box("rail2", Vector3.new(5.6, 0.5, 0.3), Level.ROTOR_PIVOT + Vector3.new(0, 0.4, -1.1), SAND, origin, rotor)
	rotor.Parent = folder

	local home = origin * CFrame.new(Level.ROTOR_PIVOT)
	local function setRotor(turns: number)
		rotor:PivotTo(home * CFrame.Angles(0, math.rad(90 * turns), 0))
	end
	-- The model was authored around the pivot, so its parts are already in the right place at 0.
	rotor.WorldPivot = home
	setRotor(0)

	folder.Parent = parent

	local xs, ys, zs = {}, {}, {}
	for _, node in NODES do
		table.insert(xs, node.pos.X)
		table.insert(ys, node.pos.Y)
		table.insert(zs, node.pos.Z)
	end
	local function mid(t: { number }): number
		local lo, hi = math.huge, -math.huge
		for _, v in t do
			lo = math.min(lo, v)
			hi = math.max(hi, v)
		end
		return (lo + hi) / 2
	end

	local handle: Handle = {
		folder = folder,
		boundsMin = trackedMin,
		boundsMax = trackedMax,
		tiles = tiles,
		occluders = occluders,
		rotor = rotor,
		setRotor = setRotor,
		centre = Vector3.new(mid(xs), mid(ys), mid(zs)),
		destroy = function()
			folder:Destroy()
		end,
	}
	return handle
end

return Level
