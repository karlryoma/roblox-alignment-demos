--!strict
--[[
	Damp — framerate-independent smoothing and easing.

	Every damped quantity in the project goes through alpha(dt, tau) = 1 - exp(-dt/tau).
	No `lerp(v, target, 0.15)` and no `vel *= 0.9` may appear anywhere else: those are
	framerate-DEPENDENT, invisible on the machine they were tuned on, and obvious to
	anyone watching the demo at 144 Hz.

	clampDt is called exactly ONCE per frame, at the top of the loop, and its result is
	passed to every consumer. Three clamps with three values is how that bug comes back.
]]

local Damp = {}

-- An alt-tab or an asset-load hitch produces a huge dt that flings any integrator.
local MAX_DT = 1 / 20

function Damp.clampDt(dt: number): number
	if dt ~= dt then
		return 1 / 60
	end
	return math.clamp(dt, 0, MAX_DT)
end

function Damp.alpha(dt: number, tau: number): number
	if tau <= 0 then
		return 1
	end
	return 1 - math.exp(-dt / tau)
end

function Damp.damp(current: number, target: number, dt: number, tau: number): number
	return current + (target - current) * Damp.alpha(dt, tau)
end

-- Attack/release pair. Fast toward, slow away: the proximity signal reads as caused by
-- the player on the way in, and leaves a fading trail rather than strobing on the way out.
function Damp.dampAsym(
	current: number,
	target: number,
	dt: number,
	attackTau: number,
	releaseTau: number
): number
	local tau = if target > current then attackTau else releaseTau
	return Damp.damp(current, target, dt, tau)
end

function Damp.decay(value: number, dt: number, tau: number): number
	if tau <= 0 then
		return 0
	end
	return value * math.exp(-dt / tau)
end

function Damp.ewma(current: Vector2, sample: Vector2, dt: number, tau: number): Vector2
	return current + (sample - current) * Damp.alpha(dt, tau)
end

function Damp.easeOutQuint(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u * u * u
end

-- Deliberately unclamped: the overshoot is wanted on a scale pop, fatal on a transparency.
function Damp.easeOutBack(t: number, overshoot: number?): number
	local s = overshoot or 1.70158
	local u = math.clamp(t, 0, 1) - 1
	return u * u * ((s + 1) * u + s) + 1
end

-- Signed shortest angular delta, radians. Used so a snap across the yaw wrap takes the
-- short way round instead of unwinding 350 degrees.
function Damp.shortestArc(from: number, to: number): number
	local tau = 2 * math.pi
	local d = (to - from) % tau
	if d > math.pi then
		d -= tau
	end
	return d
end

return Damp
