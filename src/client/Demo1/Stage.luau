--!strict
--[[
	Stage — the placeholder geometry, built entirely on the client.

	Nothing here is art. It exists so the demo runs in an empty Baseplate place with no
	Studio modelling step, and so every number that matters is visible in one file.

	Two conventions worth knowing before editing:
	  * Instance.new defaults are NOT Studio's insert defaults. Anchored, collision and
	    query flags, surfaces, and CastShadow are all set explicitly, BEFORE parenting.
	  * The two anchors are Attachments on an invisible Core part that IS the model's
	    PrimaryPart and sits at the pivot. Model:GetPivot returns the PrimaryPart's CFrame
	    rather than the WorldPivot you dragged in Studio, so making them the same thing
	    removes a whole class of "the puzzle is solvable but never locks" confusion.

	The near anchor is a RING and the far anchor is a PIP, sized so that "pip inside ring"
	happens at almost exactly the mechanical lock tolerance (0.063 studs of lateral offset at
	the fit distance). The eye and the mechanism agree, which is what makes the illusion read
	as fair rather than as a hidden trigger volume.
]]

local Stage = {}

export type Handle = {
	model: Model,
	core: BasePart,
	nearAnchor: Attachment, -- the ring (aperture)
	farAnchor: Attachment, -- the pip (bead)
	glowParts: { BasePart },
	glowLight: PointLight,
	emitters: { ParticleEmitter },
	haloParts: { BasePart },
	haloRest: { CFrame },
	lid: BasePart,
	lidClosedLocal: CFrame,
	lidHingeLocal: CFrame,
	prize: BasePart,
	prizeClosedLocal: CFrame,
	prizeOpenLocal: CFrame,
	destroy: () -> (),
}

local BOX = 3 -- stud edge of the cage
local BAR = 0.12
local RING_RADIUS = 0.16
local BEAD = 0.06
local PIP = 0.12
local ANCHOR_Z = 0.9 -- baseline L = 1.8, collinear with the pivot

local COLD = Color3.fromRGB(38, 74, 96)
local HOT = Color3.fromRGB(120, 240, 255)
local FRAME_COLOR = Color3.fromRGB(46, 48, 56)

local function newPart(
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--[[ Builds the box at `home`, already parented and posed. ]]
function Stage.build(home: CFrame, parent: Instance): Handle
	local folder = Instance.new("Folder")
	folder.Name = "Demo1Stage"

	local model = Instance.new("Model")
	model.Name = "PuzzleBox"
	model.Parent = folder

	local core = newPart("Core", Vector3.new(0.1, 0.1, 0.1), home, FRAME_COLOR, Enum.Material.SmoothPlastic, model)
	core.Transparency = 1
	model.PrimaryPart = core

	-- Cage: twelve edges, so the internals stay visible from every angle.
	local half = BOX / 2
	for _, sy in { -1, 1 } do
		for _, sz in { -1, 1 } do
			newPart(
				"BarX",
				Vector3.new(BOX, BAR, BAR),
				home * CFrame.new(0, half * sy, half * sz),
				FRAME_COLOR,
				Enum.Material.Metal,
				model
			)
		end
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			newPart(
				"BarY",
				Vector3.new(BAR, BOX, BAR),
				home * CFrame.new(half * sx, 0, half * sz),
				FRAME_COLOR,
				Enum.Material.Metal,
				model
			)
		end
	end
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			newPart(
				"BarZ",
				Vector3.new(BAR, BAR, BOX),
				home * CFrame.new(half * sx, half * sy, 0),
				FRAME_COLOR,
				Enum.Material.Metal,
				model
			)
		end
	end

	local glowParts: { BasePart } = {}

	-- NEAR anchor: a ring of beads in the plane perpendicular to the anchor axis, so it
	-- reads face-on exactly at the solution.
	local ringHub = newPart(
		"RingHub",
		Vector3.new(0.05, 0.05, 0.05),
		home * CFrame.new(0, 0, ANCHOR_Z),
		HOT,
		Enum.Material.Neon,
		model
	)
	ringHub.Transparency = 1
	local nearAnchor = Instance.new("Attachment")
	nearAnchor.Name = "NearAnchor"
	nearAnchor.Position = Vector3.new(0, 0, ANCHOR_Z)
	nearAnchor.Parent = core

	local beads = 16
	for i = 1, beads do
		local a = (i / beads) * math.pi * 2
		local bead = newPart(
			"Bead",
			Vector3.new(BEAD, BEAD, BEAD),
			home * CFrame.new(math.cos(a) * RING_RADIUS, math.sin(a) * RING_RADIUS, ANCHOR_Z),
			COLD,
			Enum.Material.Neon,
			model
		)
		bead.Shape = Enum.PartType.Ball
		table.insert(glowParts, bead)
	end
	-- Three struts, so the ring reads as mounted rather than floating.
	for i = 1, 3 do
		local a = (i / 3) * math.pi * 2
		local dir = Vector2.new(math.cos(a), math.sin(a))
		local outer = half - BAR * 0.5
		local mid = (RING_RADIUS + outer) * 0.5
		local len = math.max(outer - RING_RADIUS, 0.05)
		newPart(
			"Strut",
			Vector3.new(len, 0.05, 0.05),
			home * CFrame.new(dir.X * mid, dir.Y * mid, ANCHOR_Z) * CFrame.Angles(0, 0, a),
			FRAME_COLOR,
			Enum.Material.Metal,
			model
		)
	end

	-- FAR anchor: the pip, deep on the other side of the pivot.
	local pip = newPart(
		"Pip",
		Vector3.new(PIP, PIP, PIP),
		home * CFrame.new(0, 0, -ANCHOR_Z),
		COLD,
		Enum.Material.Neon,
		model
	)
	pip.Shape = Enum.PartType.Ball
	table.insert(glowParts, pip)
	newPart(
		"PipStem",
		Vector3.new(0.05, 0.05, half - ANCHOR_Z),
		home * CFrame.new(0, 0, -(ANCHOR_Z + (half - ANCHOR_Z) / 2)),
		FRAME_COLOR,
		Enum.Material.Metal,
		model
	)

	local farAnchor = Instance.new("Attachment")
	farAnchor.Name = "FarAnchor"
	farAnchor.Position = Vector3.new(0, 0, -ANCHOR_Z)
	farAnchor.Parent = core

	local glowLight = Instance.new("PointLight")
	glowLight.Brightness = 4
	glowLight.Range = 14
	glowLight.Color = HOT
	glowLight.Shadows = false
	glowLight.Parent = ringHub

	-- Motes. Everything explicit: the defaults throw a 25-stud cloud on parenting.
	local emitters: { ParticleEmitter } = {}
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.5, 1.1)
	emitter.Speed = NumberRange.new(0.2, 0.6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.06)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(HOT)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.LockedToPart = true -- demo 1 rotates the emitter with the object
	emitter.Parent = ringHub
	table.insert(emitters, emitter)

	-- Lid: one solid panel over the open cage, hinged on the back top edge.
	local lidClosedLocal = CFrame.new(0, half, 0)
	local lidHingeLocal = CFrame.new(0, half, -half + BAR * 0.5)
	local lid = newPart(
		"Lid",
		Vector3.new(BOX - BAR, 0.1, BOX - BAR),
		home * lidClosedLocal,
		Color3.fromRGB(64, 68, 78),
		Enum.Material.Metal,
		model
	)

	-- What is inside. Placeholder: the mechanism is the point.
	local prizeClosedLocal = CFrame.new(0, -0.35, 0) * CFrame.Angles(0, 0, math.rad(45))
	local prizeOpenLocal = CFrame.new(0, half + 0.55, 0) * CFrame.Angles(0, 0, math.rad(45))
	local prize = newPart(
		"Prize",
		Vector3.new(0.55, 0.55, 0.55),
		home * prizeClosedLocal,
		Color3.fromRGB(255, 196, 96),
		Enum.Material.Neon,
		model
	)

	-- Reticle: four bars that converge on the alignment point. Not a line between the
	-- anchors -- that would hand over the answer and turn a spatial read into follow-the-dot.
	local haloParts: { BasePart } = {}
	local haloRest: { CFrame } = {}
	local reticleAt = home * CFrame.new(0, 0, half + 1.2)
	for i = 0, 3 do
		local a = i * math.pi / 2
		local out = Vector3.new(math.cos(a), math.sin(a), 0)
		local rest = reticleAt * CFrame.new(out * 0.42) * CFrame.Angles(0, 0, a)
		local bar = newPart("Reticle", Vector3.new(0.22, 0.05, 0.05), rest, COLD, Enum.Material.Neon, folder)
		table.insert(haloParts, bar)
		table.insert(haloRest, rest)
		table.insert(glowParts, bar)
	end

	-- Backdrop. The frustum here is tiny -- distance/57.29 tall -- but portrait binds on the
	-- horizontal axis and sits further back, so this is sized for the worst case, which
	-- costs nothing.
	local backdrop = newPart(
		"Backdrop",
		Vector3.new(26, 26, 0.5),
		home * CFrame.new(0, 0, -18),
		Color3.fromRGB(14, 15, 19),
		Enum.Material.SmoothPlastic,
		folder
	)
	backdrop.CastShadow = false

	local key = Instance.new("PointLight")
	key.Brightness = 1.6
	key.Range = 26
	key.Color = Color3.fromRGB(226, 236, 255)
	key.Shadows = false
	key.Parent = newPart(
		"KeyLight",
		Vector3.new(0.1, 0.1, 0.1),
		home * CFrame.new(3.5, 3, 4),
		FRAME_COLOR,
		Enum.Material.SmoothPlastic,
		folder
	)

	folder.Parent = parent

	local handle: Handle = {
		model = model,
		core = core,
		nearAnchor = nearAnchor,
		farAnchor = farAnchor,
		glowParts = glowParts,
		glowLight = glowLight,
		emitters = emitters,
		haloParts = haloParts,
		haloRest = haloRest,
		lid = lid,
		lidClosedLocal = lidClosedLocal,
		lidHingeLocal = lidHingeLocal,
		prize = prize,
		prizeClosedLocal = prizeClosedLocal,
		prizeOpenLocal = prizeOpenLocal,
		destroy = function()
			folder:Destroy()
		end,
	}
	return handle
end

Stage.COLD = COLD
Stage.HOT = HOT

return Stage
