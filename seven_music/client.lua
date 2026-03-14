--[[
    Seven Music - Client logic
    Responsibilities:
    - Open/close NUI and handle callbacks
    - Manage speaker object and source attachment
    - Integrate xsound positional playback
    - Sync source movement (vehicle/speaker/world)
]]

local uiOpen = false
local currentSourceId = nil
local currentTrack = nil
local currentSourceType = nil
local speakerEntity = nil
local sourceAttachNetId = nil

local function debugPrint(...)
    if Config.Debug then
        print('[SevenMusic:Client]', ...)
    end
end

local function notify(level, message)
    SendNUIMessage({
        action = 'notify',
        level = level,
        message = message
    })
end

local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end

    RequestModel(hash)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        Wait(50)
        if GetGameTimer() > timeout then
            return nil
        end
    end

    return hash
end

local function removeSpeaker()
    if speakerEntity and DoesEntityExist(speakerEntity) then
        DeleteEntity(speakerEntity)
    end
    speakerEntity = nil
end

local function createSpeakerInHand()
    if speakerEntity and DoesEntityExist(speakerEntity) then
        return speakerEntity
    end

    local ped = PlayerPedId()
    local model = loadModel(Config.SpeakerModel)
    if not model then
        notify('error', 'Modelo da caixa de som não carregou.')
        return nil
    end

    speakerEntity = CreateObject(model, 0.0, 0.0, 0.0, true, true, false)
    SetEntityAsMissionEntity(speakerEntity, true, true)
    AttachEntityToEntity(
        speakerEntity,
        ped,
        GetPedBoneIndex(ped, 57005),
        0.14, 0.02, -0.02,
        -85.0, 180.0, 15.0,
        true, true, false, true, 1, true
    )

    SetModelAsNoLongerNeeded(model)
    return speakerEntity
end

local function getEntityCoordsByNet(netId)
    if not netId then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        return GetEntityCoords(entity)
    end
    return nil
end

local function updateSourceAttachment(sourceId, sourceType, netId)
    currentSourceType = sourceType
    sourceAttachNetId = netId

    if sourceType == 'speaker' then
        createSpeakerInHand()
    else
        removeSpeaker()
    end

    if sourceType == 'world' then
        local coords = GetEntityCoords(PlayerPedId())
        exports.xsound:Position(sourceId, coords)
    end
end

local function play3DSound(data)
    if not data or not data.sourceId or not data.streamUrl then
        return
    end

    local fallbackCoords = GetEntityCoords(PlayerPedId())
    local coords = fallbackCoords

    if data.entityNetId then
        local eCoords = getEntityCoordsByNet(data.entityNetId)
        if eCoords then coords = eCoords end
    end

    exports.xsound:PlayUrlPos(data.sourceId, data.streamUrl, data.volume or Config.DefaultVolume, coords, true)
    exports.xsound:Distance(data.sourceId, data.maxDistance or Config.MaxDistance)

    currentSourceId = data.sourceId
    currentTrack = data.track
    updateSourceAttachment(data.sourceId, data.sourceType, data.entityNetId)
end

local function stopCurrentTrack(sourceId)
    if sourceId then
        exports.xsound:Destroy(sourceId)
        if currentSourceId == sourceId then
            currentSourceId = nil
            currentTrack = nil
            currentSourceType = nil
            sourceAttachNetId = nil
            removeSpeaker()
            SendNUIMessage({ action = 'playingState', isPlaying = false })
        end
        return
    end

    if currentSourceId then
        exports.xsound:Destroy(currentSourceId)
    end

    currentSourceId = nil
    currentTrack = nil
    currentSourceType = nil
    sourceAttachNetId = nil
    removeSpeaker()
    SendNUIMessage({ action = 'playingState', isPlaying = false })
end

local function openUI(show)
    uiOpen = show
    SetNuiFocus(show, show)
    SendNUIMessage({ action = 'toggle', show = show })

    if show then
        TriggerServerEvent('seven_music:server:getLibrary')
    end
end

RegisterNetEvent('seven_music:client:toggleUI', function()
    openUI(not uiOpen)
end)

RegisterNetEvent('seven_music:client:searchResult', function(ok, err, items)
    SendNUIMessage({
        action = 'searchResult',
        ok = ok,
        error = err,
        items = items or {}
    })
end)

RegisterNetEvent('seven_music:client:libraryData', function(data)
    SendNUIMessage({
        action = 'libraryData',
        data = data or { recent = {}, liked = {} }
    })
end)

RegisterNetEvent('seven_music:client:startTrack', function(data)
    play3DSound(data)

    if data.owner == GetPlayerServerId(PlayerId()) then
        SendNUIMessage({ action = 'playingState', isPlaying = true, track = data.track })
    end
end)

RegisterNetEvent('seven_music:client:stopTrack', function(sourceId)
    stopCurrentTrack(sourceId)
end)

RegisterNetEvent('seven_music:client:updateTrackSource', function(sourceId, sourceType, netId)
    if currentSourceId ~= sourceId then return end
    updateSourceAttachment(sourceId, sourceType, netId)
end)

RegisterNetEvent('seven_music:client:setVolume', function(sourceId, volume)
    exports.xsound:setVolume(sourceId, volume)
end)

RegisterNetEvent('seven_music:client:notify', function(level, message)
    notify(level, message)
end)

RegisterNUICallback('close', function(_, cb)
    openUI(false)
    cb({ ok = true })
end)

RegisterNUICallback('search', function(data, cb)
    TriggerServerEvent('seven_music:server:search', data.query or '')
    cb({ ok = true })
end)

RegisterNUICallback('playTrack', function(data, cb)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    local sourceType = 'speaker'
    local netId = nil

    if vehicle ~= 0 then
        sourceType = 'vehicle'
        netId = NetworkGetNetworkIdFromEntity(vehicle)
    else
        local speaker = createSpeakerInHand()
        if speaker then
            netId = NetworkGetNetworkIdFromEntity(speaker)
        end
    end

    TriggerServerEvent('seven_music:server:playTrack', data.track, sourceType, netId)
    cb({ ok = true })
end)

RegisterNUICallback('stopTrack', function(_, cb)
    TriggerServerEvent('seven_music:server:stopTrack')
    cb({ ok = true })
end)

RegisterNUICallback('likeTrack', function(data, cb)
    TriggerServerEvent('seven_music:server:likeTrack', data.track)
    cb({ ok = true })
end)

RegisterNUICallback('unlikeTrack', function(data, cb)
    TriggerServerEvent('seven_music:server:unlikeTrack', data.trackId)
    cb({ ok = true })
end)

RegisterNUICallback('refreshLibrary', function(_, cb)
    TriggerServerEvent('seven_music:server:getLibrary')
    cb({ ok = true })
end)

CreateThread(function()
    while true do
        Wait(Config.AttachUpdateMs)

        if currentSourceId and currentSourceType and exports.xsound:soundExists(currentSourceId) then
            local coords = nil

            if currentSourceType == 'vehicle' then
                local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
                if vehicle ~= 0 then
                    local netId = NetworkGetNetworkIdFromEntity(vehicle)
                    if netId ~= sourceAttachNetId then
                        sourceAttachNetId = netId
                        TriggerServerEvent('seven_music:server:updateSource', 'vehicle', sourceAttachNetId)
                    end
                end
                coords = getEntityCoordsByNet(sourceAttachNetId)

            elseif currentSourceType == 'speaker' then
                if not speakerEntity or not DoesEntityExist(speakerEntity) then
                    createSpeakerInHand()
                    sourceAttachNetId = NetworkGetNetworkIdFromEntity(speakerEntity)
                    TriggerServerEvent('seven_music:server:updateSource', 'speaker', sourceAttachNetId)
                end
                coords = speakerEntity and GetEntityCoords(speakerEntity) or nil
            end

            if coords then
                exports.xsound:Position(currentSourceId, coords)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(750)

        if currentSourceId and currentSourceType == 'speaker' and currentTrack then
            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)
            if vehicle ~= 0 then
                sourceAttachNetId = NetworkGetNetworkIdFromEntity(vehicle)
                currentSourceType = 'vehicle'
                removeSpeaker()
                TriggerServerEvent('seven_music:server:updateSource', 'vehicle', sourceAttachNetId)
                debugPrint('Source moved to vehicle.')
            end
        end
    end
end)


-- Key mapping alternative can be added if you register a client command that triggers /som.
