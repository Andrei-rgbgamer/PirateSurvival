-- ChunkManager.server.lua (async island generation with multiple island types + diagnostics)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Terrain = workspace.Terrain

-- ?? Chunk settings
local CHUNK_SIZE = 256
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

-- ?? Mountainous generator (scaled peaks by island size)
local function generateMountainous(seedX, seedZ, sizeX, sizeZ, markerBaseY, rng)
	return coroutine.create(function()
		rng = rng or Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663 + 20000)

		local baseX = seedX * CHUNK_SIZE
		local baseZ = seedZ * CHUNK_SIZE
		local width = sizeX * CHUNK_SIZE
		local depth = sizeZ * CHUNK_SIZE
		local centerX = baseX + width * 0.5
		local centerZ = baseZ + depth * 0.5

		-- scale factor based on average island radius
		local avgRadius = (width + depth) * 0.25
		local sizeScale = clamp(avgRadius / 256, 0.5, 2.5) 
		-- 256 = baseline size (tweak), scale mountains between half and 2.5×

		-- ===== CONFIG (scaled) =====
		local OVERSHOOT       = VOXEL_STEP * 2
		local MOUNTAIN_NORM   = 0.30
		local GRASS_NORM      = 0.80
		local SAND_HEIGHT     = rng:NextInteger(1, 2)

		local GRASS_RISE      = 22 * sizeScale
		local MOUNTAIN_LIFT   = (80 + rng:NextInteger(-10, 25)) * sizeScale
		local RIDGE_AMPL      = 14 * sizeScale
		local DETAIL_AMPL     = 6 * sizeScale
		local MAX_PEAK_OFFSET = 380 * sizeScale
		-- ============================

		-- bays
		local cutouts = {}
		for i = 1, rng:NextInteger(0, 2) do
			table.insert(cutouts, {
				x = centerX + rng:NextNumber(-width * 0.22, width * 0.22),
				z = centerZ + rng:NextNumber(-depth * 0.22, depth * 0.22),
				radius = math.min(width, depth) * (0.10 + rng:NextNumber() * 0.20)
			})
		end

		-- peaks (scaled radius)
		local peaks = {}
		local peakCount = (rng:NextNumber() < 0.75) and 1 or rng:NextInteger(2, 3)
		for i = 1, peakCount do
			table.insert(peaks, {
				x = centerX + rng:NextNumber(-width*0.14, width*0.14),
				z = centerZ + rng:NextNumber(-depth*0.14, depth*0.14),
				radius = avgRadius * rng:NextNumber(0.18, 0.28) -- scaled peak footprint
			})
		end

		local ops = 0
		for localX = -OVERSHOOT, width + OVERSHOOT, VOXEL_STEP do
			for localZ = -OVERSHOOT, depth + OVERSHOOT, VOXEL_STEP do
				local wx = baseX + localX
				local wz = baseZ + localZ

				local nx = (wx - centerX) / math.max(1, width*0.5)
				local nz = (wz - centerZ) / math.max(1, depth*0.5)
				local radial = math.sqrt(nx*nx + nz*nz)

				local shapeN = dnoise(wx * 0.0009, wz * 0.0009, worldSeed * 0.12) * 0.08
				local radialNoisy = clamp(radial + shapeN, 0, 1)
				local edgeFall = smoothstep(radialNoisy)

				if edgeFall < 1.05 then
					local baseHeight = markerBaseY + GRASS_RISE * (1 - edgeFall) ^ 1.3

					for _, cut in ipairs(cutouts) do
						local dx, dz = wx - cut.x, wz - cut.z
						local dist = math.sqrt(dx*dx + dz*dz)
						if dist < cut.radius then
							baseHeight = baseHeight - (1 - smoothstep(dist / cut.radius)) * (6 + rng:NextNumber()*8)
						end
					end

					local mountainInfluence = 0
					if radialNoisy <= MOUNTAIN_NORM then
						mountainInfluence = clamp((MOUNTAIN_NORM - radialNoisy) / (MOUNTAIN_NORM + 1e-6), 0, 1)
						mountainInfluence = smoothstep(mountainInfluence)
					end

					local peakBoost = 0
					if mountainInfluence > 0 then
						for _, peak in ipairs(peaks) do
							local dx, dz = wx - peak.x, wz - peak.z
							local pdist = math.sqrt(dx*dx + dz*dz)
							local g = math.exp(-(pdist*pdist) / (2 * (peak.radius * peak.radius + 1e-6)))
							peakBoost = peakBoost + g
						end
						peakBoost = peakBoost * MOUNTAIN_LIFT * mountainInfluence
					end

					local ridge = math.abs(dnoise(wx*0.0025, wz*0.006, worldSeed*0.42)) * RIDGE_AMPL * mountainInfluence
					local detail = dnoise(wx*0.01, wz*0.01, worldSeed*0.88) * DETAIL_AMPL * mountainInfluence

					local finalHeight = baseHeight + peakBoost + ridge + detail
					finalHeight = math.min(finalHeight, markerBaseY + MAX_PEAK_OFFSET)

					if finalHeight > markerBaseY + 0.25 then
						local startY = math.floor(markerBaseY / VOXEL_STEP) * VOXEL_STEP
						if startY > markerBaseY then startY = markerBaseY end

						for y = startY, finalHeight, VOXEL_STEP do
							local mat
							if y <= markerBaseY + SAND_HEIGHT and radialNoisy > GRASS_NORM then
								mat = Enum.Material.Sand
							elseif radialNoisy <= MOUNTAIN_NORM and mountainInfluence > 0.15 and y > markerBaseY + GRASS_RISE * 0.35 then
								local rnd = dnoise(wx*0.02, wz*0.02, worldSeed*0.33)
								mat = (rnd > 0.18) and Enum.Material.Rock or Enum.Material.LeafyGrass
							elseif radialNoisy <= GRASS_NORM then
								local rnd = dnoise(wx*0.02, wz*0.02, worldSeed*0.33)
								mat = (rnd > -0.05) and Enum.Material.LeafyGrass or Enum.Material.Grass
							else
								mat = Enum.Material.Sand
							end
							Terrain:FillBlock(CFrame.new(wx, y, wz), Vector3.new(VOXEL_STEP, VOXEL_STEP, VOXEL_STEP), mat)
						end
					end
				end

				ops = ops + 1
				if ops % 350 == 0 then coroutine.yield() end
			end
		end
	end)
end

-- ---- Plateau generator (flat grassy w/ scattered small bumps; materials anchored to markerBaseY)
local function generatePlateau(seedX, seedZ, sizeX, sizeZ, markerBaseY, rng)
	return coroutine.create(function()
		rng = rng or Random.new(worldSeed + seedX * 73856093 + seedZ * 19349663 + 61000)

		local baseX = seedX * CHUNK_SIZE
		local baseZ = seedZ * CHUNK_SIZE
		local width = sizeX * CHUNK_SIZE
		local depth = sizeZ * CHUNK_SIZE
		local centerX = baseX + width * 0.5
		local centerZ = baseZ + depth * 0.5

		-- Tunables (verticals relative to markerBaseY)
		local SAND_HEIGHT     = 2
		local MID_HEIGHT_OFF  = 18 + rng:NextInteger(-3, 6) -- plateau top above marker
		local NOISE_AMPL      = 4
		local BUMP_COUNT_MIN  = 3
		local BUMP_COUNT_MAX  = 7
		local BUMP_AMPL       = 8
		local OVERSHOOT       = VOXEL_STEP * 2

		local MID_HEIGHT = markerBaseY + MID_HEIGHT_OFF

		-- many small bumps
		local bumps = {}
		local bumpCount = rng:NextInteger(BUMP_COUNT_MIN, BUMP_COUNT_MAX)
		for i = 1, bumpCount do
			table.insert(bumps, {
				x = centerX + rng:NextNumber(-width * 0.35, width * 0.35),
				z = centerZ + rng:NextNumber(-depth * 0.35, depth * 0.35),
				radius = math.min(width, depth) * rng:NextNumber(0.06, 0.16),
				ampl = BUMP_AMPL * (0.6 + rng:NextNumber()*0.9)
			})
		end

		-- minor cutouts
		local cutouts = {}
		for i = 1, rng:NextInteger(0, 1) do
			table.insert(cutouts, {
				x = centerX + rng:NextNumber(-width * 0.22, width * 0.22),
				z = centerZ + rng:NextNumber(-depth * 0.22, depth * 0.22),
				radius = math.min(width, depth) * (0.12 + rng:NextNumber() * 0.18)
			})
		end

		local ops = 0
		for localX = -OVERSHOOT, width + OVERSHOOT, VOXEL_STEP do
			for localZ = -OVERSHOOT, depth + OVERSHOOT, VOXEL_STEP do
				local wx = baseX + localX
				local wz = baseZ + localZ

				local nx = (wx - centerX) / (width * 0.5)
				local nz = (wz - centerZ) / (depth * 0.5)
				local radial = math.sqrt(nx*nx + nz*nz)
				local edgeFall = smoothstep(clamp(radial, 0, 1))

				if edgeFall < 1.0 then
					-- base slope anchored to markerBaseY (no WATER_LEVEL)
					local baseHeight = markerBaseY + (MID_HEIGHT - markerBaseY) * (1 - edgeFall)^1.6

					-- cutout depressions
					for _, cut in ipairs(cutouts) do
						local dx, dz = wx - cut.x, wz - cut.z
						local dist = math.sqrt(dx*dx + dz*dz)
						if dist < cut.radius then
							baseHeight = baseHeight - (1 - smoothstep(dist / cut.radius)) * (4 + rng:NextNumber()*6)
						end
					end

					-- bump contributions
					local bumpBoost = 0
					for _, b in ipairs(bumps) do
						local dx, dz = wx - b.x, wz - b.z
						local pd = math.sqrt(dx*dx + dz*dz)
						local g = math.exp(-(pd*pd) / (2 * (b.radius*b.radius)))
						bumpBoost = bumpBoost + g * b.ampl
					end

					-- erosion and small rolling bumps
					local erosion = dnoise(wx * 0.02, wz * 0.02, worldSeed * 0.5) * (edgeFall * 6)
					baseHeight = baseHeight - erosion
					local noiseBump = dnoise(wx*0.004, wz*0.004, worldSeed*0.44) * NOISE_AMPL
					local finalHeight = baseHeight + bumpBoost + noiseBump

					if finalHeight > markerBaseY + 0.2 then
						local shoreBand = rng:NextInteger(1, math.max(1, SAND_HEIGHT))
						local startY = math.floor(markerBaseY / VOXEL_STEP) * VOXEL_STEP
						if startY > markerBaseY then startY = markerBaseY end

						for y = startY, finalHeight, VOXEL_STEP do
							local mat
							-- sand anchored to markerBaseY
							if y <= markerBaseY + shoreBand then
								mat = Enum.Material.Sand
								-- leafy-grass dominated plateau top
							elseif y <= finalHeight - 2 then
								local d = dnoise(wx*0.02, wz*0.02, worldSeed*0.3)
								mat = (d > -0.08) and Enum.Material.LeafyGrass or Enum.Material.Grass
							else
								-- small scattered rocks at some bump peaks
								local rockChance = dnoise(wx*0.03, wz*0.03, worldSeed*0.6) + (bumpBoost * 0.02)
								if rockChance > 0.22 and y > MID_HEIGHT + 4 then
									mat = Enum.Material.Rock
								else
									mat = Enum.Material.Grass
								end
							end

							Terrain:FillBlock(CFrame.new(wx, y, wz),
								Vector3.new(VOXEL_STEP, VOXEL_STEP, VOXEL_STEP),
								mat)
						end
					end
				end

				ops = ops + 1
				if ops % 300 == 0 then coroutine.yield() end
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
