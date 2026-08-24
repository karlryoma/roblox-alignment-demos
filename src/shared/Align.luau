--!strict
--[[
	Align — pure alignment geometry for perspective-coincidence puzzles.

	No Instances, no Camera, no state except one small gate closure. This is the module
	that is identical across all four demos: probe() runs in WORLD space against whatever
	pose was actually written this frame, so it does not care whether the object moved
	(demo 1) or the camera did (demos 2-4).

	WHY atan2 AND NOT acos(dot)
	---------------------------
	The obvious test is acos(ua:Dot(ub)). At this rig it is not merely imprecise, it is
	pure noise. The lock tolerance is 0.009667 degrees, and

		1 - cos(0.009667 deg) = 1.42e-8
		one float32 ULP at 1.0 = 2^-23 = 1.19e-7

	so the entire lock threshold sits 8x BELOW one representable step of the cosine, and
	Vector3 components are float32. acos would report a hard 0.000000 for everything inside
	~0.028 degrees and quantise the feedback ramp into about twelve visible bands.

	atan2(|a x b|, a . b) is driven by the sine, which suffers no cancellation near zero.
	The components are read off the Vector3s into Lua doubles BEFORE the eye subtraction,
	and are deliberately not unit-normalised first: the magnitudes cancel inside atan2, which
	saves two square roots and removes a NaN source. Resolution is then ~3e-6 degrees, four
	orders of magnitude finer than the tolerance. Align.selfTest() prints the comparison.

	Everything fails CLOSED: a degenerate eye returns 180 degrees, never 0 and never NaN.
	NaN <= tolerance is false, so a poisoned value would silently stop the mechanism forever.
]]

local Align = {}

export type Probe = {
	sepDeg: number, -- angle subtended at the eye by the two anchors, degrees
	sepNorm: number, -- sepDeg / the subject's apparent angular diameter (the tolerance unit)
	orderOk: boolean, -- the authored near anchor really is nearer, by at least minGap
	inFront: boolean, -- both anchors are in front of the eye
	depthGap: number, -- studs
	valid: boolean, -- false => sepDeg has been forced to 180
}

export type GateState = "Idle" | "Warm" | "Armed" | "Locked"

export type Gate = {
	update: (sepNorm: number, dt: number) -> (),
	state: () -> GateState,
	armed: () -> boolean,
	edges: () -> (boolean, boolean),
	reset: () -> (),
}

local EPS = 1e-6

--[[ Angle subtended at `eye` by world points `a` and `b`, in degrees. ]]
function Align.angleDeg(eye: Vector3, a: Vector3, b: Vector3): number
	local ex, ey, ez = eye.X, eye.Y, eye.Z
	local ax, ay, az = a.X - ex, a.Y - ey, a.Z - ez
	local bx, by, bz = b.X - ex, b.Y - ey, b.Z - ez

	local cx = ay * bz - az * by
	local cy = az * bx - ax * bz
	local cz = ax * by - ay * bx
	local cross = math.sqrt(cx * cx + cy * cy + cz * cz)
	local dot = ax * bx + ay * by + az * bz

	if cross == 0 and dot == 0 then
		return 180 -- the eye is sitting on an anchor: fail closed
	end
	local deg = math.deg(math.atan2(cross, dot))
	if deg ~= deg then
		return 180
	end
	return deg
end

--[[ Apparent angular diameter of a sphere of `radius` at `center`, seen from `eye`. ]]
function Align.subtendDeg(eye: Vector3, center: Vector3, radius: number): number
	local d = (center - eye).Magnitude
	if d < EPS or d <= radius or radius <= 0 then
		return 180
	end
	return math.deg(2 * math.atan(radius / d))
end

--[[
	The full per-frame measurement.

	Two anchors at different depths coincide from TWO opposite directions, and read 180
	degrees (not 0) when the eye is between them, so the angle alone carries no information
	about which branch you are on. Three named predicates ride alongside it:
	depth ORDER, both-in-FRONT, and a minimum depth GAP. `look` is the eye's forward
	direction, used only for the in-front test.

	`slackFrac` is the containment allowance, in the SAME unit as the thresholds (a fraction
	of the subject's apparent diameter) and applied AFTER the division. If the near feature is
	a ring of visible radius R1 and the far one a pip of R2, the eye reads them as coincident
	anywhere inside (R1 - R2)/distance radians; dividing that by the subtend makes it survive
	a change of rig, which an absolute-degree allowance would not. 0 = the mechanism is exact.
]]
function Align.probe(
	eye: Vector3,
	look: Vector3,
	near: Vector3,
	far: Vector3,
	center: Vector3,
	radius: number,
	minGap: number,
	slackFrac: number
): Probe
	local toNear = near - eye
	local toFar = far - eye
	local dNear = toNear.Magnitude
	local dFar = toFar.Magnitude

	local inFront = toNear:Dot(look) > 0 and toFar:Dot(look) > 0
	local depthGap = dFar - dNear
	local orderOk = depthGap >= minGap

	local subtend = Align.subtendDeg(eye, center, radius)
	local valid = inFront and subtend > EPS and dNear > EPS and dFar > EPS

	if not valid then
		return {
			sepDeg = 180,
			sepNorm = math.huge,
			orderOk = orderOk,
			inFront = inFront,
			depthGap = depthGap,
			valid = false,
		}
	end

	local sepDeg = Align.angleDeg(eye, near, far)
	return {
		sepDeg = sepDeg,
		sepNorm = math.max(sepDeg / subtend - slackFrac, 0),
		orderOk = orderOk,
		inFront = inFront,
		depthGap = depthGap,
		valid = true,
	}
end

--[[
	Proximity 0..1 from the normalised separation. gamma > 1 back-loads the drama, so the
	halfway point of the approach reads as a faint shimmer rather than half a light show.
]]
function Align.closeness(sepNorm: number, enterFrac: number, bandFrac: number, gamma: number): number
	if sepNorm ~= sepNorm then
		return 0
	end
	if bandFrac <= enterFrac then
		return if sepNorm <= enterFrac then 1 else 0
	end
	local t = math.clamp((bandFrac - sepNorm) / (bandFrac - enterFrac), 0, 1)
	return t ^ gamma
end

--[[
	View-sphere point <-> direction. This pair is the single glue value between input and
	rendering: the state of a puzzle is two numbers, never an accumulated CFrame.

	Roll is deliberately absent. Rolling about the eye-pivot axis is an isometry fixing the
	eye, so it preserves every angle subtended there and provably cannot solve the puzzle.
	A third degree of freedom would spend a third of the player's input on a direction that
	cannot help, and would drag in the whole "it locked while upside down" failure class.
]]
function Align.fromSpherical(yaw: number, pitch: number, radius: number): Vector3
	local cp = math.cos(pitch)
	return Vector3.new(radius * cp * math.sin(yaw), radius * math.sin(pitch), radius * cp * math.cos(yaw))
end

function Align.toSpherical(dir: Vector3): (number, number)
	local m = dir.Magnitude
	if m < EPS then
		return 0, 0
	end
	local u = dir / m
	return math.atan2(u.X, u.Z), math.asin(math.clamp(u.Y, -1, 1))
end

--[[
	The solved view-sphere point, DERIVED from the anchors rather than authored.

	Two sources of truth disagreeing by a fraction of a degree is exactly the jank that sinks
	a showcase, and an authored pose silently rots the moment someone nudges an anchor. This
	intersects the anchor line with the view sphere, filters the roots by the same depth-order
	rule probe() uses, and then re-probes at its own answer: that check catches off-pivot
	anchor authoring empirically, with no residual formula to get wrong.

	Returns (yaw, pitch, nil) or (nil, nil, reason).
]]
function Align.solve(
	nearLocal: Vector3,
	farLocal: Vector3,
	radius: number,
	pitchLimit: number
): (number?, number?, string?)
	local axis = nearLocal - farLocal
	local baseline = axis.Magnitude
	if baseline < 1e-4 then
		return nil, nil, "anchors are coincident"
	end
	local u = axis / baseline

	-- Closest point on the anchor line to the pivot, then the two sphere intersections.
	local p0 = farLocal - u * farLocal:Dot(u)
	local h2 = radius * radius - p0:Dot(p0)
	if h2 <= 0 then
		return nil, nil, "the anchor line misses the view sphere"
	end
	local h = math.sqrt(h2)
	local rootA = p0 + u * h
	local rootB = p0 - u * h

	-- Same rule as probe(): the authored near anchor must be the nearer one.
	local eye = if (rootA - nearLocal).Magnitude < (rootA - farLocal).Magnitude then rootA else rootB
	if (eye - nearLocal).Magnitude >= (eye - farLocal).Magnitude then
		return nil, nil, "neither root puts the near anchor in front"
	end

	local yaw, pitch = Align.toSpherical(eye)
	if math.abs(pitch) > pitchLimit then
		return nil, nil, string.format("solution pitch %.1f deg is outside the clamp", math.deg(pitch))
	end

	return yaw, pitch, nil
end

--[[
	Authoring aids only. At FieldOfView f the viewport's vertical extent is exactly f
	degrees, so a fraction of screen height converts straight to degrees. Never store the
	result: the fit distance is refit on aspect change, so a fixed screen fraction silently
	changes difficulty between landscape and portrait. sepNorm does not.
]]
function Align.fracToDeg(frac: number, fovDeg: number): number
	return frac * fovDeg
end

function Align.degToFrac(deg: number, fovDeg: number): number
	if fovDeg <= 0 then
		return math.huge
	end
	return deg / fovDeg
end

--[[
	Schmitt trigger + dwell. All four demos need identical behaviour here: a single-threshold
	commit prompt flickering while the player parks on the boundary is exactly the fiddliness
	that sinks the review, and the arm threshold is deliberately much wider than the lock so
	a click at the visually perfect moment is never refused.
]]
function Align.newGate(
	enterFrac: number,
	exitFrac: number,
	armFrac: number,
	bandFrac: number,
	dwell: number
): Gate
	local locked = false
	local armedFor = 0
	local lastSep = math.huge
	local enteredLocked = false
	local leftLocked = false

	local function isArmed(): boolean
		return armedFor >= dwell
	end

	local gate: Gate = {
		update = function(sepNorm: number, dt: number)
			lastSep = sepNorm
			if sepNorm <= armFrac then
				armedFor += dt
			else
				armedFor = 0
			end
			if locked then
				if sepNorm > exitFrac then
					locked = false
					leftLocked = true
				end
			elseif sepNorm <= enterFrac then
				locked = true
				enteredLocked = true
			end
		end,

		state = function(): GateState
			if locked then
				return "Locked"
			elseif isArmed() then
				return "Armed"
			elseif lastSep <= bandFrac then
				return "Warm"
			end
			return "Idle"
		end,

		armed = isArmed,

		edges = function(): (boolean, boolean)
			local a, b = enteredLocked, leftLocked
			enteredLocked, leftLocked = false, false
			return a, b
		end,

		reset = function()
			locked = false
			armedFor = 0
			lastSep = math.huge
			enteredLocked = false
			leftLocked = false
		end,
	}
	return gate
end

--[[
	Three lines that justify the whole atan2 decision. Called once at boot; the output is
	part of what makes this a showcase piece rather than a black box.
]]
function Align.selfTest(): string
	local eye = Vector3.new(0, 0, 0)
	local d = 372.4
	local target = 0.01 -- degrees
	local half = math.tan(math.rad(target) * 0.5) * d
	local a = Vector3.new(-half, 0, d)
	local b = Vector3.new(half, 0, d)

	local ua = (a - eye).Unit
	local ub = (b - eye).Unit
	local viaAcos = math.deg(math.acos(math.clamp(ua:Dot(ub), -1, 1)))
	local viaAtan2 = Align.angleDeg(eye, a, b)

	return string.format("a true %.4f deg reads %.6f via acos(dot) and %.6f via atan2(cross, dot)", target, viaAcos, viaAtan2)
end

return Align
