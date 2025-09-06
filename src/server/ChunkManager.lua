local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Terrain = workspace.Terrain

-- Chunk settings
local CHUNK_SIZE = 512
local LOAD_RADIUS = 2 -- number of chunks around player to load

-- Island settings
local ISLAND_SPACING = 10 -- min distance between islands (chunks)
local ISLAND_MIN_SIZE = 1
local ISLAND_MAX_SIZE = 5

-- State
local loadedChunks = {}
local islandSeeds = {} -- stores which chunks are islands

-- Convert world pos to chunk coordinates
local function worldToChunk(pos: Vector3)
	local x = math.floor(pos.X / CHUNK_SIZE)
	local z = math.floor(pos.Z / CHUNK_SIZE)
	return x, z
end

-- Key helpers
local function chunkKey(x, z)
	return x .. "," .. z
end

-- Decide if a chunk should host an island
local function isIslandChunk(x, z)
	local key = chunkKey(x, z)
	if islandSeeds[key] ~= nil then
		return islandSeeds[key]
	end

	-- Random chance for an island
	if math.random() < 0.1 then
		-- Check spacing: must be far from other islands
		for seedKey, _ in pairs(islandSeeds) do
			local sx, sz = string.match(seedKey, "(-?%d+),(-?%d+)")
			sx, sz = tonumber(sx), tonumber(sz)
			if math.abs(sx - x) < ISLAND_SPACING and math.abs(sz - z) < ISLAND_SPACING then
				islandSeeds[key] = false
				return false
			end
		end

		-- This chunk is an island seed
		islandSeeds[key] = true
		return true
	else
		islandSeeds[key] = false
		return false
	end
end

-- Generate a simple island
local function generateIsland(x, z)
	local baseX = x * CHUNK_SIZE
	local baseZ = z * CHUNK_SIZE

	-- Random island radius
	local radius = math.random(100, 200)

	for dx = -radius, radius, 8 do
		for dz = -radius, radius, 8 do
			local dist = math.sqrt(dx*dx + dz*dz)
			if dist <= radius then
				local height = math.max(0, 40 - dist * 0.1 + math.random(-2, 2))
				local pos = Vector3.new(baseX + CHUNK_SIZE/2 + dx, 0, baseZ + CHUNK_SIZE/2 + dz)
				local region = Region3.new(pos, pos + Vector3.new(8, height, 8))
				region = region:ExpandToGrid(4)
				Terrain:FillRegion(region, 4, Enum.Material.Grass)
			end
		end
	end

	print("Generated island at chunk", x, z)
end

-- Load a chunk
local function loadChunk(x, z)
	local key = chunkKey(x, z)
	if loadedChunks[key] then return end

	local marker = Instance.new("Part")
	marker.Size = Vector3.new(CHUNK_SIZE, 1, CHUNK_SIZE)
	marker.Position = Vector3.new(x * CHUNK_SIZE + CHUNK_SIZE/2, 10, z * CHUNK_SIZE + CHUNK_SIZE/2)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Transparency = 0.8
	marker.Color = Color3.fromRGB(150, 150, 150) -- default gray
	marker.Parent = workspace

	loadedChunks[key] = marker

	-- Check if this chunk spawns an island
	if isIslandChunk(x, z) then
		marker.Color = Color3.fromRGB(0, 200, 0) -- green marker
		generateIsland(x, z)
	end
end

-- Unload a chunk
local function unloadChunk(x, z)
	local key = chunkKey(x, z)
	if not loadedChunks[key] then return end

	loadedChunks[key]:Destroy()
	loadedChunks[key] = nil
end

-- Update loop
RunService.Heartbeat:Connect(function()
	for _, player in pairs(Players:GetPlayers()) do
		if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			local pos = player.Character.HumanoidRootPart.Position
			local cx, cz = worldToChunk(pos)

			-- Load chunks in radius
			for x = cx - LOAD_RADIUS, cx + LOAD_RADIUS do
				for z = cz - LOAD_RADIUS, cz + LOAD_RADIUS do
					loadChunk(x, z)
				end
			end

			-- Unload chunks outside radius
			for key, _ in pairs(loadedChunks) do
				local x, z = string.match(key, "(-?%d+),(-?%d+)")
				x, z = tonumber(x), tonumber(z)
				if math.abs(x - cx) > LOAD_RADIUS or math.abs(z - cz) > LOAD_RADIUS then
					unloadChunk(x, z)
				end
			end
		end
	end
end)
