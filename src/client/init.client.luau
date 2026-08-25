--!strict
--[[
	SHELL — the only LocalScript in this tree, and the owner of everything global.

	It hosts demos; it does not implement one. The rule it exists to enforce is that a demo may
	not own shared state: the RenderStep bind namespace, the mouse, the camera's type and
	subject, Lighting, and the character's whereabouts after a respawn are all shared across
	demos and across menu round-trips, so exactly one owner takes them and hands out leases.

	Three of those are here because of specific failures rather than tidiness:

	  * MOUSE. Drag only restores MouseBehavior/MouseIconEnabled on the path that began the
	    drag, so a demo torn down mid-drag would leave a locked, invisible cursor in the menu.
	    Restored unconditionally on every exit.
	  * CAMERA SUBJECT. Mount sets CameraSubject = nil and deliberately does not restore it,
	    because demo 1 always exited via respawn. Leaving a demo through the MENU means no
	    respawn, so CameraType goes back to Custom with nothing to follow and the camera sits
	    where it was. Reassigned on every exit.
	  * BIND NAMES. One global namespace; a second demo reusing a string silently unbinds the
	    first with no warning. Claimed through Shell.claimBind, which throws on collision.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

ReplicatedStorage:WaitForChild("Shared")
local Shell = require(ReplicatedStorage.Shared.Shell)

local Menu = require(script.Menu)
local Demo1 = require(script.Demo1)
local Demo2 = require(script.Demo2)
local Demo3 = require(script.Demo3)
local Demo4 = require(script.Demo4)

local LOBBY = CFrame.new(0, 6, 24)
local BOOT_TIMEOUT = 12

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local camera = workspace.CurrentCamera
while not camera do
	task.wait()
	camera = workspace.CurrentCamera
end
local cam: Camera = camera

--------------------------------------------------------------------------------
-- capability probes
--
-- globalTypes.d.luau carries no security annotations, so luau-lsp will NEVER catch a
-- capability-gated write: it type-checks clean and throws at runtime. Every such write goes
-- through here, and the boot probe says out loud whether it took.
--------------------------------------------------------------------------------

local function attempt(what: string, write: () -> ()): boolean
	local ok, err = pcall(write :: () -> any)
	if not ok then
		warn(`[shell] {what} was refused: {err}`)
	end
	return ok
end

--[[
	SetCore errors until the CoreScripts have registered the callback, so it needs a retry
	rather than a single pcall.
]]
local function disableResetButton()
	task.spawn(function()
		for _ = 1, 40 do
			local ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", false)
			end)
			if ok then
				print("[shell] reset button disabled")
				return
			end
			task.wait(0.25)
		end
		warn("[shell] could not disable the reset button; respawns are still handled")
	end)
end

--------------------------------------------------------------------------------
-- global state the shell owns
--------------------------------------------------------------------------------

--[[
	ONE Lighting snapshot, taken at boot and re-asserted on every return to the menu. Demos take
	scoped leases through ctx.dim and undo them in their own teardown; this is the backstop for a
	demo that dies before its undo runs.
]]
local baseline = {
	fogEnd = Lighting.FogEnd,
	fogStart = Lighting.FogStart,
	brightness = Lighting.Brightness,
	ambient = Lighting.Ambient,
}

local function reassertLighting()
	Lighting.FogEnd = baseline.fogEnd
	Lighting.FogStart = baseline.fogStart
	Lighting.Brightness = baseline.brightness
	Lighting.Ambient = baseline.ambient
end

local function restoreMouse()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function restoreCamera()
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	cam.FieldOfViewMode = Enum.FieldOfViewMode.Vertical
	cam.FieldOfView = 70
	if humanoid then
		cam.CameraSubject = humanoid
	end
	cam.CameraType = Enum.CameraType.Custom -- LAST
end

--------------------------------------------------------------------------------
-- demo registry
--------------------------------------------------------------------------------

local demos: { Shell.Controller } = {
	Demo1,
	Demo2,
	Demo3,
	Demo4,
}

local activeDemo: Shell.Controller? = nil
local activeBind: string? = nil
local respawnAt = LOBBY
local characterHooks: { (Model) -> () } = {}

local menu: Menu.Handle

local function place(cf: CFrame)
	respawnAt = cf
	Shell.placeCharacter(player, cf)
end

local function leaveDemo()
	local live = activeDemo
	if not live then
		return
	end
	activeDemo = nil
	table.clear(characterHooks)

	live.stop()

	local bind = activeBind
	if bind then
		Shell.releaseBind(bind)
		activeBind = nil
	end

	-- Unconditional, in this order, whatever the demo did or failed to do.
	restoreMouse()
	reassertLighting()
	restoreCamera()
	respawnAt = LOBBY
	Shell.placeCharacter(player, LOBBY)

	menu.show()
end

local function enterDemo(id: string)
	if activeDemo then
		return
	end
	local chosen: Shell.Controller? = nil
	for _, demo in demos do
		if demo.id == id and demo.ready then
			chosen = demo
		end
	end
	if not chosen then
		return
	end
	local controller: Shell.Controller = chosen

	menu.hide()
	local bind = Shell.claimBind(`Alignment_{controller.id}`)
	activeBind = bind
	activeDemo = controller

	local ctx: Shell.Context = {
		player = player,
		camera = cam,
		playerGui = playerGui,
		bindName = bind,
		exit = function()
			task.defer(leaveDemo)
		end,
		place = place,
		dim = Shell.dim,
		onCharacter = function(fn: (Model) -> ())
			table.insert(characterHooks, fn)
		end,
	}

	if not controller.start(ctx) then
		warn(`[shell] {controller.id} failed to start`)
		leaveDemo()
	end
end

--------------------------------------------------------------------------------
-- respawn: the shell's problem, never a demo's
--------------------------------------------------------------------------------

player.CharacterAdded:Connect(function(character: Model)
	character:WaitForChild("HumanoidRootPart", 10)
	task.wait(0.15) -- let the default camera acquire the fresh Humanoid before we take it back

	if activeDemo then
		-- Put them back where they were playing, then take the camera back: a respawn hands
		-- CameraType to the default scripts, which would otherwise fight the demo forever.
		Shell.placeCharacter(player, respawnAt)
		cam.CameraType = Enum.CameraType.Scriptable
		for _, fn in characterHooks do
			local ok, err = pcall(fn :: (Model) -> any, character)
			if not ok then
				warn(`[shell] character hook failed: {err}`)
			end
		end
	else
		Shell.placeCharacter(player, LOBBY)
		restoreCamera()
	end
end)

--------------------------------------------------------------------------------
-- boot
--------------------------------------------------------------------------------

local entries: { Menu.Entry } = {}
for _, demo in demos do
	table.insert(entries, { id = demo.id, title = demo.title, blurb = demo.blurb, ready = demo.ready })
end
menu = Menu.new(playerGui, entries, enterDemo)
menu.hide()

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	-- A safety net, not the advertised exit: demos own Q so they can fade out first.
	if input.KeyCode == Enum.KeyCode.Q and not activeDemo and not menu.visible() then
		menu.show()
	end
end)

task.spawn(function()
	if not player.Character then
		player.CharacterAdded:Wait()
	end

	-- Wait for the loading screen to hand over, but never hang on it.
	local waited = 0
	while not ReplicatedFirst:GetAttribute("LoadingDone") and waited < BOOT_TIMEOUT do
		waited += task.wait()
	end
	if waited >= BOOT_TIMEOUT then
		warn("[shell] loading screen never reported done; continuing anyway")
	end

	attempt("Lighting baseline", reassertLighting)
	disableResetButton()
	restoreMouse()
	restoreCamera()
	place(LOBBY)
	menu.show()
	print(`[shell] ready · {#demos} demos registered`)
end)
