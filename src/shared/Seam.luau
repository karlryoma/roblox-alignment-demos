--!strict
--[[
	Seam — screen-space traversal: the core of demos 3 and 4.

	Two surfaces that COINCIDE ON SCREEN are connected, whatever their distance apart in world
	space. Walk off the edge of one and you continue onto the other. Nothing spawns, nothing
	moves, and there is no commit button: the building's connectivity is a function of the camera
	angle alone.

	THE TEST IS THE ANGLE SUBTENDED AT THE EYE, and that correction matters.

	An earlier version measured the idealised PARALLEL projection -- drop the depth component in
	camera space, no perspective divide -- on the theory that exact logic could not then inherit
	the rendering's approximation. That reasoning was backwards. Roblox renders in perspective, so
	two points that a parallel projection calls coincident are drawn apart by roughly
	(distance from frame centre) x (depth between them) / (camera distance). Near the middle of
	the frame that is a pixel or two; a seam composed ten studs off centre is visibly separated
	while the logic insists it is joined. The player judges the picture, so the picture is the
	authority.

	At a finite camera distance "the two points land on the same pixel" IS "the two points subtend
	no angle at the eye", which is what this measures. It agrees with the render everywhere in
	frame, it is independent of viewport size and aspect, and it is the same measure demos 1 and 2
	use -- so the whole repo now speaks one language.

	THE ORIENTATION RULE, which is what lets a crossing be free. Two nodes may only connect when
	their surfaces share an up-vector and their outward directions are opposite. Then the crossing
	is a PURE TRANSLATION: position, facing and velocity all carry over untouched, so the player
	walks through a seam without the character turning, stalling, or being re-solved by physics.
	Seam.orientationFault reports a mismatched pair, and callers are expected to fail loudly on it
	at authoring time: a mismatch produces a crossing that silently mangles velocity.

	WHAT COUNTS AS AN OCCLUDER. A coincidence hidden behind the architecture must not connect --
	Monument Valley requires the join to be visible. But a coincident pair necessarily has one
	surface in front of the other, so testing against the walkable surfaces themselves would
	reject every join by construction. The visibility ray therefore tests against an explicit
	occluder set: bulk geometry, never the surfaces that form the join or the markers that label
	it. Callers pass that set in.

	A GRAPH IS A SNAPSHOT. It is built for one camera pose and one arrangement of the geometry, and
	nothing in here notices when either changes -- Seam.cross re-reads live Attachment positions,
	so a stale graph would translate the character by an offset that no longer matches what is on
	screen. Any caller that moves a node's part (demo 4 rotates a sub-model) must clear the graph
	for the duration and install a freshly built one afterwards.

	Nothing here knows about any particular demo, or about Align: the angle subtended at the eye
	is the wrong measure for this. Coincidence under a parallel projection has no eye in it.
]]

local Seam = {}

--[[
	A node is an Attachment and nothing else, because the Attachment carries BOTH the position and
	the orientation:

	    outward = WorldCFrame.LookVector   the direction you walk to LEAVE this surface
	    normal  = WorldCFrame.UpVector     the surface up

	That is not a stylistic choice. A rotating sub-model turns its seams with it, and an outward
	direction stored as a plain Vector3 would keep pointing the old way -- the crossing would then
	translate the player along a direction the geometry no longer has. Deriving both from the
	Attachment makes a rotated seam correct for free.
]]
export type Node = {
	id: string,
	point: Attachment,
	--[[ Which surface the node belongs to, for the reachability report. ]]
	surface: string,
}

function Seam.outwardOf(node: Node): Vector3
	return node.point.WorldCFrame.LookVector
end

function Seam.normalOf(node: Node): Vector3
	return node.point.WorldCFrame.UpVector
end

export type Edge = {
	a: number,
	b: number,
	depthDelta: number, -- studs of depth jumped; the crossing is invisible, this is not
	screenGap: number, -- degrees of angular separation at the eye when this was built
}

export type Graph = {
	edges: { Edge },
	byNode: { [number]: { number } }, -- node index -> partner node indices
	rejectedHidden: number,
	rejectedOrientation: number,
	tested: number,
}

export type Options = {
	--[[ Degrees of angular separation at the eye that still counts as coincident. Convert from a
	     pixel budget with (px / viewportY) * fovDeg -- it is the same number in every viewport. ]]
	epsilonDeg: number,
	occluders: { Instance }, -- ONLY these block a sight line
	rayLength: number,
	backoff: number, -- stop the ray short, so a node's own surface is not "in front of" it
}

--[[
	Parallel projection, kept because framing maths wants it: fitting a camera distance to a
	bounding box is a question about the idealised projection, not about what connects. Screen
	position is in STUDS, the natural unit when there is no divide.

	It is NOT what decides connectivity -- see Seam.separationDeg.
]]
function Seam.project(worldPos: Vector3, camCF: CFrame): (Vector2, number)
	local p = camCF:PointToObjectSpace(worldPos)
	return Vector2.new(p.X, p.Y), -p.Z
end

--[[
	The angle the two points subtend at the eye, in degrees: zero exactly when they are drawn on
	the same pixel, at any distance and anywhere in frame.

	atan2 of the cross magnitude rather than acos of the dot: the sine has no cancellation near
	zero, which is the whole range that matters here. The components are read into Lua doubles
	before the subtraction because Vector3 is float32.
]]
function Seam.separationDeg(eye: Vector3, a: Vector3, b: Vector3): number
	local ex, ey, ez = eye.X, eye.Y, eye.Z
	local ax, ay, az = a.X - ex, a.Y - ey, a.Z - ez
	local bx, by, bz = b.X - ex, b.Y - ey, b.Z - ez
	local cx = ay * bz - az * by
	local cy = az * bx - ax * bz
	local cz = ax * by - ay * bx
	local cross = math.sqrt(cx * cx + cy * cy + cz * cz)
	local dot = ax * bx + ay * by + az * bz
	if cross == 0 and dot == 0 then
		return 180 -- the eye is sitting on a node: fail closed
	end
	local deg = math.deg(math.atan2(cross, dot))
	return if deg ~= deg then 180 else deg
end

--[[ How many pixels a given angular separation covers, for readouts. ]]
function Seam.degToPixels(deg: number, fovDeg: number, viewportY: number): number
	if fovDeg <= 0 then
		return 0
	end
	return (deg / fovDeg) * viewportY
end

function Seam.defaults(): Options
	return {
		-- ~0.13 deg is about 23 px of a 1080p frame at FOV 6.
		epsilonDeg = 0.13,
		occluders = {},
		rayLength = 600,
		backoff = 0.75,
	}
end

--[[
	Authoring assertion. A pair whose normals differ, or whose outward directions are not
	opposite, cannot be crossed by a pure translation -- the character would arrive facing the
	wrong way or moving off the edge it just arrived on. Returns nil when the pair is legal, or
	the reason it is not.
]]
function Seam.orientationFault(a: Node, b: Node): string?
	-- Normalised here rather than trusted: an un-normalised pair can pass a raw dot-product
	-- threshold at an angle nowhere near 180 degrees, and the crossing would then be a
	-- translation the player feels as a shove.
	-- Both come off a CFrame, so they are unit by construction; the checks below mean what they
	-- say without any normalising.
	--[[ 0.985 (~10 deg), not 0.999 (~2.6 deg). The editor's TILT is a sanctioned authoring move
	     and its coarse step is 2 deg -- under the old tolerance two presses disqualified a seam
	     FOREVER while it still lined up on screen, which read as "the game is broken". The
	     crossing itself is a pure translation, so a sub-10-deg mouth mismatch changes nothing the
	     player can feel; the check still exists to catch genuinely wrong pairings (perpendicular
	     walls, same-facing mouths), which fail it by 90 deg, not 4. ]]
	if Seam.normalOf(a):Dot(Seam.normalOf(b)) < 0.985 then
		return `normals differ ({a.id} vs {b.id})`
	end
	if Seam.outwardOf(a):Dot(Seam.outwardOf(b)) > -0.985 then
		return `outward directions are not opposite ({a.id} vs {b.id})`
	end
	return nil
end

--[[
	Builds the live connectivity for one camera pose. O(n^2) over a few dozen nodes: trivial, and
	it runs once per settle rather than per frame.
]]
function Seam.build(nodes: { Node }, camCF: CFrame, options: Options): Graph
	local count = #nodes
	local eye = camCF.Position
	local depth: { number } = table.create(count)
	for i, node in nodes do
		local _, d = Seam.project(node.point.WorldPosition, camCF)
		depth[i] = d
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = options.occluders
	params.RespectCanCollide = false -- decorative non-colliding scenery still hides a join
	params.IgnoreWater = true

	local axis = camCF.LookVector
	local visible: { boolean } = table.create(count)
	for i, node in nodes do
		local target = node.point.WorldPosition
		local from = target - axis * options.rayLength
		local span = options.rayLength - options.backoff
		visible[i] = workspace:Raycast(from, axis * span, params) == nil
	end

	local graph: Graph = {
		edges = {},
		byNode = {},
		rejectedHidden = 0,
		rejectedOrientation = 0,
		tested = 0,
	}
	for i = 1, count do
		graph.byNode[i] = {}
	end

	for a = 1, count - 1 do
		for b = a + 1, count do
			local gap = Seam.separationDeg(eye, nodes[a].point.WorldPosition, nodes[b].point.WorldPosition)
			if gap <= options.epsilonDeg then
				graph.tested += 1
				if Seam.orientationFault(nodes[a], nodes[b]) then
					graph.rejectedOrientation += 1
				elseif not (visible[a] and visible[b]) then
					graph.rejectedHidden += 1
				else
					table.insert(graph.edges, {
						a = a,
						b = b,
						depthDelta = math.abs(depth[a] - depth[b]),
						screenGap = gap,
					})
					table.insert(graph.byNode[a], b)
					table.insert(graph.byNode[b], a)
				end
			end
		end
	end
	return graph
end

--[[
	Reachability over physical adjacency PLUS the live seams, for the boot report and for the
	"does any single camera angle solve it" check. `realEdges` are surface-name pairs that are
	physically joined at every angle.
]]
function Seam.reachableSurfaces(
	nodes: { Node },
	realEdges: { { string } },
	graph: Graph,
	from: string
): { [string]: boolean }
	local adj: { [string]: { string } } = {}
	local function link(x: string, y: string)
		local list = adj[x]
		if not list then
			list = {}
			adj[x] = list
		end
		table.insert(list, y)
	end
	for _, pair in realEdges do
		link(pair[1], pair[2])
		link(pair[2], pair[1])
	end
	for _, edge in graph.edges do
		link(nodes[edge.a].surface, nodes[edge.b].surface)
		link(nodes[edge.b].surface, nodes[edge.a].surface)
	end

	local seen: { [string]: boolean } = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local at = queue[head]
		head += 1
		local neighbours = adj[at]
		if neighbours then
			for _, next_ in neighbours do
				if not seen[next_] then
					seen[next_] = true
					table.insert(queue, next_)
				end
			end
		end
	end
	return seen
end

--[[
	THE CROSSING. A pure translation, applied in ONE frame with no interpolation: Roblox gives no
	per-object depth sorting, so a character straddling two depths cannot be rendered correctly.
	Monument Valley snaps for the same reason.

	The velocity is deliberately NOT zeroed. With matched orientations the world velocity is
	already correct after a translation, and zeroing it would turn a smooth walk into a stumble --
	which is the whole thing this design exists to avoid.
]]
function Seam.cross(character: Model, from: Node, to: Node)
	local offset = to.point.WorldPosition - from.point.WorldPosition
	character:PivotTo(character:GetPivot() + offset)
end

--------------------------------------------------------------------------------
-- the per-frame traverser
--------------------------------------------------------------------------------

export type Traverser = {
	--[[ Installs the live graph. Pass the character too and any node whose mouth already contains
	     it is DISARMED until the character leaves -- which is what stops someone standing on a
	     seam from being flung the instant it goes live. ]]
	setGraph: (graph: Graph?, character: Model?) -> (),
	step: (dt: number, character: Model) -> Edge?,
	lastCrossed: () -> number?,
}

export type TraverserOptions = {
	--[[ Lateral half-extent of the seam mouth. Match it to the marker the player can see: a
	     trigger narrower than its own light reads as the seam being broken. ]]
	halfWidth: number,
	--[[ How far ABOVE the node plane the HumanoidRootPart may be. The root floats a rig-dependent
	     ~3 studs over the floor the node sits on (R15 HipHeight ~2 plus half a 2-stud root), so
	     this is a band, not a radius -- measuring a sphere from the node would spend the whole
	     budget on that constant and leave a mouth narrower than the marker. ]]
	heightTolerance: number,
	minApproachSpeed: number, -- studs/s along the outward direction
	cooldown: number,
}

function Seam.traverserDefaults(): TraverserOptions
	return {
		halfWidth = 2.6,
		heightTolerance = 4.5,
		-- Real outward motion, not mere presence.
		minApproachSpeed = 1.5,
		cooldown = 0.25,
	}
end

--[[
	THE TRIGGER IS A PLANE CROSSING, NOT A PROXIMITY SPHERE, and that is load-bearing.

	Firing on "near the node" fires EARLY, while the character is still short of the edge. Because
	paired nodes have opposite outward directions, being d studs SHORT of the source edge maps to
	d studs PAST the destination edge -- the character is translated into empty air just beyond
	the surface it was supposed to land on, and falls. Firing on the moment the signed distance
	along `outward` goes from negative to non-negative bounds that error to a single frame of
	travel (~0.27 studs at WalkSpeed 16 / 60 fps), which lands the character just INSIDE the
	destination instead.
]]
function Seam.newTraverser(nodes: { Node }, options: TraverserOptions): Traverser
	local live: Graph? = nil
	local cooling = 0
	local crossedIndex: number? = nil
	local previousAlong: { [number]: number } = {}
	local disarmed: { [number]: boolean } = {}

	--[[ Where the root sits relative to one node, in that node's own frame. ]]
	local function measure(at: Vector3, node: Node): (number, number, boolean)
		local frame = node.point.WorldCFrame
		local outward, normal = frame.LookVector, frame.UpVector
		local delta = at - frame.Position
		local along = delta:Dot(outward)
		local height = delta:Dot(normal)
		local lateral = (delta - outward * along - normal * height).Magnitude
		local inMouth = height >= 0
			and height <= options.heightTolerance
			and lateral <= options.halfWidth
		return along, height, inMouth
	end

	local function rootOf(character: Model): BasePart?
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
		return nil
	end

	local traverser: Traverser = {
		setGraph = function(graph: Graph?, character: Model?)
			live = graph
			table.clear(disarmed)
			if graph and character then
				local root = rootOf(character)
				if root then
					for i, node in nodes do
						local along, _, inMouth = measure(root.Position, node)
						-- Only what the player is already standing AT OR PAST. Disarming everything
						-- merely inside the mouth would kill the seam for someone waiting at the lip
						-- for the world to connect -- which is precisely the player this is for.
						if inMouth and along >= 0 then
							disarmed[i] = true
						end
					end
				end
			end
		end,

		lastCrossed = function(): number?
			return crossedIndex
		end,

		step = function(dt: number, character: Model): Edge?
			cooling = math.max(cooling - dt, 0)
			local graph = live
			local root = if graph then rootOf(character) else nil
			if not graph or not root then
				table.clear(previousAlong)
				return nil
			end

			local at = root.Position
			local velocity = root.AssemblyLinearVelocity

			-- One pass over every node, so the sign transition is tracked even for nodes that are
			-- not currently part of an edge.
			local along: { number } = table.create(#nodes)
			local inside: { boolean } = table.create(#nodes)
			for i, node in nodes do
				local a, _, inMouth = measure(at, node)
				along[i] = a
				inside[i] = inMouth
				-- A disarmed node re-arms once the character has actually left its mouth.
				if disarmed[i] and (not inMouth or a < -0.5) then
					disarmed[i] = nil
				end
			end

			local crossed: Edge? = nil
			if cooling <= 0 then
				for _, edge in graph.edges do
					for _, order in { { edge.a, edge.b }, { edge.b, edge.a } } do
						local fromIndex, toIndex = order[1], order[2]
						local previous = previousAlong[fromIndex]
						if
							inside[fromIndex]
							and not disarmed[fromIndex]
							and previous ~= nil
							and previous < 0
							and along[fromIndex] >= 0
							and velocity:Dot(Seam.outwardOf(nodes[fromIndex])) >= options.minApproachSpeed
						then
							Seam.cross(character, nodes[fromIndex], nodes[toIndex])
							cooling = options.cooldown
							crossedIndex = toIndex
							crossed = edge
							break
						end
					end
					if crossed then
						break
					end
				end
			end

			if crossed then
				-- The character has moved; last frame's signed distances describe a place it is no
				-- longer in, and keeping them would let the arrival node fire on the next frame.
				table.clear(previousAlong)
			else
				for i = 1, #nodes do
					previousAlong[i] = along[i]
				end
			end
			return crossed
		end,
	}
	return traverser
end

return Seam
