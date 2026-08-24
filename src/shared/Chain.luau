--!strict
--[[
	Chain — the staged-alignment contract, lifted out of demo 1 where it was a local type
	inside a function body and therefore impossible for a second demo to reuse.

	A Puzzle is one alignment: the anchor pair, the subject sphere that makes its tolerance
	dimensionless, its own thresholds, the mechanism it drives on commit, and what comes next.
	Returning another Puzzle from onSolved chains them. One alignment is a trick; alignment ->
	action -> new alignment is a system, and this is where that composition lives.

	THREE THINGS THIS FIXES that the demo-1 version got wrong, all of which fire on exactly the
	first chaining case:

	  * PER-STAGE PARAMETERS. Demo 1 passed one center/radius/minGap/slackFrac to probe() for
	    every stage, and built one gate for the whole session. Two stages in different parts of
	    a room have different baselines and want different feel, so all of it moves onto the
	    Puzzle and the gate is rebuilt per stage.

	  * A POSER LIST, not a slot. Demo 1 overwrote a single poser when the next stage began, so
	    stage 1's mechanism stopped being called. There it was survivable because PivotTo carried
	    the abandoned lid rigidly; in a world-scale demo where nothing pivots, the panel simply
	    freezes mid-slide.

	  * AIM FAILURES ARE NOT DISCARDED. Align.solve has four distinct failure strings, and demo 1
	    threw away the return value on the chained path, so a bad stage 2 silently kept stage 1's
	    snap target and became unsolvable with nothing printed.

	It also owns the ONE call to the destructive gate.edges(), so no second consumer can silently
	eat the locked edge, and the whole scoring pipeline (probe -> scored -> closeness -> asymmetric
	damping) so the two demos cannot drift on feel.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Align = require(ReplicatedStorage.Shared.Align)
local Damp = require(ReplicatedStorage.Shared.Damp)

local Chain = {}

export type Poser = (rootCF: CFrame, dt: number) -> boolean

export type Thresholds = {
	band: number, -- feedback onset
	arm: number, -- commit is accepted here, NEVER at the lock threshold
	enter: number, -- lock / full glow
	exit: number, -- lock releases (hysteresis)
	dwell: number, -- seconds armed before the prompt appears
	gamma: number, -- escalation curve
	attackTau: number,
	releaseTau: number,
}

export type Puzzle = {
	name: string,
	--[[ (near, far) in WORLD space, resolved live. A function, so a later stage's anchors may
	     be created at the moment the mechanism before it exposes them. ]]
	anchors: () -> (Vector3, Vector3),
	--[[ The subject sphere: the ANCHOR PAIR'S OWN neighbourhood, not the room's. Passing the
	     room puts the eye inside the sphere for the entire session, which reads as a working
	     tolerance while responding to nothing. Align.probe fails closed on it; this is the
	     authoring rule that stops you getting there. ]]
	sphere: () -> (Vector3, number),
	minGap: number, -- STUDS, not normalised: roughly half the baseline, per stage
	slackFrac: number,
	thresholds: Thresholds,
	--[[ Optional snap target, for demos whose commit re-poses the view. ]]
	solve: (() -> (number?, number?, string?))?,
	--[[ Optional line-of-sight test, ANDed into the score. Raycasts live at the call site:
	     Align is deliberately stateless and dependency-free. ]]
	visible: (() -> boolean)?,
	--[[ Runs once on commit. Returns a per-frame poser, or nil when the payoff IS the commit. ]]
	mechanism: (() -> Poser?)?,
	--[[ Return the successor, or nil to finish the chain. Called lazily at advance() time. ]]
	onSolved: (() -> Puzzle?)?,
}

export type Score = {
	sepNorm: number,
	prox: number, -- smoothed: what every feedback channel reads
	raw: number, -- unsmoothed: for anything that must not lag the input by a time constant
	state: Align.GateState,
	armed: boolean,
	enteredLocked: boolean,
	valid: boolean,
	eyeInside: boolean,
	occluded: boolean,
	subtendDeg: number,
}

export type Runner = {
	current: () -> Puzzle?,
	score: (dt: number, eye: Vector3, look: Vector3) -> Score,
	--[[ Drive the smoothed scalar without scoring: `hold` during a mechanism, `relax` in free
	     look. Both keep the single-scalar pipeline intact so no channel can desync. ]]
	hold: (dt: number) -> number,
	relax: (dt: number) -> number,
	prox: () -> number,
	aim: () -> (number?, number?, string?),
	beginMechanism: () -> (),
	pose: (root: CFrame, dt: number) -> boolean,
	advance: () -> (Puzzle?, string?),
	clearPosers: () -> (),
	reset: (first: Puzzle?) -> (),
}

function Chain.thresholds(band: number, arm: number, enter: number, exit: number): Thresholds
	return {
		band = band,
		arm = arm,
		enter = enter,
		exit = exit,
		dwell = 0.08,
		gamma = 2.2,
		attackTau = 0.05,
		releaseTau = 0.22,
	}
end

--[[
	Author the window you want in DEGREES, then divide once by the subject's apparent diameter.
	Thresholds are dimensionless everywhere they are consumed, and demo 1's numbers are not
	portable: feeding a raw 1.0 as `enter` is ~83x looser than demo 1, and feeding 8 as `band`
	makes closeness() saturate for every separation below 1 -- a ramp that is flat forever.
]]
function Chain.fromDegrees(bandDeg: number, armDeg: number, enterDeg: number, exitDeg: number, subtendDeg: number): Thresholds
	local d = if subtendDeg > 1e-6 then subtendDeg else 1
	return Chain.thresholds(bandDeg / d, armDeg / d, enterDeg / d, exitDeg / d)
end

function Chain.new(first: Puzzle?): Runner
	local currentPuzzle: Puzzle? = first
	local gate: Align.Gate? = nil
	local posers: { Poser } = {}
	local smoothed = 0

	local function rebuildGate()
		local puzzle = currentPuzzle
		if not puzzle then
			gate = nil
			return
		end
		local t = puzzle.thresholds
		gate = Align.newGate(t.enter, t.exit, t.arm, t.band, t.dwell)
	end
	rebuildGate()

	local function idleScore(): Score
		return {
			sepNorm = math.huge,
			prox = smoothed,
			raw = 0,
			state = "Idle" :: Align.GateState,
			armed = false,
			enteredLocked = false,
			valid = false,
			eyeInside = false,
			occluded = false,
			subtendDeg = 0,
		}
	end

	local runner: Runner
	runner = {
		current = function(): Puzzle?
			return currentPuzzle
		end,

		prox = function(): number
			return smoothed
		end,

		score = function(dt: number, eye: Vector3, look: Vector3): Score
			local puzzle = currentPuzzle
			local liveGate = gate
			if not puzzle or not liveGate then
				return idleScore()
			end

			local near, far = puzzle.anchors()
			local center, radius = puzzle.sphere()
			local p = Align.probe(eye, look, near, far, center, radius, puzzle.minGap, puzzle.slackFrac)

			-- The shipped consumption pattern, and it is not optional. p.valid does NOT include
			-- orderOk: two anchors at different depths coincide from two OPPOSITE directions and
			-- the angle carries no information about which branch you are on. A gate fed raw
			-- sepNorm locks from the wrong side, which a player walking freely reaches in seconds.
			local occluded = if puzzle.visible then not puzzle.visible() else false
			local scored = if p.valid and p.orderOk and not occluded then p.sepNorm else math.huge

			local t = puzzle.thresholds
			local raw = Align.closeness(scored, t.enter, t.band, t.gamma)
			smoothed = Damp.dampAsym(smoothed, raw, dt, t.attackTau, t.releaseTau)

			liveGate.update(scored, dt)
			local enteredLocked = select(1, liveGate.edges())

			return {
				sepNorm = scored,
				prox = smoothed,
				raw = raw,
				state = liveGate.state(),
				armed = liveGate.armed(),
				enteredLocked = enteredLocked,
				valid = p.valid,
				eyeInside = p.eyeInside,
				occluded = occluded,
				subtendDeg = p.subtendDeg,
			}
		end,

		hold = function(dt: number): number
			local puzzle = currentPuzzle
			local t = if puzzle then puzzle.thresholds else nil
			smoothed = Damp.dampAsym(smoothed, 1, dt, if t then t.attackTau else 0.05, if t then t.releaseTau else 0.22)
			return smoothed
		end,

		relax = function(dt: number): number
			local puzzle = currentPuzzle
			local t = if puzzle then puzzle.thresholds else nil
			smoothed = Damp.dampAsym(smoothed, 0, dt, if t then t.attackTau else 0.05, if t then t.releaseTau else 0.22)
			return smoothed
		end,

		aim = function(): (number?, number?, string?)
			local puzzle = currentPuzzle
			if not puzzle or not puzzle.solve then
				return nil, nil, nil
			end
			return puzzle.solve()
		end,

		beginMechanism = function()
			local puzzle = currentPuzzle
			if not puzzle or not puzzle.mechanism then
				return
			end
			local poser = puzzle.mechanism()
			if poser then
				table.insert(posers, poser)
			end
		end,

		--[[ Every poser runs every frame, forever. Returns whether the most recently added one
		     reported done, which is the edge a controller waits on. ]]
		pose = function(root: CFrame, dt: number): boolean
			local newestDone = false
			for i, poser in posers do
				local done = poser(root, dt)
				if i == #posers then
					newestDone = done
				end
			end
			return newestDone
		end,

		advance = function(): (Puzzle?, string?)
			local solved = currentPuzzle
			local nextPuzzle: Puzzle? = nil
			if solved and solved.onSolved then
				nextPuzzle = solved.onSolved()
			end
			currentPuzzle = nextPuzzle
			rebuildGate()
			if not nextPuzzle then
				return nil, nil
			end
			-- A chained stage's aim failure must be as loud as the first stage's.
			if nextPuzzle.solve then
				local yaw, pitch, why = nextPuzzle.solve()
				if not yaw or not pitch then
					return nextPuzzle, why or "stage has no reachable solution"
				end
			end
			return nextPuzzle, nil
		end,

		clearPosers = function()
			table.clear(posers)
		end,

		reset = function(firstAgain: Puzzle?)
			currentPuzzle = firstAgain
			table.clear(posers)
			smoothed = 0
			rebuildGate()
		end,
	}
	return runner
end

return Chain
