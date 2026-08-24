--!strict
-- Shared module: lands in ReplicatedStorage.Shared.Hello
local Hello = {}

function Hello.greet(name: string): string
	return `hello, {name}`
end

return Hello
