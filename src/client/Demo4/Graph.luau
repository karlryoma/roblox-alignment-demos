--!strict
--[[
	Graph — the baker and the runtime lookup for demo 4.

	THE ARCHITECTURAL POINT OF THE WHOLE DEMO: the camera snaps to a small number of fixed
	angles, so there are only a small number of connectivity graphs. Bake them all. That
	decouples two things that look coupled:

	  * RENDERING uses the FOV-1 near-orthographic approximation, and only has to fool the eye.
	  * GAMEPLAY LOGIC uses a mathematically EXACT orthographic projection computed here.

	So the illusion being approximate never leaks into correctness. There is no runtime
	screen-space measurement, no floating-point drift across frames, and no per-frame cost: a
	click is answered by a table lookup and a BFS over at most a few dozen edges.

	Nothing in this module knows about Align. The angle subtended at the eye -- the measure
	demos 1-3 are built on -- is the wrong question here. Monument Valley asks whether two
	things LAND ON THE SAME PIXEL under a parallel projection, which is a different predicate
	with no eye in it at all.
]]

local Graph = {}

export type Baked = {
	adj: { { number } },
	realCount: number,
	virtualCount: number,
	virtualPairs: { { number } },
	hiddenCount: number, -- coincidences rejected because a node was not visible
}

--[[
	Exact orthographic projection: drop the depth component in camera space. Returns the screen
	position in STUDS (not pixels -- this is a parallel projection, so studs are the natural
	unit and there is no viewport to divide by) and the depth along the view axis.

	Depth is irrelevant to connectivity. That is the entire trick. It is returned anyway,
	because crossing a virtual edge IS a depth jump and the traversal needs to know.
]]
function Graph.project(worldPos: Vector3, camCF: CFrame): (Vector2, number)
	local p = camCF:PointToObjectSpace(worldPos)
	return Vector2.new(p.X, p.Y), -p.Z
end

--[[
	Bakes one connectivity graph.

	`realPairs` is authored physical adjacency, which exists in every state. `visible(i)` is the
	caller's occlusion test -- a raycast, kept out here so this module stays pure. A coincidence
	whose nodes are not both genuinely visible is REJECTED and counted: Monument Valley requires
	the join to be seen, not merely to exist in the projection.
]]
function Graph.bake(
	positions: { Vector3 },
	realPairs: { { number } },
	camCF: CFrame,
	epsilon: number,
	visible: (index: number) -> boolean
): Baked
	local n = #positions
	local adj: { { number } } = table.create(n)
	for i = 1, n do
		adj[i] = {}
	end

	local function link(a: number, b: number)
		table.insert(adj[a], b)
		table.insert(adj[b], a)
	end

	local linked: { [number]: boolean } = {}
	local function key(a: number, b: number): number
		local lo, hi = math.min(a, b), math.max(a, b)
		return lo * 1000 + hi
	end

	local realCount = 0
	for _, pair in realPairs do
		local a, b = pair[1], pair[2]
		if a ~= b and not linked[key(a, b)] then
			linked[key(a, b)] = true
			link(a, b)
			realCount += 1
		end
	end

	local screen: { Vector2 } = table.create(n)
	for i = 1, n do
		screen[i] = (Graph.project(positions[i], camCF))
	end

	local seen: { boolean } = table.create(n)
	for i = 1, n do
		seen[i] = visible(i)
	end

	local virtualPairs: { { number } } = {}
	local hidden = 0
	for a = 1, n - 1 do
		for b = a + 1, n do
			if not linked[key(a, b)] and (screen[a] - screen[b]).Magnitude <= epsilon then
				if seen[a] and seen[b] then
					linked[key(a, b)] = true
					link(a, b)
					table.insert(virtualPairs, { a, b })
				else
					hidden += 1
				end
			end
		end
	end

	return {
		adj = adj,
		realCount = realCount,
		virtualCount = #virtualPairs,
		virtualPairs = virtualPairs,
		hiddenCount = hidden,
	}
end

--[[ Shortest path by edge count. Returns nil when the target is unreachable in this state. ]]
function Graph.path(adj: { { number } }, from: number, to: number): { number }?
	if from == to then
		return { from }
	end
	local prev: { [number]: number } = {}
	local seen: { [number]: boolean } = { [from] = true }
	local queue = { from }
	local head = 1

	while head <= #queue do
		local node = queue[head]
		head += 1
		for _, next_ in adj[node] do
			if not seen[next_] then
				seen[next_] = true
				prev[next_] = node
				if next_ == to then
					local path = { to }
					local walk = to
					while walk ~= from do
						walk = prev[walk]
						table.insert(path, 1, walk)
					end
					return path
				end
				table.insert(queue, next_)
			end
		end
	end
	return nil
end

--[[ Everything reachable from `from`, for the boot report. ]]
function Graph.reachable(adj: { { number } }, from: number): { [number]: boolean }
	local seen: { [number]: boolean } = { [from] = true }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local node = queue[head]
		head += 1
		for _, next_ in adj[node] do
			if not seen[next_] then
				seen[next_] = true
				table.insert(queue, next_)
			end
		end
	end
	return seen
end

--[[ Is this edge a virtual one? The traversal SNAPS across those and walks the rest. ]]
function Graph.isVirtual(baked: Baked, a: number, b: number): boolean
	for _, pair in baked.virtualPairs do
		if (pair[1] == a and pair[2] == b) or (pair[1] == b and pair[2] == a) then
			return true
		end
	end
	return false
end

return Graph
