--!strict
--[[
	Menu — the demo picker. Deliberately plain: it is a frame around the work, not the work.

	Unbuilt demos render as locked slots rather than being hidden, because the series is the
	point and a viewer should see where it is going.
]]

local Menu = {}

export type Entry = {
	id: string,
	title: string,
	blurb: string,
	ready: boolean,
}

export type Handle = {
	gui: ScreenGui,
	show: () -> (),
	hide: () -> (),
	visible: () -> boolean,
	destroy: () -> (),
}

local INK = Color3.fromRGB(226, 234, 245)
local DIM = Color3.fromRGB(122, 134, 152)
local CARD = Color3.fromRGB(24, 27, 34)
local CARD_LOCKED = Color3.fromRGB(18, 20, 25)
local ACCENT = Color3.fromRGB(120, 240, 255)

function Menu.new(parent: Instance, entries: { Entry }, onPick: (id: string) -> ()): Handle
	local gui = Instance.new("ScreenGui")
	gui.Name = "AlignmentMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local scrim = Instance.new("Frame")
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.fromRGB(9, 10, 13)
	scrim.BackgroundTransparency = 0.08
	scrim.BorderSizePixel = 0
	scrim.ZIndex = 1
	-- Active, so a click that misses a card cannot fall through to a demo surface underneath.
	scrim.Active = true
	scrim.Parent = gui

	local column = Instance.new("Frame")
	column.AnchorPoint = Vector2.new(0.5, 0.5)
	column.Position = UDim2.fromScale(0.5, 0.5)
	column.Size = UDim2.fromOffset(520, 420)
	column.BackgroundTransparency = 1
	column.ZIndex = 2
	column.Parent = scrim

	local heading = Instance.new("TextLabel")
	heading.Size = UDim2.fromOffset(520, 26)
	heading.BackgroundTransparency = 1
	heading.Font = Enum.Font.Code
	heading.TextSize = 19
	heading.TextXAlignment = Enum.TextXAlignment.Left
	heading.TextColor3 = INK
	heading.Text = "ALIGNMENT ILLUSIONS"
	heading.ZIndex = 3
	heading.Parent = column

	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(0, 26)
	sub.Size = UDim2.fromOffset(520, 20)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Code
	sub.TextSize = 13
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextColor3 = DIM
	sub.Text = "camera/perspective tech demos · Roblox"
	sub.ZIndex = 3
	sub.Parent = column

	local list = Instance.new("Frame")
	list.Position = UDim2.fromOffset(0, 62)
	list.Size = UDim2.fromOffset(520, 340)
	list.BackgroundTransparency = 1
	list.ZIndex = 3
	list.Parent = column

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for i, entry in entries do
		local card = Instance.new("TextButton")
		card.Name = entry.id
		card.LayoutOrder = i
		card.Size = UDim2.fromOffset(520, 62)
		card.BackgroundColor3 = if entry.ready then CARD else CARD_LOCKED
		card.BorderSizePixel = 0
		card.AutoButtonColor = entry.ready
		card.Active = entry.ready
		card.Text = ""
		card.ZIndex = 4
		card.Parent = list

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = card

		local stroke = Instance.new("UIStroke")
		stroke.Color = if entry.ready then ACCENT else Color3.fromRGB(40, 44, 52)
		stroke.Transparency = if entry.ready then 0.55 else 0.7
		stroke.Thickness = 1
		stroke.Parent = card

		local name = Instance.new("TextLabel")
		name.Position = UDim2.fromOffset(16, 10)
		name.Size = UDim2.fromOffset(488, 20)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.Code
		name.TextSize = 15
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = if entry.ready then INK else DIM
		name.Text = entry.title
		name.ZIndex = 5
		name.Parent = card

		local blurb = Instance.new("TextLabel")
		blurb.Position = UDim2.fromOffset(16, 32)
		blurb.Size = UDim2.fromOffset(488, 18)
		blurb.BackgroundTransparency = 1
		blurb.Font = Enum.Font.Code
		blurb.TextSize = 12
		blurb.TextXAlignment = Enum.TextXAlignment.Left
		blurb.TextColor3 = DIM
		blurb.Text = if entry.ready then entry.blurb else `{entry.blurb}  ·  not built yet`
		blurb.ZIndex = 5
		blurb.Parent = card

		if entry.ready then
			card.Activated:Connect(function()
				onPick(entry.id)
			end)
		end
	end

	local footer = Instance.new("TextLabel")
	footer.AnchorPoint = Vector2.new(0.5, 1)
	footer.Position = UDim2.new(0.5, 0, 1, -22)
	footer.Size = UDim2.fromOffset(620, 18)
	footer.BackgroundTransparency = 1
	footer.Font = Enum.Font.Code
	footer.TextSize = 12
	footer.TextColor3 = DIM
	footer.Text = "pick a demo · Q or EXIT returns here from inside one"
	footer.ZIndex = 3
	footer.Parent = scrim

	gui.Parent = parent

	local handle: Handle = {
		gui = gui,
		show = function()
			gui.Enabled = true
		end,
		hide = function()
			gui.Enabled = false
		end,
		visible = function(): boolean
			return gui.Enabled
		end,
		destroy = function()
			gui:Destroy()
		end,
	}
	return handle
end

return Menu
