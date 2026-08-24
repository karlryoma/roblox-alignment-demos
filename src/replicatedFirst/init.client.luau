--!strict
--[[
	The join loading screen. This is the FOURTH Rojo mapping (ReplicatedFirst.Boot) and it runs
	before StarterPlayerScripts is cloned, so it can require NOTHING from src/client -- it is
	deliberately self-contained.

	RemoveDefaultLoadingScreen only suppresses the default screen if it runs BEFORE that screen
	appears. Any yield first -- a WaitForChild, a require of something not yet replicated -- and
	it is too late. So it is the first statement, with nothing above it that can yield.

	game.Loaded is usually ALREADY true by the time a ReplicatedFirst script runs, so an
	unconditional game.Loaded:Wait() frequently never returns. Test IsLoaded first.

	Honest note: there is nothing to preload today. Every part in every demo is built in code and
	the one sound id is empty. PreloadAsync is wired anyway for demos 3-4, inside a task.spawn
	with a wall-clock timeout, so one slow asset can never hold the shell.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local MIN_SECONDS = 1.1 -- or it flashes past and reads as a glitch
local PRELOAD_TIMEOUT = 6

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "BootScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 100

local backdrop = Instance.new("Frame")
-- Active, so the boot screen SINKS clicks. Roblox routes input to the topmost INTERACTIVE
-- element, not the topmost opaque one, so a plain Frame at DisplayOrder 100 would let a click
-- land on the menu card underneath it.
backdrop.Active = true
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(9, 10, 13)
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.46)
title.Size = UDim2.fromOffset(560, 30)
title.BackgroundTransparency = 1
title.Font = Enum.Font.Code
title.TextSize = 21
title.TextColor3 = Color3.fromRGB(226, 234, 245)
title.Text = "ALIGNMENT ILLUSIONS"
title.Parent = backdrop

local sub = Instance.new("TextLabel")
sub.AnchorPoint = Vector2.new(0.5, 0.5)
sub.Position = UDim2.fromScale(0.5, 0.51)
sub.Size = UDim2.fromOffset(560, 20)
sub.BackgroundTransparency = 1
sub.Font = Enum.Font.Code
sub.TextSize = 13
sub.TextColor3 = Color3.fromRGB(122, 134, 152)
sub.Text = "loading"
sub.Parent = backdrop

local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0.5)
track.Position = UDim2.fromScale(0.5, 0.57)
track.Size = UDim2.fromOffset(260, 2)
track.BackgroundColor3 = Color3.fromRGB(44, 49, 58)
track.BorderSizePixel = 0
track.Parent = backdrop

local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.fromRGB(120, 240, 255)
fill.BorderSizePixel = 0
fill.Parent = track

gui.Parent = playerGui

local started = os.clock()
local function progress(alpha: number)
	fill.Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1)
end

progress(0.15)

if not game:IsLoaded() then
	game.Loaded:Wait()
end
progress(0.5)

do
	local done = false
	task.spawn(function()
		local assets: { Instance } = {}
		if #assets > 0 then
			pcall(function()
				ContentProvider:PreloadAsync(assets)
			end)
		end
		done = true
	end)

	local waited = 0
	while not done and waited < PRELOAD_TIMEOUT do
		waited += task.wait()
		progress(0.5 + 0.4 * (waited / PRELOAD_TIMEOUT))
	end
	if not done then
		warn("[boot] preload timed out; continuing")
	end
end

progress(1)
sub.Text = "ready"

local remaining = MIN_SECONDS - (os.clock() - started)
if remaining > 0 then
	task.wait(remaining)
end

TweenService:Create(backdrop, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
for _, label in { title, sub } do
	TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
end
TweenService:Create(track, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
TweenService:Create(fill, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
task.wait(0.45)
gui:Destroy()

-- Signalled AFTER the screen is gone, not before the fade: the shell shows the menu on the next
-- frame, and handing over early leaves an interactive picker underneath a visible boot screen.
-- The shell's own timeout covers a hang here.
ReplicatedFirst:SetAttribute("LoadingDone", true)
