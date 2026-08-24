--!strict
--[[
	Mount — the near-orthographic rig, and THE ONLY MODULE THAT DIFFERS between demo 1 and
	the world-scale demos.

	Mount.object writes the SUBJECT and parks the camera (demo 1: a handheld object turned
	in front of a fixed eye). Mount.orbit writes the CAMERA and leaves the world alone
	(demos 2-4). Both consume the identical (yaw, pitch) and are interchangeable at the call
	site — swapping one line is the entire world-scale port.

	NEAR-ORTHOGRAPHIC PROJECTION
	Roblox has no orthographic camera and FieldOfView is hard-clamped to [1, 120]. The
	approximation is FOV = 1 with a distant camera. The distance is computed here, once, so
	that nobody retypes 57.29 anywhere:

	  * against the subject's CIRCUMRADIUS, not its half-extent. A freely rotating 3-stud
	    cube presents 5.2 studs corner-on, so it is 372 studs away, not 171 — a half-extent
	    calculation clips the corners the moment the player turns it.
	  * against min(halfV, halfH), so a portrait phone (where the horizontal axis binds)
	    frames it too, and refit() is wired to ViewportSize changes.
	  * FieldOfViewMode is pinned to Vertical and the FOV is READ BACK after writing, because
	    the clamp is silent and MaxAxis/Diagonal are alternate writable views onto the same
	    frustum that reinterpret which axis the number measures.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Align = require(ReplicatedStorage.Shared.Align)

local Mount = {}

export type Rig = {
	apply: (yaw: number, pitch: number) -> (),
	eye: () -> Vector3,
	distance: () -> number,
	refit: () -> (),
	restore: () -> (),
}

-- The camera is parked along this world axis; the subject is turned to meet it.
local PARK_DIR = Vector3.new(0, 0, 1)

function Mount.fitDistance(radius: number, camera: Camera, margin: number): number
	local halfV = math.tan(math.rad(camera.FieldOfView) * 0.5)
	local vp = camera.ViewportSize
	local aspect = if vp.Y > 0 then vp.X / vp.Y else 1
	local half = math.min(halfV, halfV * aspect)
	if half < 1e-9 then
		return radius * 1000
	end
	return margin * radius / half
end

type Snapshot = {
	cameraType: Enum.CameraType,
	cframe: CFrame,
	focus: CFrame,
	fov: number,
	fovMode: Enum.FieldOfViewMode,
}

local function snapshot(camera: Camera): Snapshot
	return {
		cameraType = camera.CameraType,
		cframe = camera.CFrame,
		focus = camera.Focus,
		fov = camera.FieldOfView,
		fovMode = camera.FieldOfViewMode,
	}
end

-- Idempotent, and CameraType goes back LAST: restoring it first hands control to the
-- default camera scripts, which then fight every property written after it.
--
-- CameraSubject is deliberately NOT restored. The usual teardown trigger is a respawn, so the
-- captured subject is a Humanoid that no longer exists; putting it back would leave the camera
-- staring at a corpse. Handing CameraType back is enough for the default CameraModule to
-- re-acquire the live one.
local function restoreFrom(camera: Camera, snap: Snapshot, done: { value: boolean })
	if done.value then
		return
	end
	done.value = true
	camera.FieldOfViewMode = snap.fovMode
	camera.FieldOfView = snap.fov
	camera.CFrame = snap.cframe
	camera.Focus = snap.focus
	camera.CameraType = snap.cameraType
end

--[[
	The canonical roll-free frame for a direction. Two anchors and an eye leave the roll
	about the view axis completely free; this picks the up-locked member of that family, so
	the subject never mysteriously rotates in the plane of the screen. Degenerate at the
	poles, which is why pitch is clamped to +/- 80.
]]
local function frameFor(dir: Vector3): CFrame
	return CFrame.lookAt(Vector3.zero, dir)
end

--[[ Demo 1: the camera is parked and the OBJECT turns to present the requested eye direction. ]]
function Mount.object(
	model: Model,
	home: CFrame,
	camera: Camera,
	radius: number,
	margin: number,
	fovDeg: number
): Rig
	local snap = snapshot(camera)
	local done = { value = false }
	local center = home.Position

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil
	camera.FieldOfViewMode = Enum.FieldOfViewMode.Vertical
	camera.FieldOfView = fovDeg

	local dist = Mount.fitDistance(radius, camera, margin)
	local eyePos = center + PARK_DIR * dist
	local worldFrame = frameFor(-PARK_DIR)

	local function park()
		camera.CFrame = CFrame.lookAt(eyePos, center)
		camera.Focus = CFrame.new(center)
	end
	park()

	local rig: Rig = {
		apply = function(yaw: number, pitch: number)
			-- R maps the requested LOCAL eye direction onto the real world eye direction.
			local localEye = Align.fromSpherical(yaw, pitch, 1)
			local r = worldFrame * frameFor(-localEye):Inverse()
			model:PivotTo(CFrame.new(center) * r)
			-- Re-parked every frame rather than once at construction: a respawn hands CameraType
			-- back to the default scripts, and a camera written only at start-up never recovers.
			park()
		end,

		eye = function(): Vector3
			return eyePos
		end,

		distance = function(): number
			return dist
		end,

		refit = function()
			dist = Mount.fitDistance(radius, camera, margin)
			eyePos = center + PARK_DIR * dist
			park()
		end,

		restore = function()
			restoreFrom(camera, snap, done)
		end,
	}
	return rig
end

--[[ Demos 2-4: the world is fixed and the CAMERA orbits to the requested eye direction. ]]
function Mount.orbit(camera: Camera, focus: CFrame, radius: number, margin: number, fovDeg: number): Rig
	local snap = snapshot(camera)
	local done = { value = false }
	local center = focus.Position

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil
	camera.FieldOfViewMode = Enum.FieldOfViewMode.Vertical
	camera.FieldOfView = fovDeg

	local frame = focus.Rotation
	local dist = Mount.fitDistance(radius, camera, margin)
	local lastYaw, lastPitch = 0, 0
	local eyePos = center + frame * Align.fromSpherical(lastYaw, lastPitch, dist)

	local rig: Rig = {
		apply = function(yaw: number, pitch: number)
			lastYaw, lastPitch = yaw, pitch
			-- In the focus's frame, NOT world axes: Align.solve returns (yaw, pitch) in the frame
			-- the anchors were authored in, and Mount.object interprets them in the model's local
			-- frame. If orbit read them in world axes the same solved pair would mean two
			-- different directions, and the port to demos 2-4 would silently aim somewhere else.
			eyePos = center + frame * Align.fromSpherical(yaw, pitch, dist)
			camera.CFrame = CFrame.lookAt(eyePos, center)
			camera.Focus = CFrame.new(center)
		end,

		eye = function(): Vector3
			return eyePos
		end,

		distance = function(): number
			return dist
		end,

		refit = function()
			dist = Mount.fitDistance(radius, camera, margin)
			-- eye() must stay truthful between a resize and the next apply(): the alignment
			-- test reads it, and a stale eye scores a pose that is not on screen.
			eyePos = center + frame * Align.fromSpherical(lastYaw, lastPitch, dist)
		end,

		restore = function()
			restoreFrom(camera, snap, done)
		end,
	}
	return rig
end

return Mount
