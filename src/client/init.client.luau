--!strict
-- Runs in StarterPlayer.StarterPlayerScripts.Client
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hello = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Hello"))

print("[client]", Hello.greet("world"))
