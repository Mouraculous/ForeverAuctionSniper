--[[
Callbacks: a minimal publish/subscribe registry.

Pure module. Services fire events here. The UI and chat output subscribe.
The scanner never references the UI.
]]
local _, ns = ...

local Callbacks = {}
Callbacks.__index = Callbacks
ns.Callbacks = Callbacks

function Callbacks.New(onError)
	return setmetatable({ handlers = {}, onError = onError }, Callbacks)
end

-- Registers fn for event. owner is optional; it's passed to Unregister.
function Callbacks:Register(event, fn, owner)
	local list = self.handlers[event]
	if not list then
		list = {}
		self.handlers[event] = list
	end
	list[#list + 1] = { fn = fn, owner = owner or fn }
end

function Callbacks:Unregister(event, owner)
	local list = self.handlers[event]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i].owner == owner then
			table.remove(list, i)
		end
	end
end

-- Calls every handler. One failing handler doesn't stop the others.
function Callbacks:Fire(event, ...)
	local list = self.handlers[event]
	if not list then
		return
	end
	-- Copy so handlers may (un)register while we iterate.
	local snapshot = {}
	for i = 1, #list do
		snapshot[i] = list[i].fn
	end
	for i = 1, #snapshot do
		local ok, err = pcall(snapshot[i], ...)
		if not ok and self.onError then
			self.onError(event, err)
		end
	end
end
