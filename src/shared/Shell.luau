--!strict
--[[
	Shell — the contract between the menu shell and a demo, plus the global state a demo must
	not own.

	The rule that motivates the whole module: a demo may not snapshot global state. Lighting,
	the RenderStep bind namespace and the character are shared across every demo and across
	menu round-trips, so exactly one owner takes them and hands out scoped leases.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Shell = {}

export type Context = {
	player: Player,
	camera: Camera,
	playerGui: Instance,
	--[[ Unique per demo. Bind names are ONE GLOBAL NAMESPACE: a second demo reusing a string
	     silently unbinds the first, with no warning. ]]
	bindName: string,
	--[[ Return to the menu. Always go through this, never through your own teardown, or the
	     shell's global restores (mouse, camera subject, lighting) never run. ]]
	exit: () -> (),
	--[[ Move the character, velocity zeroed, facing a direction. Shell-owned because respawn
	     is the shell's problem. ]]
	place: (cf: CFrame) -> (),
	--[[ Per-effect opt-in. Returns the undo. ]]
	dim: (profile: DimProfile) -> () -> (),
	--[[ Called with the fresh character when the player respawns while THIS demo is running.
	     Respawn is the shell's problem, not a demo's -- but a demo that follows the avatar has
	     to re-acquire it. ]]
	onCharacter: (fn: (character: Model) -> ()) -> (),
}

export type DimProfile = {
	depthOfField: boolean?,
	atmosphere: boolean?,
	fog: boolean?,
}

export type Controller = {
	id: string,
	title: string,
	blurb: string,
	ready: boolean, -- false renders as a locked slot in the menu
	region: CFrame, -- where in the world this demo lives
	start: (ctx: Context) -> boolean,
	stop: () -> (),
}

--------------------------------------------------------------------------------
-- RenderStep bind names
--------------------------------------------------------------------------------

local claimed: { [string]: boolean } = {}

function Shell.claimBind(name: string): string
	if claimed[name] then
		-- Loud, because the failure it prevents is silent: RunService replaces the existing
		-- closure and the first demo simply stops updating.
		error(`[shell] RenderStep bind name "{name}" is already claimed`, 2)
	end
	claimed[name] = true
	return name
end

function Shell.releaseBind(name: string)
	claimed[name] = nil
	RunService:UnbindFromRenderStep(name)
end

--------------------------------------------------------------------------------
-- lighting
--------------------------------------------------------------------------------

--[[
	Per-effect, because demo 1's blanket version is wrong for an interior. Killing all
	DepthOfField, zeroing every Atmosphere and pushing fog to 1e6 is correct for a 3-stud
	subject 372 studs away in the void, and would flatten a room demo into a lit box.
]]
function Shell.dim(profile: DimProfile): () -> ()
	local undo: { () -> () } = {}

	if profile.depthOfField then
		for _, inst in Lighting:GetDescendants() do
			if inst:IsA("DepthOfFieldEffect") and inst.Enabled then
				inst.Enabled = false
				table.insert(undo, function()
					inst.Enabled = true
				end)
			end
		end
	end

	if profile.atmosphere then
		for _, inst in Lighting:GetDescendants() do
			if inst:IsA("Atmosphere") then
				local density, haze = inst.Density, inst.Haze
				inst.Density, inst.Haze = 0, 0
				table.insert(undo, function()
					inst.Density, inst.Haze = density, haze
				end)
			end
		end
	end

	if profile.fog then
		local fogEnd, fogStart = Lighting.FogEnd, Lighting.FogStart
		Lighting.FogEnd, Lighting.FogStart = 1e6, 1e6
		table.insert(undo, function()
			Lighting.FogEnd, Lighting.FogStart = fogEnd, fogStart
		end)
	end

	return function()
		for _, fn in undo do
			fn()
		end
	end
end

--------------------------------------------------------------------------------
-- character
--------------------------------------------------------------------------------

--[[
	Freeze the character in place.

	NOT via Player.DevComputerMovementMode / DevTouchMovementMode: they need the RobloxScript
	capability and THROW from an ordinary LocalScript, aborting the session. And never via
	PlayerModule, which luau-lsp cannot resolve through the sourcemap.
]]
function Shell.holdCharacter(player: Player): () -> ()
	local undo: { () -> () } = {}
	local character = player.Character

	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local walkSpeed, jumpHeight = humanoid.WalkSpeed, humanoid.JumpHeight
			local jumpPower, autoRotate = humanoid.JumpPower, humanoid.AutoRotate
			humanoid.WalkSpeed = 0
			humanoid.JumpHeight = 0
			humanoid.JumpPower = 0
			humanoid.AutoRotate = false
			table.insert(undo, function()
				if humanoid.Parent then
					humanoid.WalkSpeed = walkSpeed
					humanoid.JumpHeight = jumpHeight
					humanoid.JumpPower = jumpPower
					humanoid.AutoRotate = autoRotate
				end
			end)
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and not root.Anchored then
			root.Anchored = true
			table.insert(undo, function()
				if root.Parent then
					root.Anchored = false
				end
			end)
		end
	end

	return function()
		for _, fn in undo do
			fn()
		end
	end
end

--[[
	Client-side PivotTo on your own character replicates, because the client has network
	ownership of it -- so no server code is needed. The velocity zeroing is not optional: the
	arrival otherwise carries whatever fall speed the departure had.
]]
function Shell.placeCharacter(player: Player, cf: CFrame): boolean
	local character = player.Character
	if not character then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") then
		return false
	end
	-- Teleporting out of a seat leaves the character welded to it.
	if humanoid and (humanoid.Sit or humanoid.PlatformStand) then
		humanoid.Sit = false
		humanoid.PlatformStand = false
	end
	character:PivotTo(cf)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

return Shell
