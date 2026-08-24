--!strict
--[[
	Feedback — escalation and reveal, driven by ONE smoothed proximity scalar plus edges.

	Every channel is rendered from the single render step, so no channel can desync from the
	rotation or from another channel. Channels are typed closures, not a string-keyed binding
	table: `property = "Brightnes"` in a config table passes luau-lsp happily and then needs a
	validator module to buy back what the type system was already giving away.

	Notes that are load-bearing rather than stylistic:
	  * Neon is unlit, so Color IS the intensity channel and the look is independent of the
	    sun. No Highlight anywhere: its DepthMode defaults to AlwaysOnTop, which x-rays the
	    object and destroys the exact depth relationship this puzzle is about.
	  * The hum is a 2D Sound on SoundService. A spatial sound 372 studs from the listener is
	    inaudible, and in demos 2-4 the orbit would modulate it.
	  * Emitters are configured explicitly, because the defaults throw a 25-stud cloud the
	    instant they are parented, and the commit burst uses :Emit rather than a Rate spike.
	  * No FieldOfView channel exists. At FOV 1 a change to 1.05 is a 5% zoom and it
	    invalidates the fit distance the whole rig is built on.

	Channels are applied in the order added, so a transient (pulse) added after a continuous
	one (glow) wins for the length of its window. That is deliberate.
]]

local TweenService = game:GetService("TweenService")

local Feedback = {}

export type Channel = (prox: number, dt: number) -> ()

export type Rig = {
	add: (ch: Channel) -> () -> (),
	on: (event: string, fn: () -> ()) -> (),
	render: (prox: number, dt: number) -> (),
	fire: (event: string) -> (),
	destroy: () -> (),
}

function Feedback.new(): Rig
	local channels: { Channel } = {}
	local handlers: { [string]: { () -> () } } = {}

	local rig: Rig = {
		add = function(ch: Channel): () -> ()
			table.insert(channels, ch)
			return function()
				local i = table.find(channels, ch)
				if i then
					table.remove(channels, i)
				end
			end
		end,

		on = function(event: string, fn: () -> ())
			local list = handlers[event]
			if not list then
				list = {}
				handlers[event] = list
			end
			table.insert(list, fn)
		end,

		render = function(prox: number, dt: number)
			for _, ch in channels do
				ch(prox, dt)
			end
		end,

		fire = function(event: string)
			local list = handlers[event]
			if not list then
				return
			end
			for _, fn in list do
				fn()
			end
		end,

		destroy = function()
			table.clear(channels)
			table.clear(handlers)
		end,
	}
	return rig
end

--[[ Cold -> hot on Neon parts, with an optional light. p^1.5 keeps the low end restrained. ]]
function Feedback.glow(parts: { BasePart }, cold: Color3, hot: Color3, light: PointLight?): Channel
	local maxBrightness = if light then light.Brightness else 0
	local maxRange = if light then light.Range else 0
	return function(prox: number, _dt: number)
		local p = math.clamp(prox, 0, 1) ^ 1.5
		local c = cold:Lerp(hot, p)
		for _, part in parts do
			part.Color = c
		end
		if light then
			light.Brightness = maxBrightness * p
			light.Range = maxRange * (0.55 + 0.45 * p)
		end
	end
end

--[[
	The hum. `sound` may be nil: with no asset id configured the demo runs silently and is
	one line away from working, which is better than inventing an id that resolves to
	somebody's unrelated upload.
]]
function Feedback.hum(sound: Sound?, loPitch: number, maxVolume: number): Channel
	return function(prox: number, _dt: number)
		if not sound then
			return
		end
		local p = math.clamp(prox, 0, 1)
		sound.Volume = maxVolume * p
		sound.PlaybackSpeed = loPitch + (1 - loPitch) * p
		if p > 0.02 then
			if not sound.IsPlaying then
				sound:Play()
			end
		elseif sound.IsPlaying then
			sound:Stop()
		end
	end
end

function Feedback.motes(emitters: { ParticleEmitter }, maxRate: number): Channel
	return function(prox: number, _dt: number)
		local p = math.clamp(prox, 0, 1)
		local rate = maxRate * p * p * p
		for _, e in emitters do
			e.Rate = rate
		end
	end
end

--[[
	Converging reticles. Deliberately NOT a line drawn between the anchors: that gives the
	answer away and turns a spatial read into a follow-the-dot. Each part retreats outward
	along its own RightVector when far, and seats into its rest pose at full proximity.
]]
function Feedback.halo(parts: { BasePart }, restCF: { CFrame }, maxStuds: number): Channel
	return function(prox: number, _dt: number)
		local away = (1 - math.clamp(prox, 0, 1)) * maxStuds
		for i, part in parts do
			local rest = restCF[i]
			if rest then
				part.CFrame = rest + rest.RightVector * away
			end
		end
	end
end

--[[ One-shot colour pulse. Returns the channel and its trigger; add it AFTER glow. ]]
function Feedback.pulse(parts: { BasePart }, hot: Color3, duration: number): (Channel, () -> ())
	local t = duration + 1
	local channel: Channel = function(_prox: number, dt: number)
		if t >= duration then
			return
		end
		t += dt
		local k = 1 - math.clamp(t / duration, 0, 1)
		for _, part in parts do
			part.Color = part.Color:Lerp(hot, k)
		end
	end
	return channel, function()
		t = 0
	end
end

function Feedback.burst(emitters: { ParticleEmitter }, count: number): () -> ()
	return function()
		for _, e in emitters do
			e:Emit(count)
		end
	end
end

--[[
	The hinged lid, ANGLE-driven and posed from the render step AFTER the pivot write.

	A CFrame in a Tween goal lerps the position along a chord while a hinge's centroid must
	travel an arc, so a tweened lid melts through the box body around the halfway mark.

	Model:PivotTo moves every descendant RIGIDLY by the pivot delta -- it does not restore
	authored offsets -- so a lid mid-sweep keeps whatever pose it was left in and then gets the
	frame's rotation applied on top. Re-posing it from the model's pivot after the write each
	frame is what makes the hinge arc authoritative rather than that accumulated rigid motion.

	Returns a poser: call it with the model's current pivot each frame; it returns true once
	the sweep has finished.
]]
function Feedback.lid(
	lid: BasePart,
	hingeLocal: CFrame,
	closedLocal: CFrame,
	sweepDeg: number,
	duration: number
): (rootCF: CFrame, dt: number) -> boolean
	local hingeToLid = hingeLocal:Inverse() * closedLocal
	local t = 0
	return function(rootCF: CFrame, dt: number): boolean
		t = math.min(t + dt, duration)
		local a = TweenService:GetValue(
			if duration > 0 then t / duration else 1,
			Enum.EasingStyle.Quint,
			Enum.EasingDirection.Out
		)
		local hinge = rootCF * hingeLocal
		lid.CFrame = hinge * CFrame.Angles(-math.rad(sweepDeg) * a, 0, 0) * hingeToLid
		return t >= duration
	end
end

return Feedback
