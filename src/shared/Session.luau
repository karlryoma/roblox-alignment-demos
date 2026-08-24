--!strict
--[[
	Session — the acquire/undo lifecycle every demo controller runs on.

	Extracted from demo 1, where it was already the thing that worked: a LIFO registry of undo
	closures, each pushed at the moment its resource is acquired, replayed in reverse with every
	step in its own pcall so one failure cannot abort the rest.

	start() wraps the body in a pcall for the reason demo 1's comment records: a throw partway
	through would otherwise leave the session marked active, the camera Scriptable and the
	lighting neutralised, with no way back. That is not hypothetical -- an unwritable Player
	property did exactly this on the first run in Studio.

	Nothing here knows about cameras, input or UI. It is the skeleton, not the demo.
]]

local Session = {}

export type Handle = {
	name: string,
	active: () -> boolean,
	--[[ Push an undo. Call it immediately after acquiring the thing it undoes. ]]
	add: (undo: () -> ()) -> (),
	track: (conn: RBXScriptConnection) -> (),
	own: (inst: Instance) -> (),
	--[[ Run `body` guarded. Returns false if it threw (the session is torn down first). ]]
	start: (body: (Handle) -> ()) -> boolean,
	stop: () -> (),
}

function Session.new(name: string): Handle
	local undos: { () -> () } = {}
	local isActive = false

	local handle: Handle
	handle = {
		name = name,

		active = function(): boolean
			return isActive
		end,

		add = function(undo: () -> ())
			table.insert(undos, undo)
		end,

		track = function(conn: RBXScriptConnection)
			table.insert(undos, function()
				conn:Disconnect()
			end)
		end,

		own = function(inst: Instance)
			table.insert(undos, function()
				inst:Destroy()
			end)
		end,

		start = function(body: (Handle) -> ()): boolean
			if isActive then
				return false
			end
			isActive = true
			-- typed pcall needs a return type to hand back the error string
			local ok, err = pcall(body :: (Handle) -> any, handle)
			if not ok then
				warn(`[{name}] session failed to start: {err}`)
				handle.stop()
				return false
			end
			return true
		end,

		stop = function()
			if not isActive then
				return
			end
			isActive = false
			for i = #undos, 1, -1 do
				local ok, err = pcall(undos[i] :: () -> any)
				if not ok then
					warn(`[{name}] teardown step failed: {err}`)
				end
			end
			table.clear(undos)
		end,
	}
	return handle
end

return Session
