--[[
    Seven Music - Server logic
    Responsibilities:
    - Spotify authentication + search proxy (server-side secret usage)
    - Audio stream resolver bridge
    - Persistence (history + liked songs)
    - Multiplayer sync relay (play/stop/volume/source updates)
    - Admin ACE-gated commands
]]

local tokenCache = {
    accessToken = nil,
    expiresAt = 0
}

local activeSources = {}

local function debugPrint(...)
    if Config.Debug then
        print('[SevenMusic]', ...)
    end
end

local function ensureTables()
    local historySql = ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `identifier` VARCHAR(80) NOT NULL,
            `track_id` VARCHAR(64) NOT NULL,
            `track_name` VARCHAR(255) NOT NULL,
            `artist_name` VARCHAR(255) NOT NULL,
            `album_cover` TEXT,
            `duration_ms` INT DEFAULT 0,
            `stream_url` TEXT,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_identifier (`identifier`),
            INDEX idx_track (`track_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]):format(Config.TableHistory)

    local likesSql = ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `identifier` VARCHAR(80) NOT NULL,
            `track_id` VARCHAR(64) NOT NULL,
            `track_name` VARCHAR(255) NOT NULL,
            `artist_name` VARCHAR(255) NOT NULL,
            `album_cover` TEXT,
            `duration_ms` INT DEFAULT 0,
            `stream_url` TEXT,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uniq_identifier_track (`identifier`, `track_id`),
            INDEX idx_identifier (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]):format(Config.TableLikes)

    MySQL.query.await(historySql)
    MySQL.query.await(likesSql)
    debugPrint('Database tables checked/created.')
end

CreateThread(function()
    ensureTables()
end)

local function getIdentifier(src)
    for _, identifier in ipairs(GetPlayerIdentifiers(src)) do
        if identifier:find('license:') == 1 then
            return identifier
        end
    end
    return ('player:%s'):format(src)
end

local function getSpotifyToken()
    local now = os.time()
    if tokenCache.accessToken and tokenCache.expiresAt > (now + 30) then
        return tokenCache.accessToken
    end

    if Config.SpotifyClientId == '' or Config.SpotifyClientSecret == '' then
        return nil, 'Spotify credentials missing in config/convars.'
    end

    local auth = ('%s:%s'):format(Config.SpotifyClientId, Config.SpotifyClientSecret)
    local b64 = nil

    if lib and lib.string and lib.string.encodeBase64 then
        b64 = lib.string.encodeBase64(auth)
    else
        b64 = PerformHttpRequestInternalEx and nil or nil
        -- fallback pure Lua base64 implementation
        local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        b64 = ((auth:gsub('.', function(x)
            local r,bits='',x:byte()
            for i=8,1,-1 do
                r = r .. (bits % 2^i - bits % 2^(i-1) > 0 and '1' or '0')
            end
            return r
        end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
            if (#x < 6) then
                return ''
            end
            local c=0
            for i=1,6 do
                c = c + (x:sub(i,i)=='1' and 2^(6-i) or 0)
            end
            return b:sub(c+1,c+1)
        end)..({ '', '==', '=' })[#auth % 3 + 1])
    end

    local promiseObj = promise.new()
    PerformHttpRequest('https://accounts.spotify.com/api/token', function(statusCode, body)
        if statusCode < 200 or statusCode >= 300 then
            promiseObj:resolve({ ok = false, error = ('Spotify auth failed (%s): %s'):format(statusCode, body) })
            return
        end

        local data = json.decode(body)
        if not data or not data.access_token then
            promiseObj:resolve({ ok = false, error = 'Spotify auth response invalid.' })
            return
        end

        tokenCache.accessToken = data.access_token
        tokenCache.expiresAt = os.time() + (data.expires_in or 3600)
        promiseObj:resolve({ ok = true, token = tokenCache.accessToken })
    end, 'POST', 'grant_type=client_credentials', {
        ['Authorization'] = ('Basic %s'):format(b64),
        ['Content-Type'] = 'application/x-www-form-urlencoded'
    })

    local result = Citizen.Await(promiseObj)
    if not result.ok then
        return nil, result.error
    end

    return result.token
end

local function spotifySearch(query)
    local token, err = getSpotifyToken()
    if not token then
        return nil, err
    end

    local endpoint = ('https://api.spotify.com/v1/search?q=%s&type=track&limit=%s&market=%s')
        :format(query, Config.SearchLimit, Config.SpotifyMarket)

    local p = promise.new()
    PerformHttpRequest(endpoint, function(statusCode, body)
        if statusCode < 200 or statusCode >= 300 then
            p:resolve({ ok = false, error = ('Spotify search failed (%s)'):format(statusCode) })
            return
        end

        local decoded = json.decode(body)
        if not decoded or not decoded.tracks or not decoded.tracks.items then
            p:resolve({ ok = false, error = 'Invalid Spotify search payload.' })
            return
        end

        local items = {}
        for _, track in ipairs(decoded.tracks.items) do
            local artist = track.artists and track.artists[1] and track.artists[1].name or 'Unknown'
            local cover = track.album and track.album.images and track.album.images[1] and track.album.images[1].url or ''
            table.insert(items, {
                id = track.id,
                title = track.name,
                artist = artist,
                duration = track.duration_ms or 0,
                cover = cover,
                external_url = track.external_urls and track.external_urls.spotify or ''
            })
        end

        p:resolve({ ok = true, items = items })
    end, 'GET', '', {
        ['Authorization'] = ('Bearer %s'):format(token)
    })

    local result = Citizen.Await(p)
    if not result.ok then
        return nil, result.error
    end

    return result.items
end

local function resolveStream(track)
    if Config.AudioResolverMode ~= 'yt_dlp_service' then
        return nil, 'Resolver mode not supported in config.'
    end

    local payload = json.encode({
        track_id = track.id,
        title = track.title,
        artist = track.artist,
        external_url = track.external_url
    })

    local p = promise.new()
    PerformHttpRequest(Config.AudioResolverEndpoint, function(statusCode, body)
        if statusCode < 200 or statusCode >= 300 then
            p:resolve({ ok = false, error = ('Resolver failed (%s)'):format(statusCode) })
            return
        end

        local decoded = json.decode(body)
        if not decoded or not decoded.stream_url then
            p:resolve({ ok = false, error = 'Resolver returned invalid payload.' })
            return
        end

        p:resolve({ ok = true, streamUrl = decoded.stream_url })
    end, 'POST', payload, {
        ['Content-Type'] = 'application/json'
    })

    local result = Citizen.Await(p)
    if not result.ok then
        return nil, result.error
    end

    return result.streamUrl
end

RegisterNetEvent('seven_music:server:search', function(rawQuery)
    local src = source
    if type(rawQuery) ~= 'string' then
        TriggerClientEvent('seven_music:client:searchResult', src, false, 'Query inválida.', {})
        return
    end

    local query = rawQuery:gsub('^%s*(.-)%s*$', '%1')
    if #query < 2 then
        TriggerClientEvent('seven_music:client:searchResult', src, true, nil, {})
        return
    end

    local encoded = query:gsub(' ', '%%20')
    local items, err = spotifySearch(encoded)
    if not items then
        debugPrint('Search error:', err)
        TriggerClientEvent('seven_music:client:searchResult', src, false, err or 'Falha na busca.', {})
        return
    end

    TriggerClientEvent('seven_music:client:searchResult', src, true, nil, items)
end)

RegisterNetEvent('seven_music:server:playTrack', function(track, sourceType, netId)
    local src = source
    if type(track) ~= 'table' or not track.id then
        TriggerClientEvent('seven_music:client:notify', src, 'error', 'Faixa inválida.')
        return
    end

    local streamUrl, err = resolveStream(track)
    if not streamUrl then
        TriggerClientEvent('seven_music:client:notify', src, 'error', err or 'Não foi possível resolver o áudio.')
        return
    end

    local identifier = getIdentifier(src)
    MySQL.insert(('INSERT INTO `%s` (identifier, track_id, track_name, artist_name, album_cover, duration_ms, stream_url) VALUES (?, ?, ?, ?, ?, ?, ?)'):format(Config.TableHistory), {
        identifier,
        track.id,
        track.title or 'Unknown',
        track.artist or 'Unknown',
        track.cover or '',
        track.duration or 0,
        streamUrl
    })

    local sourceId = ('sevenmusic_%s'):format(src)
    activeSources[src] = {
        sourceId = sourceId,
        owner = src,
        track = track,
        streamUrl = streamUrl,
        sourceType = sourceType or 'speaker',
        entityNetId = netId,
        startedAt = os.time()
    }

    TriggerClientEvent('seven_music:client:startTrack', -1, {
        owner = src,
        sourceId = sourceId,
        track = track,
        streamUrl = streamUrl,
        sourceType = sourceType or 'speaker',
        entityNetId = netId,
        volume = Config.DefaultVolume,
        maxDistance = Config.MaxDistance
    })

    TriggerClientEvent('seven_music:client:notify', src, 'success', ('Tocando: %s - %s'):format(track.title or '', track.artist or ''))
end)

RegisterNetEvent('seven_music:server:stopTrack', function()
    local src = source
    local active = activeSources[src]
    if not active then return end

    TriggerClientEvent('seven_music:client:stopTrack', -1, active.sourceId)
    activeSources[src] = nil
end)

RegisterNetEvent('seven_music:server:updateSource', function(sourceType, netId)
    local src = source
    local active = activeSources[src]
    if not active then return end

    active.sourceType = sourceType
    active.entityNetId = netId

    TriggerClientEvent('seven_music:client:updateTrackSource', -1, active.sourceId, sourceType, netId)
end)


local function setPlayerVolume(src, volumePercent)
    local active = activeSources[src]
    local num = tonumber(volumePercent)

    if not active then return false, 'Nenhuma música ativa.' end
    if not num then return false, 'Volume inválido.' end

    if num < Config.MinVolumeCommand then num = Config.MinVolumeCommand end
    if num > Config.MaxVolumeCommand then num = Config.MaxVolumeCommand end

    local normalized = num / 100.0
    TriggerClientEvent('seven_music:client:setVolume', -1, active.sourceId, normalized)
    TriggerClientEvent('seven_music:client:notify', src, 'info', ('Volume ajustado para %d%%'):format(num))
    return true
end

RegisterNetEvent('seven_music:server:setVolume', function(volumePercent)
    local src = source
    setPlayerVolume(src, volumePercent)
end)

RegisterNetEvent('seven_music:server:likeTrack', function(track)
    local src = source
    if type(track) ~= 'table' or not track.id then return end

    local identifier = getIdentifier(src)

    MySQL.insert(('INSERT IGNORE INTO `%s` (identifier, track_id, track_name, artist_name, album_cover, duration_ms, stream_url) VALUES (?, ?, ?, ?, ?, ?, ?)'):format(Config.TableLikes), {
        identifier,
        track.id,
        track.title or 'Unknown',
        track.artist or 'Unknown',
        track.cover or '',
        track.duration or 0,
        track.streamUrl or ''
    })
end)

RegisterNetEvent('seven_music:server:unlikeTrack', function(trackId)
    local src = source
    if type(trackId) ~= 'string' then return end

    local identifier = getIdentifier(src)
    MySQL.query(('DELETE FROM `%s` WHERE identifier = ? AND track_id = ?'):format(Config.TableLikes), {
        identifier,
        trackId
    })
end)

RegisterNetEvent('seven_music:server:getLibrary', function()
    local src = source
    local identifier = getIdentifier(src)

    local recent = MySQL.query.await(
        ('SELECT track_id AS id, track_name AS title, artist_name AS artist, album_cover AS cover, duration_ms AS duration, stream_url AS streamUrl, created_at FROM `%s` WHERE identifier = ? ORDER BY created_at DESC LIMIT 30'):format(Config.TableHistory),
        { identifier }
    ) or {}

    local liked = MySQL.query.await(
        ('SELECT track_id AS id, track_name AS title, artist_name AS artist, album_cover AS cover, duration_ms AS duration, stream_url AS streamUrl, created_at FROM `%s` WHERE identifier = ? ORDER BY created_at DESC LIMIT 100'):format(Config.TableLikes),
        { identifier }
    ) or {}

    TriggerClientEvent('seven_music:client:libraryData', src, {
        recent = recent,
        liked = liked
    })
end)

AddEventHandler('playerDropped', function()
    local src = source
    local active = activeSources[src]
    if active then
        TriggerClientEvent('seven_music:client:stopTrack', -1, active.sourceId)
        activeSources[src] = nil
    end
end)

RegisterCommand(Config.OpenCommand, function(src, args)
    if src == 0 then
        print('This command is for players.')
        return
    end

    local firstArg = args[1]

    if firstArg and tonumber(firstArg) then
        setPlayerVolume(src, tonumber(firstArg))
        return
    end

    if firstArg == 'stopall' then
        if not IsPlayerAceAllowed(src, Config.AdminAce) then
            TriggerClientEvent('seven_music:client:notify', src, 'error', 'Sem permissão de administrador.')
            return
        end

        for owner, active in pairs(activeSources) do
            TriggerClientEvent('seven_music:client:stopTrack', -1, active.sourceId)
            activeSources[owner] = nil
        end

        TriggerClientEvent('seven_music:client:notify', src, 'success', 'Todas as músicas foram interrompidas.')
        return
    end

    if firstArg == 'global' then
        if not IsPlayerAceAllowed(src, Config.AdminAce) then
            TriggerClientEvent('seven_music:client:notify', src, 'error', 'Sem permissão de administrador.')
            return
        end

        TriggerClientEvent('seven_music:client:notify', src, 'info', 'Modo global é opcional: implemente rádio global conforme sua economia RP.')
        return
    end

    TriggerClientEvent('seven_music:client:toggleUI', src)
end, false)
