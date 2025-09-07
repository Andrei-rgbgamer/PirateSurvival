-- ChunkManager.server.lua (async island surface generation only)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Terrain = workspace.Terrain

-- ?? Chunk settings
local CHUNK_SIZE = 512
local LOAD_RADIUS = 5 -- number of chunks around player to load

-- ?? Island settings
local ISLAND_SPACING = 5 -- min distance between islands (chunks)
local worldSeed = 1000 -- deterministic layout

-- ?? Water / height tuning
local WATER_LEVEL = 36 -- your water plane Y
local VOXEL_STEP = 4 -- voxel resolution (bigger = faster, lower = finer)

-- ?? State
local loadedChunks = {}
local islandSeeds = {} -- stores which chunks are islands
local islandBlobs = {} -- which blob each chunk belongs to
local activeCoroutines = {} -- running island gens
local generatedIslands = {} -- cache so islands don't regenerate

-- ?? Helpers
local function worldToChunk(pos: Vector3)
	local x = math.floor(pos.X / CHUNK_SIZE)
	local z = math.floor(pos.Z / CHUNK_SIZE)
	return x, z
end

local function chunkKey(x, z)
	return x .. "," .. z
end

local function clamp(v, a, b)
	return math.max(a, math.min(b, v))
end

local function smoothstep(t)
	t = clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Deterministic noise
local function hash(x: number, z: number, seed: number?)
	seed = seed or worldSeed
	local n = math.noise(x * 0.1337, z * 0.7331, seed * 0.011)
	return (n + 1) * 0.5
end

-- ?? Deterministic island size
local function getIslandSizeDeterministic(seedX, seedZ)
	local rng = Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663)
	local choices = {
		{1,1},{1,1},{1,1},{1,1},{1,1},
		{2,1},{1,2},{2,1},{1,2},
		{2,2},{2,2},
		{3,1},{1,3},{3,2},{2,3},
		{3,3}
	}
	local pick = choices[rng:NextInteger(1, #choices)]
	return pick[1], pick[2], rng
end

-- ?? Blob footprint
local function generateIslandBlob(cx, cz)
	local sizeX, sizeZ, rng = getIslandSizeDeterministic(cx, cz)
	print("[?? Island Seed] at chunk:", cx, cz, "blob size:", sizeX, "x", sizeZ)
	for dx = 0, sizeX - 1 do
		for dz = 0, sizeZ - 1 do
			local key = chunkKey(cx + dx, cz + dz)
			islandSeeds[key] = true
			islandBlobs[key] = {
				seedX = cx,
				seedZ = cz,
				sizeX = sizeX,
				sizeZ = sizeZ
			}
		end
	end
end

-- ? Decide if chunk is island
local function isIslandChunk(x, z)
	local key = chunkKey(x, z)
	if islandSeeds[key] ~= nil then return islandSeeds[key] end

	local minDist = math.huge
	for seedKey, isIsland in pairs(islandSeeds) do
		if isIsland then
			local sx, sz = string.match(seedKey, "(-?%d+),(-?%d+)")
			sx, sz = tonumber(sx), tonumber(sz)
			local dist = math.max(math.abs(sx - x), math.abs(sz - z))
			if dist < minDist then minDist = dist end
		end
	end

	local chance = hash(x, z)
	local spawnChance = (minDist >= ISLAND_SPACING) and 0.3 or 0.05
	if chance < spawnChance then
		generateIslandBlob(x, z)
		islandSeeds[key] = true
		return true
	end

	islandSeeds[key] = false
	return false
end

-- ?? Surface-only island generator (sand -> grass -> rock -> snow peaks)
local function generateIsland(seedX, seedZ, sizeX, sizeZ, markerBaseY)
	return coroutine.create(function()
		local baseX = seedX * CHUNK_SIZE
		local baseZ = seedZ * CHUNK_SIZE
		local width = sizeX * CHUNK_SIZE
		local depth = sizeZ * CHUNK_SIZE
		local rng = Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663)

		local centerX = baseX + width * 0.5
		local centerZ = baseZ + depth * 0.5

		-- ====== TUNABLES ======
		local SHORE_BAND   = 2      -- sand thickness
		local GRASS_HEIGHT = 20     -- grassy layer
		local MAX_PEAK     = 400    -- tall mountains
		local NOISE_AMPL   = 85     -- noise bump for mountains
		local SNOW_RATIO   = 0.01   -- top 1% snow
		local CHUNK_MARGIN = 32     -- keep this much buffer from chunk edge
		-- =======================

		-- initial radius guess
		local rawRadiusX = width * 0.5
		local rawRadiusZ = depth * 0.5

		-- clamp so island fits chunk
		local radiusX = math.max(VOXEL_STEP, rawRadiusX - CHUNK_MARGIN)
		local radiusZ = math.max(VOXEL_STEP, rawRadiusZ - CHUNK_MARGIN)

		-- cutouts (bays/lakes)
		local cutouts = {}
		for i = 1, rng:NextInteger(1, 2) do
			table.insert(cutouts, {
				x = centerX + rng:NextNumber(-radiusX * 0.6, radiusX * 0.6),
				z = centerZ + rng:NextNumber(-radiusZ * 0.6, radiusZ * 0.6),
				radius = math.min(radiusX, radiusZ) * (0.18 + rng:NextNumber() * 0.28)
			})
		end

		local ops = 0
		for localX = -VOXEL_STEP*2, width + VOXEL_STEP*2, VOXEL_STEP do
			for localZ = -VOXEL_STEP*2, depth + VOXEL_STEP*2, VOXEL_STEP do
				local wx = baseX + localX
				local wz = baseZ + localZ

				-- normalize based on clamped radius
				local nx = math.abs((localX - width*0.5) / math.max(1, radiusX))
				local nz = math.abs((localZ - depth*0.5) / math.max(1, radiusZ))
				local edgeFall = clamp(math.max(nx, nz), 0, 1)

				if edgeFall <= 1.0 then
					-- slope anchored to marker
					local baseHeight = markerBaseY + (WATER_LEVEL - markerBaseY) * (1 - edgeFall)^1.6

					-- cutouts lower base locally
					for _, cut in ipairs(cutouts) do
						local dx, dz = wx - cut.x, wz - cut.z
						local dist = math.sqrt(dx*dx + dz*dz)
						if dist < cut.radius then
							baseHeight -= (1 - smoothstep(dist / cut.radius)) * 12
						end
					end

					-- noise layers
					local bigNoise   = math.noise(wx*0.0008, wz*0.0008, worldSeed*0.11)
					local medNoise   = math.noise(wx*0.004,  wz*0.004,  worldSeed*0.23)
					local smallNoise = math.noise(wx*0.018,  wz*0.018,  worldSeed*0.47)
					local finalHeight = baseHeight + (bigNoise + medNoise*0.6 + smallNoise*0.3) * NOISE_AMPL
					finalHeight = math.min(finalHeight, WATER_LEVEL + MAX_PEAK)

					if finalHeight > markerBaseY + 0.5 then
						local heightSpan = finalHeight - markerBaseY
						local snowStart = markerBaseY + heightSpan * (1 - SNOW_RATIO)

						for y = markerBaseY, finalHeight, VOXEL_STEP do
							local mat
							if y <= WATER_LEVEL and y <= markerBaseY + SHORE_BAND then
								mat = Enum.Material.Sand
							elseif y <= WATER_LEVEL + GRASS_HEIGHT then
								local d = math.noise(wx*0.025, wz*0.025, worldSeed*0.33)
								mat = (d > 0.3) and Enum.Material.LeafyGrass or Enum.Material.Grass
							else
								mat = (y >= snowStart) and Enum.Material.Snow or Enum.Material.Rock
							end

							Terrain:FillBlock(
								CFrame.new(wx, y, wz),
								Vector3.new(VOXEL_STEP, VOXEL_STEP, VOXEL_STEP),
								mat
							)
						end
					end
				end

				ops += 1
				if ops % 400 == 0 then coroutine.yield() end
			end
		end
	end)
end


-- ?? Load a chunk (only generate once per island seed)
local function loadChunk(x, z)
	local key = chunkKey(x, z)
	if loadedChunks[key] then return end

	local marker = Instance.new("Part")
	marker.Size = Vector3.new(CHUNK_SIZE, 1, CHUNK_SIZE)
	-- marker positioned so its Y is near ocean; you had used WATER_LEVEL - 17
	marker.Position = Vector3.new(
		x * CHUNK_SIZE + CHUNK_SIZE/2,
		WATER_LEVEL - 17,
		z * CHUNK_SIZE + CHUNK_SIZE/2
	)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Transparency = 0.8
	marker.Color = Color3.fromRGB(220, 0, 4)
	marker.Parent = workspace
	loadedChunks[key] = marker

	if isIslandChunk(x, z) then
		marker.Color = Color3.fromRGB(0, 200, 0)
		local blob = islandBlobs[key]
		if blob then
			local seedKey = chunkKey(blob.seedX, blob.seedZ)
			if not generatedIslands[seedKey] then
				-- pass markerBaseY as marker.Position.Y (you earlier used -1; this uses the marker itself)
				table.insert(activeCoroutines, generateIsland(blob.seedX, blob.seedZ, blob.sizeX, blob.sizeZ, marker.Position.Y))
				generatedIslands[seedKey] = true -- mark started/done
			end
		end
	end
end

-- ?? Unload
local function unloadChunk(x, z)
	local key = chunkKey(x, z)
	if not loadedChunks[key] then return end
	loadedChunks[key]:Destroy()
	loadedChunks[key] = nil
end

-- ?? Main loop
RunService.Heartbeat:Connect(function()
	for _, player in pairs(Players:GetPlayers()) do
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local cx, cz = worldToChunk(hrp.Position)

			for x = cx - LOAD_RADIUS, cx + LOAD_RADIUS do
				for z = cz - LOAD_RADIUS, cz + LOAD_RADIUS do
					loadChunk(x, z)
				end
			end

			for key in pairs(loadedChunks) do
				local x, z = string.match(key, "(-?%d+),(-?%d+)")
				x, z = tonumber(x), tonumber(z)
				if math.abs(x - cx) > LOAD_RADIUS or math.abs(z - cz) > LOAD_RADIUS then
					unloadChunk(x, z)
				end
			end
		end
	end

	-- progress async gens
	for i = #activeCoroutines, 1, -1 do
		local co = activeCoroutines[i]
		if coroutine.status(co) == "dead" then
			table.remove(activeCoroutines, i)
		else
			coroutine.resume(co)
		end
	end
end)
