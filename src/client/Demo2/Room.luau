--!strict
--[[
	Room — demo 2's placeholder geometry, built on the client.

	TWO ENGINE FACTS SHAPE THIS FILE:

	1. CanQuery. Demo 1's part factory sets CanQuery = false on everything, which is right for a
	   subject nothing ever raycasts. Copy that here and the occlusion test silently always
	   passes. So walls, pillars, the panel and the door are built with CanQuery = TRUE, and only
	   the markers -- which must not block the ray drawn to themselves -- keep it false.

	2. An enclosed windowless room under ShadowMap/Future renders near-black. The markers are
	   Neon, which is unlit and therefore sun-independent, and the room carries its own lights.

	Never a Highlight anywhere: DepthMode defaults to AlwaysOnTop, which x-rays the object and
	destroys the exact depth relationship the puzzle is about. "A wall panel that was locked" is
	precisely where the temptation lands.

	LOCAL COORDINATES: interior x [-14, 14], z [-10, 10], y [0, 14].
]]

local Room = {}

export type Handle = {
	folder: Folder,
	markers: { Instance }, -- excluded from occlusion rays
	stage1Near: BasePart,
	stage1Far: BasePart,
	stage1Glow: { BasePart },
	stage2Near: BasePart,
	stage2Far: BasePart,
	stage2Glow: { BasePart },
	panel: BasePart,
	panelClosed: CFrame,
	panelAxis: Vector3,
	panelTravel: number,
	bolts: { BasePart },
	door: BasePart,
	doorClosed: CFrame,
	doorOpen: CFrame,
	spawnCF: CFrame,
	emitters: { ParticleEmitter },
	destroy: () -> (),
}

Room.COLD = Color3.fromRGB(40, 78, 100)
Room.HOT = Color3.fromRGB(125, 242, 255)
Room.AMBER = Color3.fromRGB(255, 196, 110)

local SHELL = Color3.fromRGB(52, 55, 63)
local TRIM = Color3.fromRGB(38, 41, 48)

-- Stage 1: high in the room, short baseline along Z. Placed so the ORBIT CAMERA can never get
-- inside the subject sphere: the camera sits 13 studs from a focus ~5 studs up, and the pair is
-- 6+ studs above that, so even at maximum pitch the eye stays ~8 studs from the sphere centre.
local S1_X, S1_Y, S1_HALF = -2, 11.2, 2.5
-- Stage 2: inside the alcove, behind the wall plane, so the eye is outside its sphere by
-- construction -- the player cannot walk in and the camera collides with the wall.
local S2_Y, S2_NEAR_X, S2_FAR_X = 6.5, 15.6, 18.6

function Room.stage1Anchors(): (Vector3, Vector3)
	return Vector3.new(S1_X, S1_Y, S1_HALF), Vector3.new(S1_X, S1_Y, -S1_HALF)
end

function Room.stage2Anchors(): (Vector3, Vector3)
	return Vector3.new(S2_NEAR_X, S2_Y, 0), Vector3.new(S2_FAR_X, S2_Y, 0)
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
	p.CanCollide = canQuery -- occluders are also the things worth colliding with
	p.CanTouch = false
	p.CanQuery = canQuery
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function ring(
	origin: CFrame,
	center: Vector3,
	axis: Vector3,
	radius: number,
	bead: number,
	parent: Instance,
	markers: { Instance },
	glow: { BasePart }
): Part
	local hub = newPart("RingHub", Vector3.new(0.1, 0.1, 0.1), origin * CFrame.new(center), Room.HOT, Enum.Material.Neon, false, parent)
	hub.Transparency = 1
	table.insert(markers, hub)

	-- A frame whose LookVector is the anchor axis, so the ring reads face-on at the solution.
	local frame = CFrame.lookAt(center, center + axis)
	for i = 1, 14 do
		local a = (i / 14) * math.pi * 2
		local offset = frame * CFrame.new(math.cos(a) * radius, math.sin(a) * radius, 0)
		local b = newPart("Bead", Vector3.new(bead, bead, bead), origin * offset, Room.COLD, Enum.Material.Neon, false, parent)
		b.Shape = Enum.PartType.Ball
		table.insert(markers, b)
		table.insert(glow, b)
	end
	return hub
end

local function pip(origin: CFrame, center: Vector3, size: number, parent: Instance, markers: { Instance }, glow: { BasePart }): Part
	local p = newPart("Pip", Vector3.new(size, size, size), origin * CFrame.new(center), Room.COLD, Enum.Material.Neon, false, parent)
	p.Shape = Enum.PartType.Ball
	table.insert(markers, p)
	table.insert(glow, p)
	return p
end

function Room.build(origin: CFrame, parent: Instance): Handle
	local folder = Instance.new("Folder")
	folder.Name = "Demo2Room"

	local markers: { Instance } = {}
	local stage1Glow: { BasePart } = {}
	local stage2Glow: { BasePart } = {}

	--------------------------------------------------------------------------------
	-- shell
	--------------------------------------------------------------------------------
	newPart("Floor", Vector3.new(30, 1, 22), origin * CFrame.new(0, -0.5, 0), TRIM, Enum.Material.Slate, true, folder)
	newPart("Ceiling", Vector3.new(30, 1, 22), origin * CFrame.new(0, 14.5, 0), TRIM, Enum.Material.Slate, true, folder)
	newPart("WallWest", Vector3.new(1, 14, 22), origin * CFrame.new(-14.5, 7, 0), SHELL, Enum.Material.Concrete, true, folder)
	newPart("WallNorth", Vector3.new(30, 14, 1), origin * CFrame.new(0, 7, 10.5), SHELL, Enum.Material.Concrete, true, folder)

	-- South wall, with the doorway
	newPart("WallSouthL", Vector3.new(11.5, 14, 1), origin * CFrame.new(-8.75, 7, -10.5), SHELL, Enum.Material.Concrete, true, folder)
	newPart("WallSouthR", Vector3.new(11.5, 14, 1), origin * CFrame.new(8.75, 7, -10.5), SHELL, Enum.Material.Concrete, true, folder)
	newPart("Lintel", Vector3.new(6, 6, 1), origin * CFrame.new(0, 11, -10.5), SHELL, Enum.Material.Concrete, true, folder)

	-- East wall, with the alcove opening (z in [-2.5, 2.5], y in [4.5, 8.5])
	newPart("WallEastS", Vector3.new(1, 14, 8), origin * CFrame.new(14.5, 7, -6.5), SHELL, Enum.Material.Concrete, true, folder)
	newPart("WallEastN", Vector3.new(1, 14, 8), origin * CFrame.new(14.5, 7, 6.5), SHELL, Enum.Material.Concrete, true, folder)
	newPart("WallEastLow", Vector3.new(1, 4.5, 5), origin * CFrame.new(14.5, 2.25, 0), SHELL, Enum.Material.Concrete, true, folder)
	newPart("WallEastHigh", Vector3.new(1, 5.5, 5), origin * CFrame.new(14.5, 11.25, 0), SHELL, Enum.Material.Concrete, true, folder)

	-- The alcove behind it
	newPart("AlcoveBack", Vector3.new(1, 6, 7), origin * CFrame.new(20, 6.5, 0), TRIM, Enum.Material.Concrete, true, folder)
	newPart("AlcoveTop", Vector3.new(6, 1, 7), origin * CFrame.new(17.5, 9, 0), TRIM, Enum.Material.Concrete, true, folder)
	newPart("AlcoveBottom", Vector3.new(6, 1, 7), origin * CFrame.new(17.5, 4, 0), TRIM, Enum.Material.Concrete, true, folder)
	newPart("AlcoveS", Vector3.new(6, 6, 1), origin * CFrame.new(17.5, 6.5, -3), TRIM, Enum.Material.Concrete, true, folder)
	newPart("AlcoveN", Vector3.new(6, 6, 1), origin * CFrame.new(17.5, 6.5, 3), TRIM, Enum.Material.Concrete, true, folder)

	--------------------------------------------------------------------------------
	-- lights: an enclosed room is otherwise near-black under ShadowMap
	--------------------------------------------------------------------------------
	for _, z in { -6, 0, 6 } do
		local strip = newPart(
			"Strip",
			Vector3.new(9, 0.2, 0.8),
			origin * CFrame.new(0, 13.9, z),
			Color3.fromRGB(226, 236, 255),
			Enum.Material.Neon,
			false,
			folder
		)
		local light = Instance.new("PointLight")
		light.Brightness = 1.5
		light.Range = 32
		light.Color = Color3.fromRGB(214, 228, 255)
		light.Shadows = false
		light.Parent = strip
	end

	--------------------------------------------------------------------------------
	-- stage 1 markers, hung from the ceiling
	--------------------------------------------------------------------------------
	local near1 = Vector3.new(S1_X, S1_Y, S1_HALF)
	local far1 = Vector3.new(S1_X, S1_Y, -S1_HALF)
	for _, at in { near1, far1 } do
		newPart(
			"Hanger",
			Vector3.new(0.12, 14 - at.Y, 0.12),
			origin * CFrame.new(at.X, (14 + at.Y) / 2, at.Z),
			TRIM,
			Enum.Material.Metal,
			true,
			folder
		)
	end
	local stage1Near = ring(origin, near1, Vector3.new(0, 0, 1), 0.5, 0.12, folder, markers, stage1Glow)
	local stage1Far = pip(origin, far1, 0.36, folder, markers, stage1Glow)

	--------------------------------------------------------------------------------
	-- stage 2 markers, inside the alcove
	--------------------------------------------------------------------------------
	local near2, far2 = Room.stage2Anchors()
	local stage2Near = ring(origin, near2, Vector3.new(1, 0, 0), 0.45, 0.1, folder, markers, stage2Glow)
	local stage2Far = pip(origin, far2, 0.4, folder, markers, stage2Glow)

	--------------------------------------------------------------------------------
	-- the panel that locks the alcove, and its bolts
	--------------------------------------------------------------------------------
	local panelClosed = origin * CFrame.new(14.1, 6.5, 0)
	local panel = newPart("Panel", Vector3.new(0.5, 4.2, 5.2), panelClosed, Color3.fromRGB(74, 79, 90), Enum.Material.Metal, true, folder)

	local bolts: { BasePart } = {}
	for _, z in { -1.7, 1.7 } do
		for _, y in { -1.5, 1.5 } do
			local bolt = newPart(
				"Bolt",
				Vector3.new(0.6, 0.28, 0.28),
				panelClosed * CFrame.new(-0.2, y, z),
				Room.AMBER,
				Enum.Material.Neon,
				false,
				folder
			)
			table.insert(bolts, bolt)
			table.insert(markers, bolt)
		end
	end

	--------------------------------------------------------------------------------
	-- the door the second alignment opens
	--------------------------------------------------------------------------------
	local doorClosed = origin * CFrame.new(0, 4, -10.5)
	local door = newPart("Door", Vector3.new(6, 8, 0.6), doorClosed, Color3.fromRGB(66, 71, 82), Enum.Material.Metal, true, folder)
	local doorOpen = origin * CFrame.new(0, 12.2, -10.5)

	--------------------------------------------------------------------------------
	-- motes at each marker pair
	--------------------------------------------------------------------------------
	local emitters: { ParticleEmitter } = {}
	for _, host in { stage1Near, stage2Near } do
		local e = Instance.new("ParticleEmitter")
		e.Rate = 0 -- the defaults throw a 25-stud cloud the instant it is parented
		e.Lifetime = NumberRange.new(0.6, 1.3)
		e.Speed = NumberRange.new(0.3, 0.9)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Size = NumberSequence.new(0.18)
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		e.Color = ColorSequence.new(Room.HOT)
		e.LightEmission = 1
		e.LightInfluence = 0
		e.LockedToPart = true
		e.Parent = host
		table.insert(emitters, e)
	end

	folder.Parent = parent

	local handle: Handle = {
		folder = folder,
		markers = markers,
		stage1Near = stage1Near,
		stage1Far = stage1Far,
		stage1Glow = stage1Glow,
		stage2Near = stage2Near,
		stage2Far = stage2Far,
		stage2Glow = stage2Glow,
		panel = panel,
		panelClosed = panelClosed,
		panelAxis = origin:VectorToWorldSpace(Vector3.new(0, 0, 1)), -- local +Z: slides north
		panelTravel = 5.4,
		bolts = bolts,
		door = door,
		doorClosed = doorClosed,
		doorOpen = doorOpen,
		spawnCF = origin * CFrame.new(-2, 3.5, 7) * CFrame.Angles(0, math.rad(180), 0),
		emitters = emitters,
		destroy = function()
			folder:Destroy()
		end,
	}
	return handle
end

return Room
