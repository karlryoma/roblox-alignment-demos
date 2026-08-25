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

	WHICH IS ALSO HOW YOU CHOOSE WHAT IS IN FRONT. Roblox has no per-object draw order: occlusion
	is decided entirely by distance from the camera. So "put this walkway in front of that one" is
	the same operation as "move it toward the eye" -- and under these near-parallel projections
	that is nearly free in screen terms.

	ORDERING IS A SET OF CONSTRAINTS, NOT A NUDGE. "In front of the pole but behind that platform"
	is a statement about three objects at once, and satisfying one half at a time silently undoes
	the other. So IN FRONT OF and BEHIND SET constraints, and both are solved together every time
	either changes: the tool computes the interval of depths that satisfies both and moves the
	surface the shortest distance into it. When the interval is empty it says so, with the numbers
	-- because "there is no room between these two" is a fact about the level the author needs,
	not an error to hide.

	Depth is compared as a RANGE (the object's whole extent along the view axis), never a centre
	point: a platform whose centre is nearer can still have its far end poking through the thing
	it is supposed to sit in front of.

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

--[[ Anything the ordering commands can be placed relative to: surfaces, poles, scenery. The demo
     curates this -- a raw descendant walk would bury the list in skirts and marker bars. ]]
export type Reference = {
	name: string,
	instance: Instance,
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
	references: { Reference }?,
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
	panel.Size = UDim2.fromOffset(470, 340)
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
	local depthOut = label(92, 13, DIM)
	local stackTitle = label(114, 12, WARN)
	stackTitle.Text = "DEPTH STACK  (nearest the camera first)"
	local stackOut = label(130, 12, DIM)
	stackOut.Size = UDim2.fromOffset(430, 78)
	stackOut.TextYAlignment = Enum.TextYAlignment.Top
	local help = label(214, 12, DIM)
	help.Size = UDim2.fromOffset(430, 110)
	help.TextYAlignment = Enum.TextYAlignment.Top
	help.Text = table.concat({
		"[  ]  select entry              -  =  step size",
		"ARROWS  move on screen          PGUP/PGDN  toward / away from the eye",
		"ENTER  SOLVE (same pixel)       Z  FLIP across the seam partner",
		"; '  choose reference           HOME  must be IN FRONT OF it",
		"\\  clear constraints           END   must be BEHIND it",
		"BACKSPACE  undo this surface    P  print the edits",
	}, "\n")

	local function current(): Target?
		return targets[selected]
	end

	local references: { Reference } = options.references or {}
	local reference = 1
	--[[ The two ordering constraints, solved together. Kept per selected surface, because they
	     describe that surface's place in the stack and nothing else. ]]
	local mustBeInFrontOf: { [Model]: Reference } = {}
	local mustBeBehind: { [Model]: Reference } = {}

	--[[
		How much of the view axis an object occupies: the nearest and furthest depth over its whole
		extent. A range, not a centre -- an object whose centre is nearer can still have its far
		end poking through whatever it is meant to sit in front of.
	]]
	local function depthRange(inst: Instance, camCF: CFrame): (number, number)
		local cf: CFrame, size: Vector3
		if inst:IsA("Model") then
			cf, size = inst:GetBoundingBox()
		elseif inst:IsA("BasePart") then
			cf, size = inst.CFrame, inst.Size
		else
			return math.huge, -math.huge
		end
		local half = size * 0.5
		local lo, hi = math.huge, -math.huge
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local at = cf * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)
					local depth = -(camCF:PointToObjectSpace(at.Position).Z)
					lo = math.min(lo, depth)
					hi = math.max(hi, depth)
				end
			end
		end
		return lo, hi
	end

	--[[ The direction to slide along so the thing being composed keeps its pixel: the ray from the
	     eye through the seam point, or through the model's centre when there is no seam. ]]
	local function slideAxis(target: Target): (Vector3, Vector3)
		local eye = cam:GetRenderCFrame().Position
		local seam = target.seams[1]
		local anchor = if seam then seam.node.WorldPosition else target.model:GetPivot().Position
		local dir = anchor - eye
		if dir.Magnitude < 1e-3 then
			return cam:GetRenderCFrame().LookVector, anchor
		end
		return dir.Unit, anchor
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

	--[[
		Distance from the eye to each end of the seam. The nearer one is the one drawn in front,
		because that is the only thing Roblox sorts on.
	]]
	local function depths(seam: EditorSeam): (number, number)
		local eye = cam:GetRenderCFrame().Position
		return (seam.node.WorldPosition - eye).Magnitude, (seam.partner.WorldPosition - eye).Magnitude
	end

	local function refreshStack(target: Target)
		--[[ The constraints are shown persistently, not only in the last message: they are state,
		     and state the author cannot see is state they will fight. ]]
		local front = mustBeInFrontOf[target.model]
		local back = mustBeBehind[target.model]
		if front or back then
			stackTitle.Text = ("DEPTH STACK   must be%s%s%s"):format(
				if front then ` in front of {front.name}` else "",
				if front and back then " and" else "",
				if back then ` behind {back.name}` else ""
			)
		else
			stackTitle.Text = "DEPTH STACK  (nearest the camera first)"
		end
		if #references == 0 then
			stackOut.Text = "  (this demo lists no reference objects)"
			return
		end
		local camCF = cam:GetRenderCFrame()
		local rows: { { name: string, lo: number, hi: number, isRef: boolean } } = {}
		for i, ref in references do
			local lo, hi = depthRange(ref.instance, camCF)
			if lo ~= math.huge then
				table.insert(rows, { name = ref.name, lo = lo, hi = hi, isRef = i == reference })
			end
		end
		table.sort(rows, function(a, b)
			return a.lo < b.lo
		end)
		local myLo = select(1, depthRange(target.model, camCF))
		local lines: { string } = {}
		for _, row in rows do
			local mark = if row.isRef then ">" else " "
			local mine = if math.abs(row.lo - myLo) < 0.01 then "  <= selected" else ""
			table.insert(lines, ("%s %-22s %6.0f .. %6.0f studs%s"):format(mark, row.name, row.lo, row.hi, mine))
		end
		stackOut.Text = table.concat(lines, "\n")
	end

	local function refresh()
		local target = current()
		if not target then
			who.Text = "no editable surfaces"
			return
		end
		refreshStack(target)
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

			--[[ Depth order is the whole of "what is in front of what" in Roblox, and the size
			     penalty is what it costs: a surface pulled toward the eye is drawn that much
			     larger, which at a wide FOV is the thing that gives the trick away. ]]
			local mine, theirs = depths(seam)
			local gap = mine - theirs
				-- The ratio of the two distances is the ratio of their drawn sizes.
		local scale = if theirs > 1e-3 then math.abs(gap) / theirs * 100 else 0
			--[[ The percentage is not decoration: it is exactly how much the avatar's apparent size
			     jumps when it crosses this seam, because that pop IS the depth ratio. Widen the gap
			     to reorder the drawing and you widen the pop by the same amount. ]]
			depthOut.Text = ("in front: %s, by %.1f studs · crossing pops the avatar %.1f%%"):format(
				if gap < 0 then seam.node.Name else seam.partner.Name,
				math.abs(gap),
				scale
			)
		else
			readout.Text = "this surface carries no seam"
			readout2.Text = ""
			depthOut.Text = ""
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

	--[[
		FLIP: mirror this surface to the other side of its partner along the eye ray, so whichever
		was in front now is not. The screen ray is unchanged, so the picture keeps its alignment;
		only the occlusion order and the apparent size change. That is the only lever there is --
		Roblox sorts by distance and nothing else.
	]]
	local function flipDepth()
		local target = current()
		local seam = if target then target.seams[1] else nil
		if not target or not seam then
			return
		end
		local gate = options.canSolve
		if gate and not gate() then
			readout2.Text = "cannot flip from here -- the view is not settled"
			return
		end
		local eye = cam:GetRenderCFrame().Position
		local toNode = seam.node.WorldPosition - eye
		local mine, theirs = depths(seam)
		if toNode.Magnitude < 1e-3 or theirs < 1e-3 then
			return
		end
		-- Mirrored across the partner's distance: same direction from the eye, other side of it.
		local wantedDistance = 2 * theirs - mine
		if wantedDistance < 5 then
			-- The mirror would land on top of the camera, or behind it. Refuse rather than fling
			-- the surface through the lens.
			readout2.Text = "cannot flip: the far side is behind the camera -- move it closer first"
			return
		end
		local wanted = eye + toNode.Unit * wantedDistance
		moveBy(wanted - seam.node.WorldPosition)
	end

	--[[
		Solve BOTH ordering constraints at once and move the shortest distance that satisfies them.

		Working in "depth of my nearest face", the two constraints are intervals:
		  in front of R  =>  my FAR face must clear R's near face   =>  myLo <= R.lo - margin - span
		  behind R       =>  my NEAR face must clear R's far face   =>  myLo >= R.hi + margin
		Intersect, clamp the current value into it -- and when the intersection is empty, say so
		with the numbers rather than satisfying one and silently breaking the other.
	]]
	local MARGIN = 0.5
	local function applyConstraints(): boolean
		local target = current()
		if not target then
			return false
		end
		local gate = options.canSolve
		if gate and not gate() then
			readout2.Text = "cannot reorder from here -- the view is not settled"
			return false
		end
		local front = mustBeInFrontOf[target.model]
		local back = mustBeBehind[target.model]
		if not front and not back then
			return false
		end

		local camCF = cam:GetRenderCFrame()
		local myLo, myHi = depthRange(target.model, camCF)
		if myLo == math.huge then
			return false
		end
		local span = myHi - myLo

		local dir = slideAxis(target)
		local perStud = dir:Dot(camCF.LookVector)
		if math.abs(perStud) < 1e-3 then
			readout2.Text = "cannot reorder: this surface is edge-on to the view axis"
			return false
		end

		local lowest, highest = -math.huge, math.huge
		if back then
			local _, refHi = depthRange(back.instance, camCF)
			lowest = math.max(lowest, refHi + MARGIN)
		end
		if front then
			local refLo = depthRange(front.instance, camCF)
			highest = math.min(highest, refLo - MARGIN - span)
		end

		if lowest > highest then
			readout2.Text = ("no room: %s leaves %.1f studs and this surface is %.1f deep"):format(
				if front and back then `{back.name} .. {front.name}` else "that pair",
				highest - lowest + span,
				span
			)
			return false
		end

		local wanted = math.clamp(myLo, lowest, highest)
		moveBy(dir * ((wanted - myLo) / perStud))
		readout2.Text = ("ordered: %s%s%s"):format(
			if front then `in front of {front.name}` else "",
			if front and back then " · " else "",
			if back then `behind {back.name}` else ""
		)
		return true
	end

	local function order(inFront: boolean)
		local target = current()
		local ref = references[reference]
		if not target or not ref then
			return
		end
		-- A constraint, not a one-shot move: both are re-solved together so the second can never
		-- silently undo the first.
		if inFront then
			mustBeInFrontOf[target.model] = ref
		else
			mustBeBehind[target.model] = ref
		end
		applyConstraints()
		refresh()
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
			elseif code == Enum.KeyCode.Z then
				flipDepth()
			elseif code == Enum.KeyCode.Semicolon then
				reference = ((reference - 2) % math.max(#references, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.Quote then
				reference = (reference % math.max(#references, 1)) + 1
				refresh()
			elseif code == Enum.KeyCode.Home then
				order(true)
			elseif code == Enum.KeyCode.End then
				order(false)
			elseif code == Enum.KeyCode.BackSlash then
				local target = current()
				if target then
					mustBeInFrontOf[target.model] = nil
					mustBeBehind[target.model] = nil
					readout2.Text = "constraints cleared"
					refresh()
				end
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
