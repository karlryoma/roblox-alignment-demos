--!strict
-- Runs in ServerScriptService.Server
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Hello = require(ReplicatedStorage.Shared.Hello)

Players.PlayerAdded:Connect(function(player)
	print("[server]", Hello.greet(player.Name))
end)

print("[server] sandbox up")
