fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'loe_crash'
author 'loe'
description 'Fizik tabanli arac carpismasi ve aractan aninda ragdoll ile firlama'
version '1.0.0'

shared_script 'config.lua'

-- Sira onemli: physics (saf matematik) -> debug -> main
client_scripts {
    'client/physics.lua',
    'client/debug.lua',
    'client/main.lua',
}

-- Yalnizca Config.Debug.serverLog acikken debug satirlarini sunucu loguna yazar;
-- kapaliyken event hic kaydedilmez. Veritabani yok. qbx_core zorunlu degil: ol/baygin
-- kontrolu icin varsa exports.qbx_core:GetPlayerData() pcall ile okunur.
server_script 'server/debug.lua'

