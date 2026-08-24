--!strict
--[[
	Drag — input capture and nothing else. It never rotates anything.

	Accumulates raw pixel deltas into a pending vector plus a short EWMA, and hands the whole
	frame's worth to the loop exactly once through consume(). Smoothing at input rate would
	make the feel depend on the viewer's mouse: a 1000 Hz mouse fires ~16 events per rendered
	frame, a 125 Hz office mouse fires ~2.

	Deltas leave here divided by viewport height, read fresh each frame, so sensitivity is
	identical on every screen.

	The traps this module exists to contain:
	  * MouseBehavior = LockCurrentPosition WITH input.Delta. Differencing GetMouseLocation
	    returns zero under the lock, and Delta without the lock dies at the screen edge.
	  * A full-screen TextButton that is Modal ON TOUCH ONLY, where Modal's job is suppressing
	    the thumbstick and the default touch camera. On mouse it stays false: Modal exists to
	    FREE the cursor while a modal element is visible, which is the exact opposite of the
	    LockCurrentPosition this module depends on.
	  * ONE latched touch InputObject, by identity, so a second thumb cannot yank the object.
	  * The drag ends on window focus loss, on the Roblox menu opening, and on a per-frame
	    button poll. Alt-tabbing mid-drag otherwise leaves a sticky drag with a pinned cursor.
	  * Tap and drag are distinguished, so the commit click cannot nudge the box three pixels
	    on its way through.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Damp = require(ReplicatedStorage.Shared.Damp)

local Drag = {}

export type Frame = {
	dx: number,
	dy: number,
	velX: number,
	velY: number,
	held: boolean,
	released: boolean,
	tapped: boolean,
}

export type Handle = {
	consume: () -> Frame,
	setEnabled: (on: boolean) -> (),
	destroy: () -> (),
}

local VELOCITY_TAU = 0.08 -- people decelerate before letting go; the last frame is near zero
local TAP_SECONDS = 0.25
local TAP_TRAVEL = 0.006 -- fraction of viewport height

function Drag.new(camera: Camera, parentGui: Instance): Handle
	local surface = Instance.new("TextButton")
	surface.Name = "DragSurface"
	surface.Size = UDim2.fromScale(1, 1)
	surface.BackgroundTransparency = 1
	surface.Text = ""
	surface.AutoButtonColor = false
	surface.Active = true
	surface.Modal = UserInputService.TouchEnabled
	surface.ZIndex = 0
	surface.Parent = parentGui

	local connections: { RBXScriptConnection } = {}
	local enabled = true

	local dragging = false
	local latched: InputObject? = nil
	local isTouch = false
	local skipFirstTouchMove = false

	local pendX, pendY = 0, 0
	local vel = Vector2.zero
	local lastConsume = os.clock()

	local pressedAt = 0
	local travel = 0
	local releasedFlag = false
	local tappedFlag = false

	local function viewportY(): number
		local y = camera.ViewportSize.Y
		return if y > 1 then y else 1
	end

	local function endDrag(wasTap: boolean?)
		if not dragging then
			return
		end
		dragging = false
		latched = nil
		releasedFlag = true
		if wasTap then
			tappedFlag = true
		end
		if not isTouch then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		isTouch = false
	end

	local function beginDrag(input: InputObject, touch: boolean)
		if not enabled or dragging then
			return
		end
		dragging = true
		latched = input
		isTouch = touch
		skipFirstTouchMove = touch
		pressedAt = os.clock()
		travel = 0
		pendX, pendY = 0, 0
		vel = Vector2.zero
		if not touch then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			UserInputService.MouseIconEnabled = false
		end
	end

	-- gameProcessedEvent is honoured on the BEGIN only. Gating movement on it as well makes
	-- the drag stutter whenever the cursor crosses any other GUI element.
	table.insert(
		connections,
		surface.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				beginDrag(input, false)
			elseif input.UserInputType == Enum.UserInputType.Touch then
				beginDrag(input, true)
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if not dragging then
				return
			end
			if isTouch then
				if input ~= latched or input.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				if skipFirstTouchMove then
					skipFirstTouchMove = false
					return
				end
			elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end
			local d = input.Delta
			pendX += d.X
			pendY += d.Y
			travel += (math.abs(d.X) + math.abs(d.Y)) / viewportY()
		end)
	)

	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if not dragging then
				return
			end
			local ended = (isTouch and input == latched)
				or (not isTouch and input.UserInputType == Enum.UserInputType.MouseButton1)
			if ended then
				local quick = (os.clock() - pressedAt) <= TAP_SECONDS and travel <= TAP_TRAVEL
				endDrag(quick)
			end
		end)
	)

	table.insert(
		connections,
		UserInputService.WindowFocusReleased:Connect(function()
			endDrag(false)
		end)
	)

	table.insert(
		connections,
		GuiService.MenuOpened:Connect(function()
			endDrag(false)
		end)
	)

	local handle: Handle = {
		consume = function(): Frame
			local now = os.clock()
			local dt = math.clamp(now - lastConsume, 1 / 240, 1 / 15)
			lastConsume = now

			-- Belt and braces: a mouse-up swallowed by another GUI leaves a sticky drag.
			if dragging and not isTouch and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				endDrag(false)
			end

			local vy = viewportY()
			local dx, dy = pendX / vy, pendY / vy
			pendX, pendY = 0, 0

			vel = Damp.ewma(vel, Vector2.new(dx / dt, dy / dt), dt, VELOCITY_TAU)

			local frame: Frame = {
				dx = dx,
				dy = dy,
				velX = vel.X,
				velY = vel.Y,
				held = dragging,
				released = releasedFlag,
				tapped = tappedFlag,
			}
			releasedFlag = false
			tappedFlag = false
			return frame
		end,

		setEnabled = function(on: boolean)
			enabled = on
			surface.Active = on
			surface.Modal = on and UserInputService.TouchEnabled
			if not on then
				endDrag(false)
				pendX, pendY = 0, 0
				vel = Vector2.zero
			end
		end,

		destroy = function()
			endDrag(false)
			for _, c in connections do
				c:Disconnect()
			end
			table.clear(connections)
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			surface.Modal = false
			surface:Destroy()
		end,
	}
	return handle
end

return Drag
