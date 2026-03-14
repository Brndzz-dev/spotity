--[[
    Seven Music - fxmanifest
    Declares this resource for FiveM and wires Lua/NUI files.
    Edit this file if you rename client/server scripts or add dependencies.
]]

fx_version 'cerulean'
game 'gta5'

lua54 'yes'

name 'seven_music'
author 'Seven Music / Codex'
description 'Spotify-style in-game music system with NUI and 3D positional audio via xsound'
version '1.0.0'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}

shared_scripts {
    'config.lua'
}

client_scripts {
    '@xsound/client/exports.lua',
    'client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

dependencies {
    'xsound'
}
