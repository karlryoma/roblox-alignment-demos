--!strict
--[[
	Spin — the one stateful object, and the owner of FEEL.

	Holds the view-sphere point (yaw, pitch): the eye's direction expressed in the subject's
	local frame. TWO degrees of freedom, not three. The state is two numbers and the CFrame
	is rebuilt from scratch every frame, so it cannot shear, cannot accumulate, and its drag
	axes are screen-relative by construction — controls can never invert on the far side of
	an orbit, which is the classic post-multiplied-trackball bug.

	Drag deltas arrive already divided by viewport height. Resolution independence is
	enforced at that boundary, not hoped for.

	This module never touches UserInputService, a Camera, or a Model.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Damp = require(ReplicatedStorage.Shared.Damp)

local Spin = {}

export type Feel = {
	degPerScreenHeight: number, -- drag gain: a full screen-height drag turns this many degrees
	followTau: number, -- render follows the input target with this lag
	coastTauFar: number, -- inertia decay away from the solution
	coastTauNear: number, -- inertia decay inside the band (tightens, so it settles)
	maxDegPerSec: number,
	stopDegPerSec: number, -- below this the coast is hard-zeroed; creep ruins a steady glow
	pitchLimitDeg: number,
	gainFloor: number,
	gainCurve: number, -- gain = 1 - gainCurve * prox^2, floored
	snapTime: number,
}

export type Handle = {
	drag: (dxFrac: number, dyFrac: number) -> (),
	release: (velXFrac: number, velYFrac: number) -> (),
	step: (dt: number, prox: number) -> (number, number),
	snapTo: (yaw: number, pitch: number) -> (),
	isSnapping: () -> boolean,
	justLanded: () -> boolean,
	freeze: () -> (),
	set: (yaw: number, pitch: number) -> (),
	get: () -> (number, number),
}

function Spin.defaults(): Feel
	return {
		-- A full screen-height drag turns 300 degrees: 3.6 mouse pixels per degree at 1080p.
		degPerScreenHeight = 300,
		-- Under three frames at 60 Hz. Reads as zero latency, kills single-pixel jitter, and
		-- hands off to inertia continuously instead of with a seam at the release.
		followTau = 0.045,
		coastTauFar = 0.90,
		coastTauNear = 0.28,
		maxDegPerSec = 540,
		stopDegPerSec = 4,
		pitchLimitDeg = 80, -- off the poles, where the up-locked frame degenerates
		gainFloor = 0.35,
		gainCurve = 0.65,
		-- Monotonic, and no Back/Elastic: overshoot visibly un-aligns the anchors and dips
		-- the glow at the exact moment of payoff.
		snapTime = 0.18,
	}
end

function Spin.new(yaw: number, pitch: number, feel: Feel): Handle
	local curYaw, curPitch = yaw, pitch
	local tgtYaw, tgtPitch = yaw, pitch
	local velYaw, velPitch = 0, 0
	local pendX, pendY = 0, 0

	local snapping = false
	local snapT = 0
	local fromYaw, fromPitch = 0, 0
	local toYaw, toPitch = 0, 0
	local landed = false

	local pitchLimit = math.rad(feel.pitchLimitDeg)
	local maxVel = math.rad(feel.maxDegPerSec)
	local stopVel = math.rad(feel.stopDegPerSec)

	local handle: Handle = {
		drag = function(dxFrac: number, dyFrac: number)
			if snapping then
				return
			end
			-- A new drag is an explicit new intent, so it kills the previous flick. Leaving the
			-- coast running underneath means the box keeps drifting while the player is holding
			-- it still, which reads as the object fighting the hand.
			velYaw, velPitch = 0, 0
			pendX += dxFrac
			pendY += dyFrac
		end,

		release = function(velXFrac: number, velYFrac: number)
			if snapping then
				return
			end
			local scale = math.rad(feel.degPerScreenHeight)
			local vy = math.clamp(-velXFrac * scale, -maxVel, maxVel)
			local vp = math.clamp(velYFrac * scale, -maxVel, maxVel)
			velYaw = if math.abs(vy) < stopVel then 0 else vy
			velPitch = if math.abs(vp) < stopVel then 0 else vp
		end,

		step = function(dt: number, prox: number): (number, number)
			if snapping then
				snapT += dt
				local t = if feel.snapTime > 0 then math.clamp(snapT / feel.snapTime, 0, 1) else 1
				local e = Damp.easeOutQuint(t)
				curYaw = fromYaw + Damp.shortestArc(fromYaw, toYaw) * e
				curPitch = fromPitch + (toPitch - fromPitch) * e
				tgtYaw, tgtPitch = curYaw, curPitch
				velYaw, velPitch = 0, 0
				if t >= 1 then
					snapping = false
					landed = true
				end
				return curYaw, curPitch
			end

			-- Gain damping inside the band. The raw lock window is ~14 mouse pixels wide:
			-- mathematically correct and physically unhittable. Squaring the proximity keeps
			-- the damping imperceptible at the edge and strong only in the last degree, so it
			-- reads as the mechanism seating rather than as input lag. It never moves the
			-- object without input, which is the failure mode a magnetic detent has.
			local gain = math.max(feel.gainFloor, 1 - feel.gainCurve * prox * prox)
			local scale = math.rad(feel.degPerScreenHeight) * gain
			if pendX ~= 0 or pendY ~= 0 then
				tgtYaw -= pendX * scale
				tgtPitch = math.clamp(tgtPitch + pendY * scale, -pitchLimit, pitchLimit)
				pendX, pendY = 0, 0
			end

			if velYaw ~= 0 or velPitch ~= 0 then
				tgtYaw += velYaw * dt
				tgtPitch = math.clamp(tgtPitch + velPitch * dt, -pitchLimit, pitchLimit)
				local coastTau = feel.coastTauFar + (feel.coastTauNear - feel.coastTauFar) * math.clamp(prox, 0, 1)
				velYaw = Damp.decay(velYaw, dt, coastTau)
				velPitch = Damp.decay(velPitch, dt, coastTau)
				if math.abs(velYaw) < stopVel then
					velYaw = 0
				end
				if math.abs(velPitch) < stopVel then
					velPitch = 0
				end
			end

			local a = Damp.alpha(dt, feel.followTau)
			curYaw += Damp.shortestArc(curYaw, tgtYaw) * a
			curPitch += (tgtPitch - curPitch) * a
			return curYaw, curPitch
		end,

		snapTo = function(y: number, p: number)
			fromYaw, fromPitch = curYaw, curPitch
			toYaw, toPitch = y, p
			snapT = 0
			snapping = true
			landed = false
			pendX, pendY = 0, 0
			velYaw, velPitch = 0, 0
		end,

		isSnapping = function(): boolean
			return snapping
		end,

		justLanded = function(): boolean
			local l = landed
			landed = false
			return l
		end,

		freeze = function()
			velYaw, velPitch = 0, 0
			pendX, pendY = 0, 0
			tgtYaw, tgtPitch = curYaw, curPitch
		end,

		set = function(y: number, p: number)
			curYaw, curPitch = y, math.clamp(p, -pitchLimit, pitchLimit)
			tgtYaw, tgtPitch = curYaw, curPitch
			velYaw, velPitch = 0, 0
			pendX, pendY = 0, 0
			snapping = false
		end,

		get = function(): (number, number)
			return curYaw, curPitch
		end,
	}
	return handle
end

return Spin
