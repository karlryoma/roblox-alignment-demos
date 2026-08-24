--!strict
--[[
	Orbit — a Scriptable third-person camera that follows a walking avatar.

	WHY THIS EXISTS AT ALL, since "just use the default camera" is the obvious move:

	  * There is no pitch-clamp property. Player exposes CameraMaxZoomDistance,
	    CameraMinZoomDistance, CameraMode, DevCameraOcclusionMode, DevComputerCameraMode and
	    DevTouchCameraMode -- and nothing for pitch. The default camera's vertical limit is
	    hard-coded in PlayerModule's BaseCamera, and forking PlayerModule fails this project's
	    quality gate (luau-lsp cannot resolve it through the sourcemap).
	  * A commit that re-poses the view needs CameraType = Scriptable. There is no mode in which
	    the default camera and a scripted snap both drive the CFrame.

	So we own the camera, and therefore own the clamp. Walking still works: the default control
	module derives its move vector from workspace.CurrentCamera.CFrame, so a Scriptable camera
	steers the avatar exactly like the stock one.

	It is NOT Mount. Mount captures its centre and distance at construction with no mutators, so
	it cannot follow a walking player, and at FOV 70 its fit distance is ~1.785 x radius -- for a
	20-stud room that parks the camera outside, looking in through a wall.

	Angles use Align.fromSpherical, the same convention Mount and Align.solve use, so a solved
	(yaw, pitch) is portable between rigs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Align = require(ReplicatedStorage.Shared.Align)
local Damp = require(ReplicatedStorage.Shared.Damp)

local Orbit = {}

export type Options = {
	distance: number,
	height: number, -- focus above the subject's origin: roughly eye height
	minPitchDeg: number,
	maxPitchDeg: number,
	degPerScreenHeight: number,
	turnTau: number, -- how fast the camera follows the input target
	followTau: number, -- how fast the focus follows the walking subject
	fovDeg: number,
	collisionPad: number,
}

export type Rig = {
	turn: (dxFrac: number, dyFrac: number) -> (),
	step: (dt: number) -> (),
	set: (yaw: number, pitch: number) -> (),
	get: () -> (number, number),
	eye: () -> Vector3,
	look: () -> Vector3,
	focusPoint: () -> Vector3,
	setSubject: (part: BasePart?) -> (),
	setFilter: (parts: { Instance }) -> (),
	restore: () -> (),
}

function Orbit.defaults(): Options
	return {
		distance = 13,
		height = 3.0,
		-- Ours to choose, which is the entire reason this module exists. Below the horizon by a
		-- little (so you can see the floor markers) and well short of straight down.
		minPitchDeg = -14,
		maxPitchDeg = 62,
		degPerScreenHeight = 260,
		turnTau = 0.055,
		followTau = 0.12,
		fovDeg = 70,
		collisionPad = 0.6,
	}
end

type Snapshot = {
	cameraType: Enum.CameraType,
	cframe: CFrame,
	focus: CFrame,
	fov: number,
	fovMode: Enum.FieldOfViewMode,
}

function Orbit.new(camera: Camera, subject: BasePart?, opts: Options): Rig
	local snap: Snapshot = {
		cameraType = camera.CameraType,
		cframe = camera.CFrame,
		focus = camera.Focus,
		fov = camera.FieldOfView,
		fovMode = camera.FieldOfViewMode,
	}
	local restored = false

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfViewMode = Enum.FieldOfViewMode.Vertical
	camera.FieldOfView = opts.fovDeg

	local minPitch = math.rad(opts.minPitchDeg)
	local maxPitch = math.rad(opts.maxPitchDeg)

	local yaw, pitch = 0, math.rad(14)
	local tgtYaw, tgtPitch = yaw, pitch
	local live: BasePart? = subject
	local focusPos = if live then live.Position + Vector3.new(0, opts.height, 0) else Vector3.zero
	local eyePos = focusPos + Align.fromSpherical(yaw, pitch, opts.distance)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude -- Blacklist/Whitelist no longer exist
	params.FilterDescendantsInstances = {}
	-- Decorative parts with CanCollide = false still block a ray by default, which is right for
	-- a wall we do not want the camera to pass through.
	params.RespectCanCollide = false
	params.IgnoreWater = true

	local rig: Rig = {
		turn = function(dxFrac: number, dyFrac: number)
			local scale = math.rad(opts.degPerScreenHeight)
			tgtYaw -= dxFrac * scale
			tgtPitch = math.clamp(tgtPitch + dyFrac * scale, minPitch, maxPitch)
		end,

		step = function(dt: number)
			local part = live
			if part and part.Parent then
				local want = part.Position + Vector3.new(0, opts.height, 0)
				local a = Damp.alpha(dt, opts.followTau)
				focusPos += (want - focusPos) * a
			end

			local a = Damp.alpha(dt, opts.turnTau)
			yaw += Damp.shortestArc(yaw, tgtYaw) * a
			pitch += (tgtPitch - pitch) * a

			local offset = Align.fromSpherical(yaw, pitch, opts.distance)
			local desired = focusPos + offset

			-- Camera collision. The avatar is excluded here and deliberately NOT excluded from
			-- the anchor-occlusion test elsewhere: the body should hide the markers, but it must
			-- never shove the camera.
			local hit = workspace:Raycast(focusPos, offset, params)
			if hit then
				local d = (hit.Position - focusPos).Magnitude - opts.collisionPad
				desired = focusPos + offset.Unit * math.max(d, 0.75)
			end

			eyePos = desired
			camera.CFrame = CFrame.lookAt(eyePos, focusPos)
			camera.Focus = CFrame.new(focusPos)
		end,

		set = function(y: number, p: number)
			yaw, tgtYaw = y, y
			pitch = math.clamp(p, minPitch, maxPitch)
			tgtPitch = pitch
		end,

		get = function(): (number, number)
			return yaw, pitch
		end,

		eye = function(): Vector3
			return eyePos
		end,

		look = function(): Vector3
			return (focusPos - eyePos).Unit
		end,

		focusPoint = function(): Vector3
			return focusPos
		end,

		setSubject = function(part: BasePart?)
			live = part
			if part then
				focusPos = part.Position + Vector3.new(0, opts.height, 0)
			end
		end,

		setFilter = function(parts: { Instance })
			params.FilterDescendantsInstances = parts
		end,

		restore = function()
			if restored then
				return
			end
			restored = true
			camera.FieldOfViewMode = snap.fovMode
			camera.FieldOfView = snap.fov
			camera.CFrame = snap.cframe
			camera.Focus = snap.focus
			camera.CameraType = snap.cameraType -- LAST, as in Mount
		end,
	}
	return rig
end

return Orbit
