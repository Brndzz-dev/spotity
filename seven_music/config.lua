--[[
    Seven Music - Configuration
    Central place for all tunables such as volume, distance, API credentials and permissions.
    Keep secrets server-side in production (ConVars/env) and avoid exposing private keys to clients.
]]

Config = {}

-- Debug prints for development. Disable in production.
Config.Debug = true

-- Default volume used when player starts music (0.01 - 1.0).
Config.DefaultVolume = 0.4

-- Maximum hearing distance for 3D audio.
Config.MaxDistance = 45.0

-- Minimum and maximum values accepted by /som <volume> command.
Config.MinVolumeCommand = 1
Config.MaxVolumeCommand = 100

-- Portable speaker model used when outside vehicles.
Config.SpeakerModel = `prop_boombox_01`

-- Optional: allow dropping speaker on ground by command/keybind extension.
Config.EnableSpeakerDrop = false

-- ACE permissions
Config.AdminAce = 'sevenmusic.admin'

-- Command names
Config.OpenCommand = 'som'

-- Spotify API credentials. Prefer setting through server.cfg convars:
-- setr seven_music_spotify_client_id "..."
-- setr seven_music_spotify_client_secret "..."
Config.SpotifyClientId = GetConvar('seven_music_spotify_client_id', '')
Config.SpotifyClientSecret = GetConvar('seven_music_spotify_client_secret', '')

-- Spotify country and search limit
Config.SpotifyMarket = 'BR'
Config.SearchLimit = 10

-- Streaming resolver mode:
-- 'yt_dlp_service' expects your custom backend endpoint returning direct/allowed stream URL
Config.AudioResolverMode = 'yt_dlp_service'
Config.AudioResolverEndpoint = GetConvar('seven_music_resolver_endpoint', 'http://127.0.0.1:30120/sevenmusic/resolve')

-- Database table names
Config.TableHistory = 'seven_music_history'
Config.TableLikes = 'seven_music_likes'

-- Tick rate for moving sound source update when attached to entity
Config.AttachUpdateMs = 400
