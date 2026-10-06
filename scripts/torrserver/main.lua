-- TorrServer integration for mpv.
--
-- Provides a uosc menu for searching, adding, browsing, filtering, and
-- streaming torrents through a local TorrServer instance.
--
-- Search:
--   JacRed API: Native v1.0 or Jackett v2.0.
--
-- Supporting files:
--   scripts/torrserver/search-api.lua      JacRed search API client.
--   scripts/torrserver/torrserver-api.lua  TorrServer's own HTTP API + process management.
--   scripts/torrserver/torrserver-update.lua  TorrServer release/update management.
--   modules/native-dialog.lua               Cross-platform .torrent file picker.
--   modules/platform.lua                    OS and architecture detection.
--   modules/utils.lua                       Shared cache-dir/JSON/string helpers.
--
-- Configuration:
--   torrserver.conf controls TorrServer, search API, paths, retry/polling
--   settings, history, and search size filters.
--
-- Storage:
--   ~~/cache/torrserver/torrserver-history.json       Played torrent history.
--   ~~/cache/torrserver/torrserver-state.json         UI preferences (search API, etc).
--   ~~/cache/torrserver/torrserver-update-check.json  Cached update-check result.
--   ~~/bin/                                           TorrServer binary.

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")
local platform = dofile(mp.command_native({"expand-path", "~~/modules/platform.lua"}))
local native_dialog = dofile(mp.command_native({"expand-path", "~~/modules/native-dialog.lua"}))
local shared = dofile(mp.command_native({"expand-path", "~~/modules/utils.lua"}))
local updater = dofile(mp.command_native({"expand-path", "~~/scripts/torrserver/torrserver-update.lua"}))
local torrserver_api = dofile(mp.command_native({"expand-path", "~~/scripts/torrserver/torrserver-api.lua"}))
local search_api = dofile(mp.command_native({"expand-path", "~~/scripts/torrserver/search-api.lua"}))

local unpack = table.unpack or unpack
local script_name = mp.get_script_name()
local menu_type = "torrserver_menu"

local opts = {
    -- TorrServer (streams/hosts the torrent locally)
    torr_server = "http://localhost:8090",
    request_timeout = 15,
    -- search (JacRed; comma-separated = fallback order)
    search_server = "https://jac.red,https://jacred.stream",
    search_api = "native",
    search_api_key = "0",
    -- paths
    bin_path = "",
    browser_path = "",
    -- history
    history_limit = 20,
    stats_interval = 3,
    -- metadata polling (see torrserver.poll_metadata_async)
    metadata_retries = 5,
    metadata_retry_delay = 2,
    -- search polling (see search_torrents); 5s × 2 ≈ 10s total
    search_timeout = 5,
    search_retries = 2,
    search_retry_delay = 1,
    -- comma-separated file size ranges (GB) for search results, "min-max" or "min-" for open-ended
    size_filters = "0-10,10-20,20-30,30-50,50-100,100-",
    -- minimum seconds between passive update checks (menu opening does not
    -- force a network call more often than this); clicking "Update TorrServer"
    -- always checks live regardless of this interval
    update_check_interval = 86400,
    -- menu title truncation
    elide_titles = true,
    title_max_chars = 60,
    -- multi-file torrents: queue later video files after the one that was clicked
    queue_episodes = true,
    -- advance to the next queued file when the current one ends; no pauses instead
    playlist_autoplay = true,
    -- count | position | remaining. See torrserver.conf.
    episode_progress = "position",
    -- comma-separated extensions treated as episodes; everything else stays a single-file open
    video_extensions = "mkv,mp4,m4v,mov,avi,wmv,asf,webm,flv,f4v,mpg,mpeg,mpe,m2v,ts,m2ts,mts,m2t,vob,ogv,ogm,divx,3gp,3g2,rm,rmvb,qt,mk3d",
}
options.read_options(opts, "torrserver")
if opts.episode_progress ~= "position" and opts.episode_progress ~= "remaining" then
    opts.episode_progress = "count"
end

-- torrserver.conf keys stay flat above (mp.options can't bind nested
-- tables), grouped here once into the shape the rest of the script uses.
local metadata = {retries = opts.metadata_retries, delay = opts.metadata_retry_delay}
local search = {timeout = opts.search_timeout, retries = opts.search_retries, delay = opts.search_retry_delay}

local function split_csv(value)
    local parts = {}
    for token in (value or ""):gmatch("[^,]+") do
        local part = token:match("^%s*(.-)%s*$")
        if part ~= "" then parts[#parts + 1] = part end
    end
    return parts
end

local search_servers = split_csv(opts.search_server)
local video_extensions = {}
for _, extension in ipairs(split_csv(opts.video_extensions)) do
    video_extensions[extension:lower()] = true
end

local size_filters = {}
for _, token in ipairs(split_csv(opts.size_filters)) do
    local min_s, max_s = token:match("^(%d*)%-(%d*)$")
    if min_s and min_s ~= "" then
        local min_gb, max_gb = tonumber(min_s), tonumber(max_s)
        local label
        if not max_gb then label = min_gb .. "+ GB"
        elseif min_gb == 0 then label = "< " .. max_gb .. " GB"
        else label = min_gb .. "-" .. max_gb .. " GB" end
        size_filters[#size_filters + 1] = {
            label = label,
            min = min_gb * 1024 ^ 3,
            max = max_gb and (max_gb * 1024 ^ 3) or math.huge,
        }
    end
end

local quality_filters = {
    {label = "480p", value = 480},
    {label = "720p", value = 720},
    {label = "1080p", value = 1080},
    {label = "4K", value = 2160},
}
local videotype_filters = {
    {label = "SDR", value = "sdr"},
    {label = "HDR", value = "hdr"},
}
-- value is matched against info.types; some UI labels cover several API values
local type_filters = {
    {label = "Movie", value = "movie", match = {"movie"}},
    {label = "Serial", value = "serial", match = {"serial"}},
    {label = "TV show", value = "tvshow", match = {"tvshow"}},
    {label = "Documentary", value = "documentary", match = {"documovie", "docuserial"}},
    {label = "Anime", value = "anime", match = {"anime", "ova", "ona"}},
    {label = "Cartoon", value = "multfilm", match = {"multfilm"}},
    {label = "Animated series", value = "multserial", match = {"multserial"}},
}

local function quality_label(quality)
    for _, q in ipairs(quality_filters) do
        if q.value == quality then return q.label end
    end
    return quality and tostring(quality) or nil
end

local history = {}
local stats = {}
local stats_timer = nil
local menu_view = nil -- "root" | "search" | "files" | "filters"
local playing = { hash = nil, index = nil } -- currently loaded stream in mpv
local available_update = nil -- { installed = "...", latest = "..." } when update is available
local last_search = nil -- { query, items, urls }
local filter_keys = {"text", "size", "seeds", "quality", "videotype", "type", "year", "lang", "dub"}
local empty_filters = {seeds = false, dub = false}
local filters = {}
for _, k in ipairs(filter_keys) do filters[k] = empty_filters[k] end
local last_opened_magnet = nil
-- torrent added to TorrServer but not yet committed to history; a torrent is
-- only worth remembering once a file from it actually gets played, so this
-- stays uncommitted (and gets removed from TorrServer) if the user backs out
-- of the file list instead.
local pending_entry = nil
local files_back = nil -- "back" | "back_search" while in files menu
local files_items = nil -- items currently shown in the files menu
-- Per-torrent session marks. Skips drop files from the default "queue the rest"
-- path. Picks are an explicit playlist in the order the user added them.
local episode_skips = {}
local episode_picks = {}
local metadata_poll = nil -- poll handle while torrserver.poll_metadata_async is in flight

--- paths / cache -------------------------------------------------------

local function expand_path(path)
    return mp.command_native({"expand-path", path})
end

-- All of this script's own cache files live under their own subfolder, so
-- ~~/cache doesn't end up a flat pile shared with every other script.
local cache_dir = expand_path("~~/cache/torrserver")
local history_path = utils.join_path(cache_dir, "torrserver-history.json")
local state_path = utils.join_path(cache_dir, "torrserver-state.json")
local update_cache_path = utils.join_path(cache_dir, "torrserver-update-check.json")

-- Small persisted state (currently just the last-picked search API), distinct
-- from history: this is UI preference, not played-torrent history.
local function load_state()
    return shared.read_json_file(state_path) or {}
end

local function save_state(state)
    shared.write_json_file(state_path, state, true)
end

local trim = platform.trim

-- torrserver.conf's search_api is only the fallback for a fresh install (no
-- saved state yet); once the user switches via "Search API: ... (Click to
-- switch)" in the menu, that choice is remembered here across restarts.
local state = load_state()
local search_api_engine = state.search_api or (opts.search_api == "jackett" and "jackett" or "native")

local function load_history()
    local data = shared.read_json_file(history_path)
    if data then history = data end
end

local function save_history()
    while #history > opts.history_limit do
        table.remove(history)
    end
    shared.write_json_file(history_path, history, true)
end

local function find_history(hash)
    for i, entry in ipairs(history) do
        if entry.hash == hash then return entry, i end
    end
    return nil, nil
end

local function remember_history(entry)
    local _, i = find_history(entry.hash)
    if i then table.remove(history, i) end
    table.insert(history, 1, entry)
    save_history()
end

local function forget_history(hash)
    local _, i = find_history(hash)
    if i then
        table.remove(history, i)
        save_history()
    end
    stats[hash] = nil
end

local function commit_pending()
    if pending_entry then
        remember_history(pending_entry)
        pending_entry = nil
    end
end

load_history()

--- API clients -----------------------------------------------------------

local torrserver = torrserver_api.new({
    torr_server = opts.torr_server,
    request_timeout = opts.request_timeout,
    browser_path = opts.browser_path,
})

local search_client = search_api.new({
    servers = search_servers,
    api_key = opts.search_api_key,
    timeout = search.timeout,
    retries = search.retries,
    delay = search.delay,
    title_max_chars = opts.title_max_chars,
    elide_titles = opts.elide_titles,
    quality_label = quality_label,
})

--- torrent helpers ------------------------------------------------------

local function is_magnet(value)
    return type(value) == "string" and value:match("^magnet:%?") ~= nil
end

local function magnet_hash(magnet)
    local hash = magnet:match("[?&]xt=urn:btih:([^&]+)")
    return hash and hash:lower()
end

local function elide(str, max_chars)
    return shared.elide(str, max_chars, opts.elide_titles)
end

--- process management ---------------------------------------------------

local function show_error(message)
    mp.osd_message("TorrServer: " .. message, 5)
    mp.msg.error(message)
end

local function default_bin_path()
    return expand_path("~~/bin/" .. updater.default_bin_name(native_dialog.platform))
end

local function resolved_bin_path()
    return opts.bin_path ~= "" and opts.bin_path or default_bin_path()
end

local function start_torrserver(silent)
    local ok, error_text = torrserver.start(resolved_bin_path())
    if not ok and not silent then
        show_error(error_text)
    end
    return ok
end

local function stop_torrserver()
    torrserver.stop()
end

local function open_url(url)
    platform.open_url(url, opts.browser_path)
end

local function open_torrserver_ui()
    torrserver.open_ui()
end

-- "Open source" pauses playback instead of touching the stream, so leaving
-- the browser tab and hitting pause/play again just resumes where it was.
local function pause_if_playing(hash)
    if hash and playing.hash and hash:lower() == playing.hash then
        mp.set_property_bool("pause", true)
    end
end

local function read_clipboard()
    return platform.read_clipboard()
end

local function browse_torrent_file()
    local files, err = native_dialog.choose_files({
        title = "Select .torrent file",
        filters = {{label = "Torrent files", patterns = {"torrent"}}},
        multiselect = false,
    })
    if not files then
        if err then mp.msg.error("file dialog failed: " .. err) end
        return nil
    end
    return files[1]
end

--- menu -------------------------------------------------------------

local function send_menu(command, data)
    mp.commandv("script-message-to", "uosc", command, utils.format_json(data))
end

local function clear_search()
    mp.commandv("script-message-to", "uosc", "menu-action", "search-cancel")
end

local function close_menu()
    send_menu("close-menu", {type = menu_type})
end

local function menu_data(title, items, footnote)
    local data = {
        type = menu_type,
        id = menu_type,
        title = title,
        items = items,
        keep_open = true,
        search_debounce = "submit",
        on_search = "callback",
        on_paste = "callback",
        on_close = "callback",
        callback = {script_name, "torrserver-menu-event"},
    }
    if footnote then data.footnote = footnote end
    return data
end

local function back_item(target)
    return {title = "Back", icon = "arrow_back", value = target or "back", keep_open = true}
end

local episode_progress_label

local function stop_resume_action(hash)
    if hash and playing.hash and hash:lower() == playing.hash then
        return {name = "drop", icon = "stop", label = "Stop streaming"}
    end
    return {name = "resume", icon = "play_arrow", label = "Resume streaming"}
end

local function history_actions(entry)
    local actions = {stop_resume_action(entry.hash)}
    if episode_progress_label(entry.items, entry.hash) then
        actions[#actions + 1] = {name = "previous_episode", icon = "skip_previous", label = "Previous episode"}
        actions[#actions + 1] = {name = "next_episode", icon = "skip_next", label = "Next episode"}
    end
    if entry.source then
        actions[#actions + 1] = {name = "open_source", icon = "open_in_new", label = "Open source"}
    end
    actions[#actions + 1] = {name = "delete", icon = "delete", label = "Remove from history"}
    return actions
end

local function root_menu()
    local items = {
        {title = "Add magnet", icon = "content_paste", value = "add_magnet", keep_open = true},
        {title = "Add torrent file", icon = "folder_open", value = "add_torrent_file", keep_open = true},
        {
            title = "Open TorrServer",
            icon = "dns",
            value = "open_torrserver",
            keep_open = true,
            separator = not available_update,
        },
    }
    if available_update then
        local installed = available_update.installed
        local latest = available_update.latest
        items[#items + 1] = {
            title = installed and "Update TorrServer" or "Download TorrServer",
            icon = "cloud_download",
            hint = installed and (installed .. " → " .. latest) or latest,
            value = "update_torrserver",
            keep_open = true,
            separator = true,
        }
    end
    if last_search and last_search.query ~= "" then
        items[#items + 1] = {
            title = "Search: " .. elide(last_search.query, opts.title_max_chars),
            icon = "search",
            value = "show_search",
            keep_open = true,
            separator = true,
        }
    end
    for i, entry in ipairs(history) do
        local is_playing = playing.hash and entry.hash and entry.hash:lower() == playing.hash
        local hint_parts = {}
        local progress = episode_progress_label(entry.items, entry.hash)
        if progress then hint_parts[#hint_parts + 1] = progress end
        if stats[entry.hash] then hint_parts[#hint_parts + 1] = stats[entry.hash] end
        items[#items + 1] = {
            title = elide(entry.title, opts.title_max_chars),
            hint = #hint_parts > 0 and table.concat(hint_parts, " · ") or nil,
            icon = is_playing and "play_arrow" or (progress and "folder" or "movie"),
            value = "history:" .. entry.hash,
            keep_open = true,
            actions = history_actions(entry),
            separator = i == #history and #history > 1 or nil,
        }
    end
    -- Only worth offering once there's more than one entry in the history.
    if #history > 1 then
        items[#items + 1] = {
            title = "Remove all torrents",
            icon = "delete_sweep",
            value = "wipe_torrents",
            keep_open = true,
        }
    end
    return menu_data("Add torrent", items)
end

local function is_video_file(title)
    local extension = title and title:match("%.([%w]+)$")
    return extension and video_extensions[extension:lower()] or false
end

local function stream_hash(url)
    local hash = type(url) == "string" and url:match("[?&]link=([^&]+)")
    return hash and hash:lower() or nil
end

local function item_url(value)
    return type(value) == "table" and value[2] or nil
end

local function items_hash(items)
    for _, item in ipairs(items or {}) do
        local hash = stream_hash(item_url(item.value))
        if hash then return hash end
    end
end

local function video_items(items)
    local videos = {}
    for _, item in ipairs(items or {}) do
        if is_video_file(item.title) and item_url(item.value) then
            videos[#videos + 1] = item
        end
    end
    return videos
end

local function pick_index(hash, url)
    for index, picked in ipairs(episode_picks[hash] or {}) do
        if picked == url then return index end
    end
end

-- current/total while this torrent is playing. A loaded multi-file playlist
-- is the denominator; otherwise the episode index in the torrent file list.
local function playing_fraction(videos, hash)
    local total = #videos
    if total < 2 or not hash or playing.hash ~= hash then return nil, total end
    local count = mp.get_property_number("playlist-count") or 0
    local position = mp.get_property_number("playlist-pos") or -1
    local matched, current = 0, nil
    for index = 0, count - 1 do
        local filename = mp.get_property("playlist/" .. index .. "/filename") or ""
        if stream_hash(filename) == hash then
            matched = matched + 1
            if index == position then current = matched end
        end
    end
    if matched > 1 and current then return current, matched end
    local playing_url = mp.get_property("path")
    for index, item in ipairs(videos) do
        if item_url(item.value) == playing_url then return index, total end
    end
    return nil, total
end

function episode_progress_label(items, hash)
    local videos = video_items(items)
    if #videos < 2 then return nil end
    local current, shown_total = playing_fraction(videos, hash and hash:lower())
    if not current or opts.episode_progress == "count" then
        return #videos .. " episodes"
    end
    if opts.episode_progress == "remaining" then
        return (shown_total - current + 1) .. "/" .. shown_total
    end
    return current .. "/" .. shown_total
end

local function load_queue(queue)
    if #queue == 0 or not item_url(queue[1].value) then return false end
    if not mp.commandv("loadfile", queue[1].value[2], "replace") then return false end
    for index = 2, #queue do
        mp.commandv("loadfile", queue[index].value[2], "append")
    end
    for index, item in ipairs(queue) do
        mp.set_property("playlist/" .. (index - 1) .. "/title", item.title)
    end
    if #queue > 1 then mp.osd_message("Queued " .. (#queue - 1) .. " more", 2) end
    return true
end

-- Starts at the clicked video and appends every later video that was not skipped.
local function play_queued(value, items)
    local stream_url = item_url(value)
    if not opts.queue_episodes or not stream_url then
        return type(value) == "table" and mp.commandv(unpack(value))
    end
    local videos = video_items(items)
    local start_index
    for index, item in ipairs(videos) do
        if item_url(item.value) == stream_url then start_index = index break end
    end
    if not start_index or #videos < 2 then
        return mp.commandv(unpack(value))
    end
    local skipped = episode_skips[stream_hash(stream_url)] or {}
    local queue = {videos[start_index]}
    for index = start_index + 1, #videos do
        if not skipped[item_url(videos[index].value)] then queue[#queue + 1] = videos[index] end
    end
    return load_queue(queue)
end

-- Custom playlist if one was built, otherwise video files with skips removed.
local function episode_order(items)
    local hash = items_hash(items)
    local videos = video_items(items)
    local picks = hash and episode_picks[hash]
    if picks and #picks > 0 then
        local by_url = {}
        for _, item in ipairs(videos) do by_url[item_url(item.value)] = item end
        local ordered = {}
        for _, url in ipairs(picks) do
            if by_url[url] then ordered[#ordered + 1] = by_url[url] end
        end
        if #ordered > 0 then return ordered end
    end
    local skipped = hash and episode_skips[hash] or {}
    local ordered = {}
    for _, item in ipairs(videos) do
        if not skipped[item_url(item.value)] then ordered[#ordered + 1] = item end
    end
    return ordered
end

local function play_picked(items)
    return load_queue(episode_order(items))
end

local function toggle_episode_skip(value)
    local url = item_url(value)
    local hash = stream_hash(url)
    if not hash then return end
    local skipped = episode_skips[hash] or {}
    skipped[url] = not skipped[url] or nil
    episode_skips[hash] = skipped
end

local function toggle_episode_pick(value)
    local url = item_url(value)
    local hash = stream_hash(url)
    if not hash then return end
    local picks = episode_picks[hash] or {}
    local index = pick_index(hash, url)
    if index then table.remove(picks, index) else picks[#picks + 1] = url end
    episode_picks[hash] = picks
end

local function clear_marks(store, items)
    local hash = items_hash(items)
    if hash then store[hash] = nil end
end

local function is_playing_file(item)
    local url = item_url(item.value)
    if not playing.hash or stream_hash(url) ~= playing.hash then return false end
    if not playing.index then return true end
    return url:match("[?&]index=([^&]+)") == playing.index
end

local function show_files(items, back)
    files_items = items
    files_back = back or files_back or "back"
    menu_view = "files"
    clear_search()
    local menu_items = {back_item(files_back)}
    local videos = video_items(items)
    local hash = items_hash(items)
    local picks = hash and episode_picks[hash] or {}
    local skipped = hash and episode_skips[hash] or {}
    local skip_count = 0
    for _ in pairs(skipped) do skip_count = skip_count + 1 end
    local queueable = opts.queue_episodes and #videos > 1
    if queueable and #picks > 0 then
        menu_items[#menu_items + 1] = {
            title = "Play playlist (" .. #picks .. ")",
            hint = "in the order added",
            icon = "playlist_play",
            value = "play_picks",
            keep_open = true,
            actions = {{name = "clear_picks", icon = "close", label = "Clear playlist"}},
        }
    end
    if queueable and skip_count > 0 then
        menu_items[#menu_items + 1] = {
            title = "Include skipped (" .. skip_count .. ")",
            icon = "playlist_add",
            value = "clear_skips",
            keep_open = true,
            separator = true,
        }
    end
    for _, item in ipairs(items) do
        local url = item_url(item.value)
        local video = is_video_file(item.title)
        local skipped_file = video and skipped[url]
        local added = video and pick_index(hash, url)
        local hint = item.hint
        if added then hint = "#" .. added .. (hint and (" · " .. hint) or "") end
        local actions
        if video and queueable then
            actions = {
                {
                    name = "toggle_skip",
                    icon = skipped_file and "add" or "remove",
                    label = skipped_file and "Include" or "Skip",
                },
                {
                    name = "toggle_pick",
                    icon = added and "close" or "playlist_add",
                    label = added and "Remove from playlist" or "Add to playlist",
                },
            }
        end
        menu_items[#menu_items + 1] = {
            title = elide(item.title, opts.title_max_chars),
            hint = hint,
            icon = is_playing_file(item) and "play_arrow" or (skipped_file and "visibility_off" or (video and "movie" or "description")),
            value = item.value,
            actions = actions,
        }
    end
    if #menu_items == 1 then
        menu_items[#menu_items + 1] = {title = "No files returned by TorrServer", selectable = false}
    end
    local footnote
    if queueable then
        footnote = (episode_progress_label(items, hash) or (#videos .. " episodes"))
            .. " · click plays it and queues the rest · Skip excludes · Add to playlist builds your own"
    end
    send_menu("update-menu", menu_data("Files", menu_items, footnote))
end

local function refresh_files()
    if files_items then show_files(files_items) end
end

--- search -----------------------------------------------------------

local function list_has(list, value)
    if not list or value == nil then return false end
    local lv = type(value) == "string" and value:lower() or value
    for _, v in ipairs(list) do
        if type(v) == "string" and type(lv) == "string" then
            if v:lower() == lv then return true end
        elseif v == value then
            return true
        end
    end
    return false
end

local function has_dub(item)
    if not item.voices then return false end
    for _, v in ipairs(item.voices) do
        -- API always sends "Дубляж"; Lua lower() does not fold Cyrillic
        if v == "Дубляж" then return true end
    end
    return false
end

local function item_matches(item, f)
    if f.text then
        local title = (item.title or ""):lower()
        for word in f.text:lower():gmatch("%S+") do
            if not title:find(word, 1, true) then return false end
        end
    end
    if f.size then
        local size = item.size or 0
        if size < f.size.min or size > f.size.max then return false end
    end
    if f.seeds and (item.seeders or 0) == 0 and (item.peers or 0) == 0 then
        return false
    end
    if f.quality and item.quality ~= f.quality then return false end
    if f.videotype and (not item.videotype or item.videotype:lower() ~= f.videotype) then return false end
    if f.type then
        local matched = false
        for _, tf in ipairs(type_filters) do
            if tf.value == f.type then
                for _, m in ipairs(tf.match) do
                    if list_has(item.types, m) then matched = true break end
                end
                break
            end
        end
        if not matched then return false end
    end
    if f.year and item.released ~= f.year then return false end
    if f.lang and not list_has(item.languages, f.lang) then return false end
    if f.dub and not has_dub(item) then return false end
    return true
end

local function count_matches(f)
    if not last_search or not last_search.items then return 0 end
    local n = 0
    for _, item in ipairs(last_search.items) do
        if item_matches(item, f) then n = n + 1 end
    end
    return n
end

-- Snapshot of filter fields; nils mean "not constrained". Used for independent
-- per-option counters and for the active selection.
local function filter_state(overrides)
    local state = {}
    for _, k in ipairs(filter_keys) do state[k] = empty_filters[k] end
    for k, v in pairs(overrides or {}) do state[k] = v end
    return state
end

local function current_filter_state()
    return filter_state(filters)
end

local function has_active_filters()
    for _, k in ipairs(filter_keys) do
        if filters[k] ~= empty_filters[k] then return true end
    end
    return false
end

local function reset_filters()
    for _, k in ipairs(filter_keys) do filters[k] = empty_filters[k] end
end

-- Single source of truth for "how many results match right now" and its
-- wording, shared by the filters-menu header and the search-menu Filters row.
local function results_count()
    if not last_search or not last_search.items then return 0 end
    if has_active_filters() then return count_matches(current_filter_state()) end
    return #last_search.items
end

local function results_hint()
    return tostring(results_count()) .. (has_active_filters() and " filtered" or " found")
end

local function filters_clear_item()
    local active = has_active_filters()
    return {
        title = active and "Clear filters" or "All results",
        hint = results_hint(),
        icon = active and "close" or "filter_list",
        value = active and "clear_filters" or nil,
        selectable = active,
        keep_open = true,
        separator = true,
    }
end

local function collect_result_values(field)
    if not last_search or not last_search.items then return {} end
    local seen, values = {}, {}
    for _, item in ipairs(last_search.items) do
        local v = item[field]
        if type(v) == "table" then
            for _, entry in ipairs(v) do
                if entry ~= nil and not seen[entry] then
                    seen[entry] = true
                    values[#values + 1] = entry
                end
            end
        elseif v ~= nil and not seen[v] then
            seen[v] = true
            values[#values + 1] = v
        end
    end
    table.sort(values, function(a, b)
        if type(a) == "number" and type(b) == "number" then return a > b end
        return tostring(a) < tostring(b)
    end)
    return values
end

local function append_toggle_items(menu_items, options, selected, field, icon, value_prefix)
    for i, opt in ipairs(options) do
        local active = selected == opt.value
        menu_items[#menu_items + 1] = {
            title = opt.label,
            hint = tostring(count_matches(filter_state({[field] = opt.value}))),
            icon = active and "check" or icon,
            value = value_prefix .. tostring(opt.value),
            keep_open = true,
            separator = i == #options,
        }
    end
end

local function filters_menu()
    menu_view = "filters"
    local menu_items = {back_item("back_search")}
    menu_items[#menu_items + 1] = filters_clear_item()

    append_toggle_items(menu_items, quality_filters, filters.quality, "quality", "hd", "quality:")
    append_toggle_items(menu_items, videotype_filters, filters.videotype, "videotype", "tonality", "videotype:")
    append_toggle_items(menu_items, type_filters, filters.type, "type", "category", "type:")

    menu_items[#menu_items + 1] = {
        title = "Dub",
        hint = tostring(count_matches(filter_state({dub = true}))),
        icon = filters.dub and "check" or "record_voice_over",
        value = "dub_filter",
        keep_open = true,
        separator = true,
    }

    local langs = collect_result_values("languages")
    for i, lang in ipairs(langs) do
        menu_items[#menu_items + 1] = {
            title = lang,
            hint = tostring(count_matches(filter_state({lang = lang}))),
            icon = filters.lang == lang and "check" or "translate",
            value = "lang:" .. lang,
            keep_open = true,
            separator = i == #langs,
        }
    end

    local years = collect_result_values("released")
    for i, year in ipairs(years) do
        menu_items[#menu_items + 1] = {
            title = tostring(year),
            hint = tostring(count_matches(filter_state({year = year}))),
            icon = filters.year == year and "check" or "event",
            value = "year:" .. tostring(year),
            keep_open = true,
            separator = i == #years,
        }
    end

    for i, sf in ipairs(size_filters) do
        local active = filters.size and filters.size.min == sf.min and filters.size.max == sf.max
        menu_items[#menu_items + 1] = {
            title = sf.label,
            hint = tostring(count_matches(filter_state({size = sf}))),
            icon = active and "check" or "straighten",
            value = "size_filter:" .. i,
            keep_open = true,
            separator = i == #size_filters,
        }
    end

    menu_items[#menu_items + 1] = {
        title = "Seeds/Peers",
        hint = tostring(count_matches(filter_state({seeds = true}))),
        icon = filters.seeds and "check" or "wifi",
        value = "seeds_filter",
        keep_open = true,
    }

    return menu_data("Filters", menu_items)
end

local function filters_label()
    local parts = {}
    if filters.text then parts[#parts + 1] = filters.text end
    if filters.quality then
        for _, q in ipairs(quality_filters) do
            if q.value == filters.quality then parts[#parts + 1] = q.label break end
        end
    end
    if filters.videotype then parts[#parts + 1] = filters.videotype:upper() end
    if filters.type then
        for _, t in ipairs(type_filters) do
            if t.value == filters.type then parts[#parts + 1] = t.label break end
        end
    end
    if filters.dub then parts[#parts + 1] = "Dub" end
    if filters.lang then parts[#parts + 1] = filters.lang end
    if filters.year then parts[#parts + 1] = tostring(filters.year) end
    if filters.size then parts[#parts + 1] = filters.size.label end
    if filters.seeds then parts[#parts + 1] = "seeds/peers" end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

local function search_api_label()
    return search_api_engine == "native" and "Native" or "Jackett"
end

-- Forward-declared: cycle_sort (below) needs to call these, but they're
-- defined further down where the rest of the search-results pipeline lives.
local apply_filters, render_search_menu

local function search_api_item()
    return {
        title = "Search API: " .. search_api_label(),
        hint = "Click to switch",
        icon = "swap_horiz",
        value = "toggle_search_api",
        keep_open = true,
        separator = true,
    }
end

-- Compact, single-row cycling control (same pattern as search_api_item)
-- rather than a submenu, so sorting doesn't add height to the results list.
local sort_options = {
    {key = "none", label = "Default order", icon = "sort"},
    {key = "seeders_desc", label = "Seeds", icon = "arrow_downward"},
    {key = "size_desc", label = "Size", icon = "arrow_downward"},
    {key = "size_asc", label = "Size", icon = "arrow_upward"},
}
local sort_index = 1

local function sort_item()
    local opt = sort_options[sort_index]
    return {
        title = "Sort: " .. opt.label,
        hint = "Click to cycle",
        icon = opt.icon,
        value = "cycle_sort",
        keep_open = true,
    }
end

local function sort_items(items)
    local key = sort_options[sort_index].key
    if key == "none" then return items end
    local sorted = {}
    for i, it in ipairs(items) do sorted[i] = it end
    if key == "seeders_desc" then
        table.sort(sorted, function(a, b) return (a.seeders or 0) > (b.seeders or 0) end)
    elseif key == "size_desc" then
        table.sort(sorted, function(a, b) return (a.size or 0) > (b.size or 0) end)
    elseif key == "size_asc" then
        table.sort(sorted, function(a, b) return (a.size or 0) < (b.size or 0) end)
    end
    return sorted
end

local function cycle_sort()
    sort_index = sort_index % #sort_options + 1
    if has_active_filters() then
        apply_filters()
    else
        render_search_menu(true)
    end
end

local function search_menu(items)
    local menu_items = {back_item(), search_api_item()}

    if last_search and last_search.items and #last_search.items > 0 then
        local label = filters_label()
        local filters_item = {
            title = label and ("Filter: " .. elide(label, opts.title_max_chars)) or "Filters",
            hint = results_hint(),
            icon = "filter_list",
            value = "show_filters",
            keep_open = true,
        }
        if label then
            filters_item.actions = {{name = "clear_filter", icon = "close", label = "Clear filter"}}
        end
        menu_items[#menu_items + 1] = filters_item
        menu_items[#menu_items + 1] = sort_item()
    end

    for _, item in ipairs(items) do menu_items[#menu_items + 1] = item end
    return menu_data("Search torrents", menu_items)
end

-- Redraws the cached search results (or a placeholder) without hitting the
-- network, so returning to a previous search is instant.
local function apply_opened_icons(items)
    for _, item in ipairs(items) do
        item.icon = (item.value == last_opened_magnet) and "visibility" or "movie"
    end
end

function apply_filters()
    apply_opened_icons(last_search.items)
    local filtered = {}
    if has_active_filters() then
        for _, item in ipairs(last_search.items) do
            if item_matches(item, current_filter_state()) then filtered[#filtered + 1] = item end
        end
    else
        filtered = last_search.items
    end
    if #filtered == 0 then
        filtered = {{title = "No matches", selectable = false}}
    else
        filtered = sort_items(filtered)
    end
    menu_view = "search"
    send_menu("update-menu", search_menu(filtered))
end

local function clear_filters(to_search)
    reset_filters()

    if to_search then
        apply_filters()
    else
        send_menu("update-menu", filters_menu())
    end
end

local function set_text_filter(query)
    query = trim(query)
    filters.text = query ~= "" and query or nil
    apply_filters()
end

local function toggle_field(filter_field, value)
    if value == nil then
        filters[filter_field] = not filters[filter_field]
    elseif filters[filter_field] == value then
        filters[filter_field] = nil
    else
        filters[filter_field] = value
    end
    send_menu("update-menu", filters_menu())
end

local function toggle_size_filter(index)
    index = tonumber(index)
    if not index then return end
    local sf = size_filters[index]
    if not sf then return end
    if filters.size and filters.size.min == sf.min and filters.size.max == sf.max then
        filters.size = nil
    else
        filters.size = sf
    end
    send_menu("update-menu", filters_menu())
end

-- "prefix:value" filter toggles from filters_menu's item values. Length is
-- always computed from the prefix string itself, never hardcoded, so a
-- prefix can change length without silently breaking its offset.
local filter_value_prefixes = {
    {prefix = "quality:", filter_field = "quality", cast = tonumber},
    {prefix = "videotype:", filter_field = "videotype"},
    {prefix = "type:", filter_field = "type"},
    {prefix = "lang:", filter_field = "lang"},
    {prefix = "year:", filter_field = "year", cast = tonumber},
}

-- Returns true and applies the toggle if event.value matched one of the
-- prefixes above, so the event handler's elseif chain can fall through
-- to size_filter:/other cases otherwise.
local function try_toggle_prefixed_filter(value)
    if type(value) ~= "string" then return false end
    for _, p in ipairs(filter_value_prefixes) do
        if value:sub(1, #p.prefix) == p.prefix then
            local raw = value:sub(#p.prefix + 1)
            toggle_field(p.filter_field, p.cast and p.cast(raw) or raw)
            return true
        end
    end
    return false
end

-- Re-renders search results against the current filter state (text + size + seeds).
function render_search_menu(preserve_filter)
    files_back = nil
    menu_view = "search"
    clear_search()
    if not preserve_filter then reset_filters() end
    if last_search and last_search.items and #last_search.items > 0 and has_active_filters() then
        apply_filters()
        return
    end
    local items = last_search and last_search.items or {}
    if #items == 0 then
        items = {{title = (last_search and last_search.query ~= "") and "No results" or "Type to search...", selectable = false}}
    else
        apply_opened_icons(items)
        items = sort_items(items)
    end
    send_menu("update-menu", search_menu(items))
end

local function search_torrents(query)
    query = trim(query)
    if query == "" then
        last_search = nil
        last_opened_magnet = nil
        menu_view = nil
        render_search_menu()
        return
    end
    last_opened_magnet = nil
    if not start_torrserver() then return end

    menu_view = "search"
    local items, urls, error_text = search_client.search(search_api_engine, query, function(attempt, total)
        local label = "Searching..."
        if total > 1 then label = label .. " (" .. attempt .. "/" .. total .. ")" end
        send_menu("update-menu", search_menu({{title = label, icon = "spinner", selectable = false}}))
    end)
    if #items == 0 then
        show_error(error_text or "search failed")
        render_search_menu()
        return
    end

    last_search = {query = query, items = items, urls = urls}
    render_search_menu(true) -- preserve filters if already set
end

--- flows ------------------------------------------------------------

local function begin_add(back)
    if not start_torrserver() then return false end
    send_menu("update-menu", menu_data("Add torrent", {
        back_item(back),
        {title = "Adding torrent...", icon = "spinner", selectable = false},
    }))
    return true
end

-- Forward-declared: remove_torrent and return_to_root (below) are needed
-- here to clean up an orphaned add and leave the menu somewhere sane when
-- retries run out — otherwise the last "Waiting for metadata..." spinner
-- frame stays on screen forever with nothing left to update it.
local remove_torrent, return_to_root

-- Goes back to wherever the add was started from: the search results if it
-- came from there, the root menu otherwise.
local function back_to_previous(back)
    if back == "back_search" then
        render_search_menu(true)
    else
        return_to_root()
    end
end

-- Shared tail for both add flows: resolve, show files. Not committed to
-- history yet — see pending_entry / commit_pending.
local function finish_add(response, error_text, hash, fallback_title, source, back)
    if not response then
        show_error(error_text or "could not add torrent")
        back_to_previous(back)
        return
    end

    -- Completes the flow once a torrent (with files) is known, whether that
    -- came back immediately or after polling for metadata.
    local function complete(torrent, items, poll_error)
        if not torrent or #items == 0 then
            -- Torrent was already added to TorrServer (save_to_db=true); with no
            -- files to show there's nothing pending to discard it later, so it
            -- would otherwise sit there orphaned. Clean it up now instead.
            local orphan_hash = (torrent and torrserver_api.torrent_hash(torrent)) or hash
            if orphan_hash then remove_torrent(orphan_hash) end
            show_error(poll_error or "no files found")
            back_to_previous(back)
            return
        end
        local title = torrserver_api.torrent_title(torrent) or fallback_title
        pending_entry = {hash = torrserver_api.torrent_hash(torrent) or hash, title = title, items = items, source = source}
        show_files(items, back)
    end

    local torrent = torrserver_api.find_added_torrent(response, hash)
    if not torrent and not hash and type(response[1]) == "table" then
        torrent = response[1]
    end
    local items = torrent and torrserver.file_items(torrent) or {}
    if #items > 0 then
        complete(torrent, items)
        return
    end

    -- Metadata (file list) can take a few seconds to arrive after adding, so
    -- poll for it; cancel_pending_add() can abort this while it's running.
    metadata_poll = torrserver.poll_metadata_async(hash, metadata.retries, metadata.delay, function(attempt, total)
        send_menu("update-menu", menu_data("Add torrent", {
            back_item(back),
            {title = "Waiting for metadata (" .. attempt .. "/" .. total .. ")...", icon = "spinner", selectable = false},
        }))
    end, function(torrent, items, poll_error)
        metadata_poll = nil
        complete(torrent, items, poll_error)
    end)
    metadata_poll.back = back
end

local function add_magnet(magnet, source, back)
    if not is_magnet(magnet) then
        show_error("clipboard does not contain a magnet link")
        return
    end
    if not begin_add(back) then return end

    local hash = magnet_hash(magnet)
    local response, error_text = torrserver.add(magnet)
    finish_add(response, error_text, hash, "Untitled torrent", source, back)
end

local function stop_stats_polling()
    if stats_timer then
        stats_timer:kill()
        stats_timer = nil
    end
end

local stats_refresh_in_flight = false

local function apply_stats_response(list_response)
    local changed = false
    for _, entry in ipairs(history) do
        local torrent = torrserver_api.find_added_torrent(list_response, entry.hash)
        local hint = torrent and torrserver_api.torrent_stat_hint(torrent) or nil
        if hint ~= stats[entry.hash] then
            changed = true
        end
        stats[entry.hash] = hint
    end
    if changed and menu_view == "root" then
        send_menu("update-menu", root_menu())
    end
end

-- Non-blocking: this used to run synchronously on the main thread, which
-- meant a slow or unresponsive TorrServer froze the whole mpv UI for up to
-- several seconds on every single poll. in_flight guards against a slow
-- response overlapping the next timer tick. The timer itself keeps running
-- for as long as the menu is open (any view), but the request only matters
-- while root is showing, so skip it otherwise instead of hitting the network
-- every tick for nothing.
local function refresh_stats()
    if menu_view ~= "root" then return end
    if stats_refresh_in_flight then return end
    stats_refresh_in_flight = true
    torrserver.list(function(list_response)
        stats_refresh_in_flight = false
        if not list_response then return end
        apply_stats_response(list_response)
    end)
end

-- Fully asynchronous, and gated end-to-end by the on-disk cache: within
-- update_check_interval (a day, by default) this is a plain file read with
-- no subprocess spawn and no network call at all.
local function check_for_update()
    updater.cached_update_status_async(native_dialog.platform, resolved_bin_path(), update_cache_path, opts.update_check_interval, function(installed, release)
        if not release then return end
        if not installed or installed ~= release.version then
            local prev = available_update
            if not prev or prev.latest ~= release.version or prev.installed ~= installed then
                available_update = {installed = installed, latest = release.version}
                if menu_view == "root" then send_menu("update-menu", root_menu()) end
            end
        elseif available_update then
            available_update = nil
            if menu_view == "root" then send_menu("update-menu", root_menu()) end
        end
    end)
end

-- Kicks off a stats refresh (now async, see refresh_stats) so the root menu's
-- seeds/speed/history update shortly after it opens, then keeps polling.
local function show_root_menu(command)
    if start_torrserver(true) then refresh_stats() end
    files_back = nil
    menu_view = "root"
    clear_search()
    send_menu(command, root_menu())
    if not stats_timer then
        stats_timer = mp.add_periodic_timer(opts.stats_interval, refresh_stats)
    end
end

-- Leaving search back to the root menu drops the active filter, so
-- reopening search via "Search: ..." starts unfiltered.
function return_to_root()
    if menu_view == "search" then
        reset_filters()
    end
    show_root_menu("update-menu")
end

local function stop_if_playing(hash)
    if hash and playing.hash and hash:lower() == playing.hash then
        mp.commandv("stop")
    end
end

local function drop_torrent(hash)
    local ok, error_text = torrserver.drop(hash)
    if not ok then
        show_error("could not stop torrent: " .. (error_text or ""))
    else
        stop_if_playing(hash)
    end
    return ok
end

function remove_torrent(hash)
    drop_torrent(hash)
    local ok, error_text = torrserver.remove(hash)
    if not ok then
        show_error("could not remove torrent from TorrServer: " .. (error_text or ""))
    end
    return ok
end

-- "Remove all torrents": wipes everything TorrServer knows about in one call,
-- rather than dropping/removing each history entry individually.
local function wipe_all_torrents()
    send_menu("update-menu", menu_data("Add torrent", {
        back_item(),
        {title = "Removing all torrents...", icon = "spinner", selectable = false},
    }))
    if playing.hash then mp.commandv("stop") end
    local ok, error_text = torrserver.wipe()
    if not ok then
        show_error("could not remove all torrents: " .. (error_text or ""))
    else
        history = {}
        stats = {}
        save_history()
    end
    send_menu("update-menu", root_menu())
end

-- Leaving the file list without playing anything means the user didn't want
-- that torrent after all, so undo what save_to_db=true persisted in TorrServer.
local function discard_pending()
    if pending_entry then
        remove_torrent(pending_entry.hash)
        pending_entry = nil
    end
end

-- Undoes an add that hasn't been committed to history yet, whichever stage
-- it's at: an in-flight metadata poll (see torrserver.poll_metadata_async) or
-- an already-resolved pending_entry. Returns the poll's back target, if any,
-- so callers don't need to inspect metadata_poll themselves.
local function cancel_pending_add()
    local back
    if metadata_poll then
        metadata_poll.cancelled = true
        back = metadata_poll.back
        if metadata_poll.hash then remove_torrent(metadata_poll.hash) end
        metadata_poll = nil
    end
    discard_pending()
    return back
end

local function open_history_entry(hash)
    local entry = find_history(hash)
    if not entry then
        show_error("history entry no longer available")
        return
    end
    if not start_torrserver() then return end
    show_files(entry.items)
end

-- "Resume streaming" plays straight away instead of opening the file list;
-- opening the file list is reserved for clicking the history row itself.
local function play_history_entry(hash)
    local entry = find_history(hash)
    if not entry or not entry.items or #entry.items == 0 then
        show_error("history entry no longer available")
        return
    end
    if not start_torrserver() then return end
    local videos = video_items(entry.items)
    local value = (videos[1] or entry.items[1]).value
    if not play_queued(value, entry.items) then
        show_error("failed to start playback")
    end
end

local function order_index(order, url)
    for index, item in ipairs(order) do
        if item_url(item.value) == url then return index end
    end
end

-- Previous/next follow episode_order. A manually played skipped file still
-- steps to the nearest kept episode on either side.
local function play_adjacent(hash, step)
    local entry = find_history(hash)
    if not entry then
        show_error("history entry no longer available")
        return
    end
    if not start_torrserver() then return end
    local order = episode_order(entry.items)
    if #order == 0 then
        show_error("no episodes")
        return
    end
    local current_url = playing.hash == hash:lower() and mp.get_property("path") or nil
    local current_index = current_url and order_index(order, current_url)
    if current_url and not current_index then
        local file_index = order_index(video_items(entry.items), current_url)
        if file_index then
            for index, item in ipairs(order) do
                local kept = order_index(video_items(entry.items), item_url(item.value))
                if step < 0 and kept < file_index then current_index = index + 1 end
                if step > 0 and kept > file_index then current_index = index - 1 break end
            end
        end
    end
    local target = current_index and (current_index + step) or (step > 0 and 1 or nil)
    if not target or target < 1 or target > #order then
        mp.osd_message(step > 0 and "No next episode" or "No previous episode", 2)
        return
    end
    local queue = {}
    for index = target, #order do queue[#queue + 1] = order[index] end
    if not load_queue(queue) then show_error("failed to start playback") end
end

local function add_torrent_from_file(filepath)
    filepath = trim(filepath)
    if filepath == "" then
        show_error("file path is empty")
        return
    end

    if not utils.file_info(filepath) then
        show_error("file not found: " .. filepath)
        return
    end

    if not filepath:match("%.torrent$") then
        show_error("file must have .torrent extension")
        return
    end

    if not begin_add() then return end

    local _, filename = utils.split_path(filepath)
    local response, error_text = torrserver.request_upload(filepath)
    finish_add(response, error_text, nil, filename)
end

local function finalize_update(bin_path, tmp_path, installed, version)
    stop_torrserver()
    platform.sleep(1)

    local replaced, replace_error = updater.replace_binary(bin_path, tmp_path)
    if not replaced then
        os.remove(tmp_path)
        show_error(replace_error or "failed to replace TorrServer binary")
        send_menu("update-menu", root_menu())
        return
    end

    available_update = nil
    -- Keeps today's remaining passive checks (see check_for_update) from
    -- re-detecting the version we just installed as an available update.
    shared.write_json_file(update_cache_path, {checked_at = os.time(), installed = version, release = {version = version}}, true)
    start_torrserver()
    mp.osd_message("TorrServer " .. (installed and "updated to" or "installed:") .. " " .. version, 3)
    send_menu("update-menu", root_menu())
end

local function update_torrserver()
    local bin_path = resolved_bin_path()
    local installed = updater.installed_version(bin_path)

    send_menu("update-menu", menu_data("Add torrent", {
        back_item(),
        {title = "Checking for TorrServer updates...", icon = "spinner", selectable = false},
    }))
    -- Bypasses the passive TTL cache: an explicit click should always check live.
    local release, error_text = updater.latest_release(native_dialog.platform)
    if not release then
        show_error(error_text or "could not check for updates")
        send_menu("update-menu", root_menu())
        return
    end
    if installed and installed == release.version then
        available_update = nil
        mp.osd_message("TorrServer: already up to date (" .. installed .. ")", 3)
        send_menu("update-menu", root_menu())
        return
    end

    local tmp_path = bin_path .. ".new"
    updater.download_async(release.url, tmp_path, release.size, function(percent)
        local label = "Downloading TorrServer " .. release.version .. "..."
        if percent then label = label .. " " .. percent .. "%" end
        send_menu("update-menu", menu_data("Add torrent", {
            back_item(),
            {title = label, icon = "spinner", selectable = false},
        }))
    end, function(ok, download_error)
        if not ok then
            os.remove(tmp_path)
            show_error("update download failed: " .. (download_error or "unknown error"))
            send_menu("update-menu", root_menu())
            return
        end
        finalize_update(bin_path, tmp_path, installed, release.version)
    end)
end

--- events -------------------------------------------------------------

local history_prefix = "history:"

local function history_hash(value)
    if type(value) == "string" and value:sub(1, #history_prefix) == history_prefix then
        return value:sub(#history_prefix + 1)
    end
    return nil
end

-- Playing state reflects what's actually loaded in mpv, not TorrServer's
-- download activity (which can stay nonzero briefly after a stream is dropped).
mp.observe_property("path", "string", function(_, path)
    local hash = stream_hash(path)
    local index = path and path:match("[?&]index=([^&]+)")
    if hash ~= playing.hash or index ~= playing.index then
        playing.hash = hash
        playing.index = index
        if menu_view == "root" then
            send_menu("update-menu", root_menu())
        elseif menu_view == "files" and files_items then
            show_files(files_items)
        end
    end
end)

mp.register_script_message("torrserver-menu-event", function(json)
    local event = utils.parse_json(json)

    if event.type == "search" then
        if menu_view == "search" and last_search and last_search.items and #last_search.items > 0 then
            set_text_filter(event.query)
        else
            search_torrents(event.query)
        end
        return
    end
    if event.type == "paste" then
        add_magnet(event.value)
        return
    end
    if event.type == "close" then
        discard_pending()
        stop_stats_polling()
        files_back = nil
        menu_view = nil
        return
    end
    if event.type == "back" then
        -- menu_view hasn't switched to "files" yet while a metadata poll is
        -- in flight, so its own back target decides where to land instead.
        local poll_back = cancel_pending_add()
        if poll_back then
            back_to_previous(poll_back)
        elseif menu_view == "filters" or (menu_view == "files" and files_back == "back_search") then
            render_search_menu(true)
        else
            return_to_root()
        end
        return
    end
    if event.type ~= "activate" then return end

    if event.action == "delete" then
        local hash = history_hash(event.value)
        if hash then
            send_menu("update-menu", menu_data("Add torrent", {
                back_item(),
                {title = "Removing torrent...", icon = "spinner", selectable = false},
            }))
            if remove_torrent(hash) then
                forget_history(hash)
            end
            send_menu("update-menu", root_menu())
            return
        end
    end
    if event.action == "drop" then
        local hash = history_hash(event.value)
        if hash then
            drop_torrent(hash)
            send_menu("update-menu", root_menu())
            return
        end
    end
    if event.action == "resume" then
        local hash = history_hash(event.value)
        if hash then
            play_history_entry(hash)
            send_menu("update-menu", root_menu())
            return
        end
    end
    if event.action == "previous_episode" or event.action == "next_episode" then
        local hash = history_hash(event.value)
        if hash then
            play_adjacent(hash, event.action == "next_episode" and 1 or -1)
            send_menu("update-menu", root_menu())
        end
        return
    end
    if event.action == "clear_filter" then
        clear_filters(true) -- Stay in search menu
        return
    end
    if event.action == "open_source" then
        local hash = history_hash(event.value)
        if hash then
            local entry = find_history(hash)
            if entry and entry.source then
                pause_if_playing(hash)
                open_url(entry.source)
            end
            return
        end
        local url = last_search and last_search.urls and last_search.urls[event.value]
        if url then
            pause_if_playing(magnet_hash(event.value))
            open_url(url)
            last_opened_magnet = event.value
            if has_active_filters() then
                apply_filters()
            else
                render_search_menu()
            end
        end
        return
    end
    if event.action == "clear_picks" then
        clear_marks(episode_picks, files_items)
        refresh_files()
        return
    end
    if event.action == "copy_magnet" then
        -- Search results only: event.value is the magnet URI itself here,
        -- unlike history items (see history_hash usage above).
        if not history_hash(event.value) then
            platform.write_clipboard(event.value)
            mp.osd_message("Magnet link copied", 2)
        end
        return
    end
    if type(event.value) == "table" then
        if event.action == "toggle_skip" then
            toggle_episode_skip(event.value)
            refresh_files()
            return
        end
        if event.action == "toggle_pick" then
            toggle_episode_pick(event.value)
            refresh_files()
            return
        end
        if play_queued(event.value, files_items) then
            commit_pending()
        else
            show_error("failed to start playback")
        end
    elseif event.value == "play_picks" then
        if play_picked(files_items) then
            commit_pending()
        else
            show_error("playlist is empty")
        end
    elseif event.value == "clear_skips" then
        clear_marks(episode_skips, files_items)
        refresh_files()
    elseif event.value == "add_magnet" then
        add_magnet(read_clipboard())
    elseif event.value == "open_torrserver" then
        if start_torrserver() then open_torrserver_ui() end
    elseif event.value == "update_torrserver" then
        update_torrserver()
    elseif event.value == "wipe_torrents" then
        wipe_all_torrents()
    elseif event.value == "add_torrent_file" then
        local filepath = browse_torrent_file()
        if filepath then
            add_torrent_from_file(filepath)
        else
            mp.msg.info("No file selected")
        end
    elseif event.value == "toggle_search_api" then
        if not last_search or last_search.query == "" then return end
        search_api_engine = search_api_engine == "native" and "jackett" or "native"
        state.search_api = search_api_engine
        save_state(state)
        search_torrents(last_search.query)
    elseif event.value == "cycle_sort" then
        cycle_sort()
    elseif event.value == "show_search" or event.value == "back_search" then
        cancel_pending_add()
        render_search_menu(true)
    elseif event.value == "show_filters" then
        clear_search()
        menu_view = "filters"
        send_menu("update-menu", filters_menu())
    elseif event.value == "clear_filters" then
        clear_filters(false) -- Stay in filters menu
    elseif event.value == "seeds_filter" then
        toggle_field("seeds")
    elseif event.value == "dub_filter" then
        toggle_field("dub")
    elseif try_toggle_prefixed_filter(event.value) then
        -- handled inside try_toggle_prefixed_filter
    elseif type(event.value) == "string" and event.value:match("^size_filter:") then
        toggle_size_filter(event.value:sub(#"size_filter:" + 1))
    elseif is_magnet(event.value) then
        add_magnet(event.value, last_search and last_search.urls and last_search.urls[event.value], "back_search")
    elseif event.value == "back" then
        cancel_pending_add()
        return_to_root()
    else
        local hash = history_hash(event.value)
        if hash then
            open_history_entry(hash)
        end
    end
end)

mp.add_key_binding(nil, "torrserver", function()
    show_root_menu("open-menu")
end)

mp.register_event("shutdown", stop_torrserver)

-- playlist_autoplay=no: mpv would still advance on its own, so remember an
-- eof that still has a later entry and pause the file that replaces it.
local pause_next_queued_file = false

mp.register_event("end-file", function(event)
    if opts.playlist_autoplay or event.reason ~= "eof" or not playing.hash then return end
    local count = mp.get_property_number("playlist-count") or 0
    local position = mp.get_property_number("playlist-pos") or -1
    if position >= 0 and position + 1 < count then
        pause_next_queued_file = true
    end
end)

mp.register_event("file-loaded", function()
    if not pause_next_queued_file then return end
    pause_next_queued_file = false
    mp.set_property_bool("pause", true)
    mp.osd_message("TorrServer: next episode paused", 2)
end)

-- Runs once per mpv start/script reload; TTL-cached (see opts.update_check_interval)
-- so this only hits the binary/release API once a day, never on menu open.
mp.add_timeout(0.05, check_for_update)
