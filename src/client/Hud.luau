--!strict
--[[
	Hud — the minimum on-screen surface: a proximity meter, a state line, and the fade used
	for the entry and exit cuts.

	The meter is here because the audience is developers: it makes the continuous angular
	signal visible, which is the part of the mechanic a video otherwise cannot show. It reads
	the same smoothed scalar the glow does, so it can never disagree with the object.

	The fade tweens a plain overlay, which is safe: no property here is written by the render
	loop, so there is no second writer.
]]

local TweenService = game:GetService("TweenService")

local Hud = {}

export type Handle = {
	gui: ScreenGui,
	layer: Frame,
	exitButton: TextButton,
	setProgress: (p: number, armed: boolean, locked: boolean) -> (),
	setState: (text: string) -> (),
	setHint: (text: string) -> (),
	fade: (to: number, duration: number) -> (),
	destroy: () -> (),
}

local DIM = Color3.fromRGB(120, 132, 148)
local WARM = Color3.fromRGB(96, 190, 220)
local HOT = Color3.fromRGB(150, 245, 255)
local ARMED = Color3.fromRGB(255, 214, 120)

function Hud.new(parent: Instance): Handle
	local gui = Instance.new("ScreenGui")
	gui.Name = "Demo1Hud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local layer = Instance.new("Frame")
	layer.Name = "Layer"
	layer.Size = UDim2.fromScale(1, 1)
	layer.BackgroundTransparency = 1
	layer.ZIndex = 1
	layer.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0, 0)
	title.Position = UDim2.fromOffset(28, 24)
	title.Size = UDim2.fromOffset(520, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Code
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = DIM
	title.Text = "ALIGNMENT DEMO 1 — ITEM INSPECTION"
	title.ZIndex = 3
	title.Parent = layer

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.Position = UDim2.fromOffset(28, 46)
	hint.Size = UDim2.fromOffset(640, 20)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 14
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = DIM
	hint.TextTransparency = 0.25
	hint.Text = ""
	hint.ZIndex = 3
	hint.Parent = layer

	local meterBack = Instance.new("Frame")
	meterBack.Name = "Meter"
	meterBack.AnchorPoint = Vector2.new(0.5, 1)
	meterBack.Position = UDim2.new(0.5, 0, 1, -74)
	meterBack.Size = UDim2.fromOffset(260, 3)
	meterBack.BackgroundColor3 = Color3.fromRGB(48, 54, 64)
	meterBack.BorderSizePixel = 0
	meterBack.ZIndex = 3
	meterBack.Parent = layer

	local meterFill = Instance.new("Frame")
	meterFill.Name = "Fill"
	meterFill.AnchorPoint = Vector2.new(0.5, 0.5)
	meterFill.Position = UDim2.fromScale(0.5, 0.5)
	meterFill.Size = UDim2.fromScale(0, 1)
	meterFill.BackgroundColor3 = WARM
	meterFill.BorderSizePixel = 0
	meterFill.ZIndex = 4
	meterFill.Parent = meterBack

	local state = Instance.new("TextLabel")
	state.Name = "State"
	state.AnchorPoint = Vector2.new(0.5, 1)
	state.Position = UDim2.new(0.5, 0, 1, -44)
	state.Size = UDim2.fromOffset(520, 20)
	state.BackgroundTransparency = 1
	state.Font = Enum.Font.Code
	state.TextSize = 15
	state.TextColor3 = DIM
	state.Text = ""
	state.ZIndex = 3
	state.Parent = layer

	-- The only exit a touch player can reach: there is no keyboard there, and Escape is owned
	-- by the Roblox menu on desktop. It sits above the drag surface, so it sinks its own click.
	local exitButton = Instance.new("TextButton")
	exitButton.Name = "Exit"
	exitButton.AnchorPoint = Vector2.new(1, 0)
	exitButton.Position = UDim2.new(1, -24, 0, 22)
	exitButton.Size = UDim2.fromOffset(88, 28)
	exitButton.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
	exitButton.BackgroundTransparency = 0.25
	exitButton.BorderSizePixel = 0
	exitButton.AutoButtonColor = true
	exitButton.Font = Enum.Font.Code
	exitButton.TextSize = 14
	exitButton.TextColor3 = DIM
	exitButton.Text = "EXIT"
	exitButton.ZIndex = 6
	exitButton.Parent = layer

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = exitButton

	local veil = Instance.new("Frame")
	veil.Name = "Veil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = Color3.new(0, 0, 0)
	veil.BackgroundTransparency = 0
	veil.BorderSizePixel = 0
	veil.ZIndex = 50
	veil.Parent = layer

	gui.Parent = parent

	local handle: Handle = {
		gui = gui,
		layer = layer,
		exitButton = exitButton,

		setProgress = function(p: number, armed: boolean, locked: boolean)
			local k = math.clamp(p, 0, 1)
			meterFill.Size = UDim2.fromScale(k, 1)
			meterFill.BackgroundColor3 = if locked then HOT elseif armed then ARMED else WARM
		end,

		setState = function(text: string)
			state.Text = text
		end,

		setHint = function(text: string)
			hint.Text = text
		end,

		fade = function(to: number, duration: number)
			if duration <= 0 then
				veil.BackgroundTransparency = to
				return
			end
			TweenService:Create(
				veil,
				TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = to }
			):Play()
		end,

		destroy = function()
			gui:Destroy()
		end,
	}
	return handle
end

return Hud
