--!strict
--[[
	Editor — a live map editor for the alignment demos.

	WHY THIS EXISTS. These illusions are composed by eye. The maths that makes two points coincide
	is exact and easy; deciding WHICH two things should appear to touch, from WHICH angle, so that
	the shot reads well, is a judgement about a picture. Authoring those numbers blind produces
	geometry that is arithmetically perfect and visually wrong. So this hands the composition back
	to a person and keeps the arithmetic here.

	THE ONE IDEA WORTH KNOWING, and the tool is built around it: moving a surface ALONG THE LINE
	FROM THE EYE changes almost nothing on screen -- it only scales what you see. Motion across
	that line is what changes an alignment. So the nudge keys are screen-relative: left/right and
	up/down move the picture, in/out moves depth nearly for free.

	SOLVE is the point of the whole tool. Frame the shot you want, select the surface that should
	appear to meet another, press it, and the surface moves the exact amount that puts its seam
	point on the ray from your eye through the partner -- the same pixel, from where you are
	standing. No eyeballing, no fitting.

	MEASURED IN THE REAL PROJECTION, not an idealised one. The readout is the angle the two points
	subtend at the eye, which is zero exactly when they are drawn on the same pixel. An earlier
	version measured the parallel projection and would print "coincident" for a seam the user
	could plainly see was apart, because perspective separates points by roughly
	(distance from frame centre) x (depth between them) / (camera distance). A tool that lies
	about the thing you are composing is worse than no tool.

	Nothing here writes to disk -- a client cannot. EXPORT prints a paste-ready block to the
	Output; the numbers go back into the level file, which is what Rojo syncs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Seam = require(ReplicatedStorage.Shared.Seam)

local Editor = {}

export type EditorSeam = {
	--[[ The point on THIS target that should appear to touch `partner`. ]]
	node: Attachment,
	partner: Attachment,
	label: string,
}

export type Target = {
	id: string,
	model: Model,
	--[[ How a move is applied. Defaults to PivotTo. A demo overrides it when the model's pose is
	     re-issued from a stored home every frame -- demo 4's rotor -- because a PivotTo would then
	     be erased before the next frame and the panel would report a move that did not happen. ]]
	apply: ((delta: Vector3) -> ())?,
	seams: { EditorSeam },
	--[[ Formats the current pose as something to paste back into the level file. The demo owns
	     this because only the demo knows how its own table is written. ]]
	export: (offset: Vector3) -> { string },
}

export type Handle = {
	toggle: () -> (),
	isOpen: () -> boolean,
	step: (dt: number) -> (),
	destroy: () -> (),
}

export type Options = {
	--[[ Called after any edit, so the demo can rebuild whatever it caches (a settled graph, a
	     bake). Edits are rare and this is cheap. ]]
	onChanged: () -> (),
	--[[ Opening and closing the editor is a mode change: the demo freezes the avatar and stops
	     arming crossings, because being walked or teleported mid-nudge is indistinguishable from
	     the map being wrong. ]]
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
	--[[ Whether authoring is legal right now -- demo 4 says no mid-rotation, because the camera is
	     then showing an angle the game can never settle at. ]]
	canSolve: (() -> boolean)?,
	camera: Camera,
	playerGui: Instance,
}

local STEPS = { 0.25, 0.5, 1, 2, 5 }
-- Tab is not safe for a game to own, so selection lives on the bracket keys and the step size on
-- minus/equals.

local INK = Color3.fromRGB(228, 236, 248)
local DIM = Color3.fromRGB(126, 140, 158)
local WARN = Color3.fromRGB(255, 196, 110)
local GOOD = Color3.fromRGB(130, 246, 190)

function Editor.new(targets: { Target }, options: Options): Handle
	local cam = options.camera
	local open = false
	local selected = 1
	local stepIndex = 3
	-- Keyed by MODEL, not by entry: several entries can steer the same surface (one per seam it
	-- carries), and they must share one accumulated offset.
	local moved: { [Model]: Vector3 } = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "MapEditor"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Enabled = false
	gui.Parent = options.playerGui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 24, 1, -24)
	panel.Size = UDim2.fromOffset(430, 210)
	panel.BackgroundColor3 = Color3.fromRGB(16, 18, 23)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = WARN
	stroke.Transparency = 0.5
	stroke.Parent = panel

	local function label(y: number, size: number, colour: Color3): TextLabel
		local t = Instance.new("TextLabel")
		t.Position = UDim2.fromOffset(16, y)
		t.Size = UDim2.fromOffset(400, 18)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.Code
		t.TextSize = size
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextColor3 = colour
		t.Text = ""
		t.Parent = panel
		return t
	end

	local title = label(12, 15, WARN)
	title.Text = "MAP EDITOR"
	local who = label(34, 14, INK)
	local readout = label(56, 13, DIM)
	local readout2 = label(74, 13, DIM)
	local help = label(102, 12, DIM)
	help.Size = UDim2.fromOffset(400, 100)
	help.TextYAlignment = Enum.TextYAlignment.Top
	help.Text = table.concat({
		"[  ]  select entry              -  =  step size",
		"ARROWS  move on screen          PGUP/PGDN  move in depth",
		"ENTER  SOLVE: put this seam on the ray through its partner",
		"BACKSPACE  undo all moves to this surface",
		"P  print the edits as paste-ready Luau",
	}, "\n")

	local function current(): Target?
		return targets[selected]
	end

	--[[
		How far apart the two points are IN THE PICTURE: the angle they subtend at the eye, and
		the same figure in pixels of the live viewport. Zero exactly when they are drawn on the
		same pixel -- which is the thing being composed.
	]]
	local function separation(seam: EditorSeam): (number, number)
		local camCF = cam:GetRenderCFrame()
		local deg = Seam.separationDeg(camCF.Position, seam.node.WorldPosition, seam.partner.WorldPosition)
		return deg, Seam.degToPixels(deg, cam.FieldOfView, cam.ViewportSize.Y)
	end

	local function refresh()
		local target = current()
		if not target then
			who.Text = "no editable surfaces"
			return
		end
		local offset = moved[target.model] or Vector3.zero
		who.Text = ("[%d/%d] %s   step %.2f   moved (%.2f, %.2f, %.2f)"):format(
			selected,
			#targets,
			target.id,
			STEPS[stepIndex],
			offset.X,
			offset.Y,
			offset.Z
		)
		local seam = target.seams[1]
		if seam then
			local deg, px = separation(seam)
			readout.Text = ("seam %s: %.1f px apart on screen (%.4f deg at the eye)"):format(seam.label, px, deg)
			readout.TextColor3 = if px < 2 then GOOD else DIM
			readout2.Text = if px < 2
				then "drawn on the same pixel from here"
				else "ENTER solves it from where you are standing"
		else
			readout.Text = "this surface carries no seam"
			readout2.Text = ""
		end
	end

	local function moveBy(delta: Vector3)
		local target = current()
		if not target then
			return
		end
		local apply = target.apply
		if apply then
			apply(delta)
		else
			target.model:PivotTo(target.model:GetPivot() + delta)
		end
		moved[target.model] = (moved[target.model] or Vector3.zero) + delta
		options.onChanged()
		refresh()
	end

	--[[
		Put this surface's seam point on the RAY from the eye through its partner, keeping its own
		distance from the eye. The two are then drawn on the same pixel exactly -- in the real
		projection, not an idealised one -- and the surface has moved as little as it can to get
		there.
	]]
	local function solve()
		local target = current()
		local seam = if target then target.seams[1] else nil
		if not target or not seam then
			return
		end
		local gate = options.canSolve
		if gate and not gate() then
			readout2.Text = "cannot solve from here -- the view is not settled"
			return
		end
		local eye = cam:GetRenderCFrame().Position
		local toPartner = seam.partner.WorldPosition - eye
		if toPartner.Magnitude < 1e-3 then
			return
		end
		local reach = (seam.node.WorldPosition - eye).Magnitude
		local wanted = eye + toPartner.Unit * reach
		moveBy(wanted - seam.node.WorldPosition)
	end

	local function undo()
		local target = current()
		if not target then
			return
		end
		local offset = moved[target.model]
		if offset then
			moveBy(-offset)
			moved[target.model] = nil
			refresh()
		end
	end

	local function printExport()
		print("---- map edits ----")
		local any = false
		local done: { [Model]: boolean } = {}
		for _, target in targets do
			local offset = moved[target.model]
			if offset and offset.Magnitude > 1e-4 and not done[target.model] then
				done[target.model] = true
				any = true
				print(("-- %s moved by (%.2f, %.2f, %.2f)"):format(target.id, offset.X, offset.Y, offset.Z))
				for _, line in target.export(offset) do
					print("   " .. line)
				end
			end
		end
		if not any then
			print("-- nothing moved yet")
		end
		print("-------------------")
	end

	local connections: { RBXScriptConnection } = {}

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed or not open then
				return
			end
			local code = input.KeyCode
			local camCF = cam:GetRenderCFrame()
			local step = STEPS[stepIndex]

			if code == Enum.KeyCode.LeftBracket then
				selected = ((selected - 2) % math.max(#targets, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.RightBracket then
				selected = (selected % math.max(#targets, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.Minus then
				stepIndex = math.max(stepIndex - 1, 1)
				refresh()
			elseif code == Enum.KeyCode.Equals then
				stepIndex = math.min(stepIndex + 1, #STEPS)
				refresh()
			elseif code == Enum.KeyCode.Left then
				moveBy(-camCF.RightVector * step)
			elseif code == Enum.KeyCode.Right then
				moveBy(camCF.RightVector * step)
			elseif code == Enum.KeyCode.Up then
				moveBy(camCF.UpVector * step)
			elseif code == Enum.KeyCode.Down then
				moveBy(-camCF.UpVector * step)
			elseif code == Enum.KeyCode.PageUp then
				-- Along the view axis: free under a parallel projection, and the readout proves it.
				moveBy(camCF.LookVector * step)
			elseif code == Enum.KeyCode.PageDown then
				moveBy(-camCF.LookVector * step)
			elseif code == Enum.KeyCode.Return then
				solve()
			elseif code == Enum.KeyCode.Backspace then
				undo()
			elseif code == Enum.KeyCode.P then
				printExport()
			end
		end)
	)

	local handle: Handle = {
		toggle = function()
			open = not open
			gui.Enabled = open
			if open then
				if options.onOpen then
					options.onOpen()
				end
				refresh()
				print("[editor] open — ARROWS move on screen, ENTER solves, P prints the edits")
			elseif options.onClose then
				options.onClose()
			end
		end,

		isOpen = function(): boolean
			return open
		end,

		step = function(_dt: number)
			if open then
				refresh()
			end
		end,

		destroy = function()
			for _, c in connections do
				c:Disconnect()
			end
			table.clear(connections)
			gui:Destroy()
		end,
	}
	return handle
end

return Editor
