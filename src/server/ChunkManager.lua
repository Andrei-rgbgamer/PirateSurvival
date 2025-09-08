-- ChunkManager.server.lua (async island generation with multiple island types + diagnostics)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Terrain = workspace.Terrain

-- ?? Chunk settings
local CHUNK_SIZE = 512
local LOAD_RADIUS = 5 -- number of chunks around player to load

-- ?? Island settings
local ISLAND_SPACING = 3 -- min distance between islands (chunks)
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

local function gauss(x, mu, sigma)
	local d = (x - mu) / sigma
	return math.exp(-0.5 * d * d)
end

-- Deterministic noise helper (wrapper if you want to tweak)
local function dnoise(x, z, s)
	return math.noise(x, z, s or 0)
end

-- Deterministic hash
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

-- ---- Island type picker (deterministic) ----
local function pickIslandType(seedX, seedZ)
	local rng = Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663 + 12345)
	local r = rng:NextNumber()
	-- Adjust probabilities as you like:
	-- 40% beachy, 35% plateau, 25% mountainous (example)
	if r < 0.40 then
		return "beachy", rng
	elseif r < 0.75 then
		return "plateau", rng
	else
		return "mountainous", rng
	end
end

-- ?? Mountainous generator — dome + central peaks + shoreline bays
local function generateMountainous(seedX, seedZ, sizeX, sizeZ, markerBaseY, rng)
	return coroutine.create(function()
		rng = rng or Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663 + 20000)

		local baseX = seedX * CHUNK_SIZE
		local baseZ = seedZ * CHUNK_SIZE
		local width = sizeX * CHUNK_SIZE
		local depth = sizeZ * CHUNK_SIZE

		local centerX = baseX + width * 0.5
		local centerZ = baseZ + depth * 0.5

		-- ===== Tunables =====
		local SHORE_FRACTION     = 0.32
		local DOME_HEIGHT        = 36
		local MOUNTAIN_BOOST_MIN = 60
		local MOUNTAIN_BOOST_MAX = 150
		local MAX_PEAK_LIMIT     = 340
		local NOISE_BIG_AMPL     = 20
		local NOISE_DETAIL_AMPL  = 10
		local SNOW_TOP_FRACTION  = 0.12
		local OVERSHOOT          = VOXEL_STEP * 2
		-- ====================

		local radiusX = math.max(1, width * 0.5)
		local radiusZ = math.max(1, depth * 0.5)
		local islandRadius = math.min(radiusX, radiusZ)

		-- Peaks (center bump or short range)
		local peaks = {}
		if rng:NextNumber() < 0.75 then
			table.insert(peaks, {
				x = centerX + rng:NextNumber(-islandRadius * 0.08, islandRadius * 0.08),
				z = centerZ + rng:NextNumber(-islandRadius * 0.08, islandRadius * 0.08),
				radius = islandRadius * (0.28 + rng:NextNumber() * 0.18),
				strength = rng:NextNumber(MOUNTAIN_BOOST_MIN, MOUNTAIN_BOOST_MAX)
			})
		else
			local count = rng:NextInteger(2, 3)
			for i = 1, count do
				table.insert(peaks, {
					x = centerX + rng:NextNumber(-islandRadius * 0.2, islandRadius * 0.2),
					z = centerZ + rng:NextNumber(-islandRadius * 0.2, islandRadius * 0.2),
					radius = islandRadius * rng:NextNumber(0.18, 0.28),
					strength = rng:NextNumber(MOUNTAIN_BOOST_MIN * 0.6, MOUNTAIN_BOOST_MAX * 0.9)
				})
			end
		end

		-- Bays (cutouts)
		local bays = {}
		local bayCount = rng:NextInteger(1, 3)
		for i = 1, bayCount do
			table.insert(bays, {
				x = centerX + rng:NextNumber(-radiusX * 0.7, radiusX * 0.7),
				z = centerZ + rng:NextNumber(-radiusZ * 0.7, radiusZ * 0.7),
				radius = islandRadius * rng:NextNumber(0.18, 0.28),
				depth = rng:NextNumber(12, 22) -- how deep the bay cuts in
			})
		end

		local ops = 0
		for localX = -OVERSHOOT, width + OVERSHOOT, VOXEL_STEP do
			for localZ = -OVERSHOOT, depth + OVERSHOOT, VOXEL_STEP do
				local wx = baseX + localX
				local wz = baseZ + localZ

				local nx = (localX - width * 0.5) / radiusX
				local nz = (localZ - depth * 0.5) / radiusZ
				local radial = math.sqrt(nx * nx + nz * nz)
				local edgeFall = smoothstep(clamp(radial, 0, 1))

				if edgeFall < 1.0 then
					-- Base dome
					local domeFactor = (1 - edgeFall)
					local domeHeight = DOME_HEIGHT * (domeFactor ^ 1.6)
					local baseHeight = WATER_LEVEL + domeHeight * 0.9

					-- Shore flatten
					if edgeFall > (1 - SHORE_FRACTION) then
						local shoreBias = (1 - edgeFall) / SHORE_FRACTION
						baseHeight = WATER_LEVEL + domeHeight * (0.25 * shoreBias)
					end

					-- Apply bays
					for _, bay in ipairs(bays) do
						local dx, dz = wx - bay.x, wz - bay.z
						local dist = math.sqrt(dx * dx + dz * dz)
						if dist < bay.radius then
							baseHeight = baseHeight - (1 - smoothstep(dist / bay.radius)) * bay.depth
						end
					end

					-- Peaks
					if edgeFall < (1 - SHORE_FRACTION * 0.2) then
						for _, p in ipairs(peaks) do
							local dx, dz = wx - p.x, wz - p.z
							local d = math.sqrt(dx * dx + dz * dz)
							local g = math.exp(-0.5 * (d * d) / (p.radius * p.radius))
							baseHeight = baseHeight + g * p.strength * (0.9 * domeFactor + 0.1)
						end
					end

					-- Noise
					local bigNoise = dnoise(wx * 0.0012, wz * 0.0012, worldSeed * 0.11) * NOISE_BIG_AMPL
					local detailNoise = dnoise(wx * 0.006, wz * 0.006, worldSeed * 0.27) * NOISE_DETAIL_AMPL
					local finalHeight = baseHeight + (bigNoise + detailNoise)
					finalHeight = math.min(finalHeight, WATER_LEVEL + MAX_PEAK_LIMIT)

					-- Fill terrain
					if finalHeight > markerBaseY + 0.25 then
						local heightSpan = finalHeight - markerBaseY
						local snowStart = finalHeight - heightSpan * SNOW_TOP_FRACTION
						local startY = math.floor((WATER_LEVEL - (DOME_HEIGHT * 0.35)) / VOXEL_STEP) * VOXEL_STEP
						if startY > markerBaseY then startY = markerBaseY end

						for y = startY, finalHeight, VOXEL_STEP do
							local mat
							if y <= WATER_LEVEL and y <= markerBaseY + 2 then
								mat = Enum.Material.Sand
							elseif y <= WATER_LEVEL + (DOME_HEIGHT * 0.25) then
								local dd = dnoise(wx * 0.02, wz * 0.02, worldSeed * 0.33)
								mat = (dd > 0.15) and Enum.Material.LeafyGrass or Enum.Material.Grass
							else
								mat = (y >= snowStart) and Enum.Material.Snow or Enum.Material.Rock
							end

							Terrain:FillBlock(CFrame.new(wx, y, wz), Vector3.new(VOXEL_STEP, VOXEL_STEP, VOXEL_STEP), mat)
						end
					end
				end

				ops += 1
				if ops % 350 == 0 then coroutine.yield() end
			end
		end
	end)
end

-- ---- Beachy generator (low, wide sand, no rock) ----
local function generateBeachy(seedX, seedZ, sizeX, sizeZ, markerBaseY, rng)
	return coroutine.create(function()
		rng = rng or Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663 + 30000)

		local baseX = seedX * CHUNK_SIZE
		local baseZ = seedZ * CHUNK_SIZE
		local width = sizeX * CHUNK_SIZE
		local depth = sizeZ * CHUNK_SIZE
		local centerX = baseX + width * 0.5
		local centerZ = baseZ + depth * 0.5

		-- Tunables
		local SHORE_BAND_MAX    = 3
		local GRASS_HEIGHT      = 18
		local NOISE_AMPL_SMALL  = 12 -- small bumps only
		local OVERSHOOT         = VOXEL_STEP * 3

		-- simple cutouts
		local cutouts = {}
		for i = 1, rng:NextInteger(0,1) do
			table.insert(cutouts, {
				x = centerX + rng:NextNumber(-width * 0.22, width * 0.22),
				z = centerZ + rng:NextNumber(-depth * 0.22, depth * 0.22),
				radius = math.min(width, depth) * (0.10 + rng:NextNumber() * 0.18)
			})
		end

		for localX = -OVERSHOOT, width + OVERSHOOT, VOXEL_STEP do
			for localZ = -OVERSHOOT, depth + OVERSHOOT, VOXEL_STEP do
				local wx = baseX + localX
				local wz = baseZ + localZ

				local nx = (localX - width*0.5) / math.max(1, width * 0.5)
				local nz = (localZ - depth*0.5) / math.max(1, depth * 0.5)
				local radial = math.sqrt(nx*nx + nz*nz)
				local edgeFall = clamp(radial, 0, 1)
				edgeFall = smoothstep(edgeFall)

				if edgeFall < 1.0 then
					local baseHeight = markerBaseY + (WATER_LEVEL - markerBaseY) * (1 - edgeFall)^1.2

					for _, cut in ipairs(cutouts) do
						local dx, dz = wx - cut.x, wz - cut.z
						local dist = math.sqrt(dx*dx + dz*dz)
						if dist < cut.radius then
							baseHeight = baseHeight - (1 - smoothstep(dist / cut.radius)) * (4 + rng:NextNumber()*6)
						end
					end

					-- tiny noise for gentle rolling beaches
					local finalHeight = baseHeight + dnoise(wx*0.01, wz*0.01, worldSeed*0.21) * NOISE_AMPL_SMALL
					finalHeight = math.min(finalHeight, WATER_LEVEL + 24)

					if finalHeight > markerBaseY + 0.2 then
						local shoreBand = rng:NextInteger(1, SHORE_BAND_MAX)
						local startY = math.floor(markerBaseY / VOXEL_STEP) * VOXEL_STEP
						if startY > markerBaseY then startY = markerBaseY end

						for y = startY, finalHeight, VOXEL_STEP do
							local mat
							if y <= WATER_LEVEL and y <= markerBaseY + shoreBand then
								mat = Enum.Material.Sand
							elseif y <= WATER_LEVEL + GRASS_HEIGHT then
								-- strong leafy bias for beachy islands
								local d = dnoise(wx*0.02, wz*0.02, worldSeed*0.33)
								mat = (d > -0.05) and Enum.Material.LeafyGrass or Enum.Material.Grass
							else
								-- keep it ground (no rock)
								mat = Enum.Material.Ground
							end

							Terrain:FillBlock(CFrame.new(wx, y, wz), Vector3.new(VOXEL_STEP, VOXEL_STEP, VOXEL_STEP), mat)
						end
					end
				end
			end
			coroutine.yield()
		end
	end)
end

-- ---- Plateau generator (flat grassy w/ scattered bumps) ----
local function generatePlateau(seedX, seedZ, sizeX, sizeZ, markerBaseY, rng)
	return coroutine.create(function()
		rng = rng or Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663 + 60000)

		local baseX = seedX * CHUNK_SIZE
		local baseZ = seedZ * CHUNK_SIZE
		local width = sizeX * CHUNK_SIZE
		local depth = sizeZ * CHUNK_SIZE
		local centerX = baseX + width * 0.5
		local centerZ = baseZ + depth * 0.5

		-- Tunables
		local SHORE_BAND_MAX   = 3
		local MID_HEIGHT       = WATER_LEVEL + 22 + rng:NextInteger(-4, 6) -- lower & flatter
		local NOISE_AMPL       = 10  -- just little undulations
		local ROCK_THRESHOLD   = 0.55 -- chance for rock bumps
		local OVERSHOOT        = VOXEL_STEP * 2

		-- cutouts (still allow bays/ponds)
		local cutouts = {}
		for i = 1, rng:NextInteger(0,1) do
			table.insert(cutouts, {
				x = centerX + rng:NextNumber(-width * 0.25, width * 0.25),
				z = centerZ + rng:NextNumber(-depth * 0.25, depth * 0.25),
				radius = math.min(width, depth) * (0.14 + rng:NextNumber() * 0.22)
			})
		end

		for localX = -OVERSHOOT, width + OVERSHOOT, VOXEL_STEP do
			for localZ = -OVERSHOOT, depth + OVERSHOOT, VOXEL_STEP do
				local wx = baseX + localX
				local wz = baseZ + localZ

				local nx = (localX - width*0.5) / math.max(1, width * 0.5)
				local nz = (localZ - depth*0.5) / math.max(1, depth * 0.5)
				local radial = math.sqrt(nx*nx + nz*nz)
				local edgeFall = smoothstep(clamp(radial, 0, 1))

				if edgeFall < 1.0 then
					-- base slope toward water
					local baseHeight = markerBaseY + (WATER_LEVEL - markerBaseY) * (1 - edgeFall)^1.6

					-- cutouts for bays
					for _, cut in ipairs(cutouts) do
						local dx, dz = wx - cut.x, wz - cut.z
						local dist = math.sqrt(dx*dx + dz*dz)
						if dist < cut.radius then
							baseHeight -= (1 - smoothstep(dist / cut.radius)) * 8
						end
					end

					-- mostly flat top, with little rolling bumps
					local noiseBump = dnoise(wx*0.005, wz*0.005, worldSeed*0.44) * NOISE_AMPL
					local finalHeight = baseHeight + (MID_HEIGHT - markerBaseY) * (1 - edgeFall) + noiseBump

					if finalHeight > markerBaseY + 0.5 then
						local shoreBand = rng:NextInteger(1, SHORE_BAND_MAX)
						local startY = math.floor(markerBaseY / VOXEL_STEP) * VOXEL_STEP
						if startY > markerBaseY then startY = markerBaseY end

						for y = startY, finalHeight, VOXEL_STEP do
							local mat
							if y <= WATER_LEVEL and y <= markerBaseY + shoreBand then
								mat = Enum.Material.Sand
							elseif y <= MID_HEIGHT then
								-- mostly leafy grass with some grass
								local d = dnoise(wx*0.02, wz*0.02, worldSeed*0.3)
								mat = (d > -0.2) and Enum.Material.LeafyGrass or Enum.Material.Grass
							else
								-- scattered rock bumps, not a peak
								local r = dnoise(wx*0.04, wz*0.04, worldSeed*0.66)
								mat = (r > ROCK_THRESHOLD) and Enum.Material.Rock or Enum.Material.LeafyGrass
							end

							Terrain:FillBlock(
								CFrame.new(wx, y, wz),
								Vector3.new(VOXEL_STEP, VOXEL_STEP, VOXEL_STEP),
								mat
							)
						end
					end
				end
			end
			coroutine.yield()
		end
	end)
end

-- ---- Dispatcher: generateIsland picks type and returns corresponding coroutine + diagnostics ----
local function generateIsland(seedX, seedZ, sizeX, sizeZ, markerBaseY)
	local typ, pickerRng = pickIslandType(seedX, seedZ)
	print(string.format("[IslandType] seed=%d,%d -> %s", seedX, seedZ, typ))
	local co = nil
	if typ == "mountainous" then
		co = generateMountainous(seedX, seedZ, sizeX, sizeZ, markerBaseY, pickerRng)
	elseif typ == "plateau" then
		co = generatePlateau(seedX, seedZ, sizeX, sizeZ, markerBaseY, pickerRng)
	else
		co = generateBeachy(seedX, seedZ, sizeX, sizeZ, markerBaseY, pickerRng)
	end
	return co, typ
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
				local co, typ = generateIsland(blob.seedX, blob.seedZ, blob.sizeX, blob.sizeZ, marker.Position.Y)
				if co then
					table.insert(activeCoroutines, co)
					generatedIslands[seedKey] = true -- mark started/done
					print(string.format("[IslandGen] started %s island at seed=%s size=%dx%d", typ, seedKey, blob.sizeX, blob.sizeZ))
				else
					warn("[IslandGen] failed to create coroutine for island at", seedKey)
				end
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
			local ok, err = coroutine.resume(co)
			if not ok then
				warn("Island coroutine error:", err)
				table.remove(activeCoroutines, i)
			end
		end
	end
end)
