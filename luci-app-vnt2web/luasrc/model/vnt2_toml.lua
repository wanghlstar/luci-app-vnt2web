local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"
local nixio = require "nixio"

local M = {}

M.TOML_FILE = "/etc/config/vnt2.toml"

local LEGACY_DEFAULT_CLIENT_SERVER = "tcp://0.0.0.0:29872"
local DEFAULT_CLIENT_SERVER = "tcp://1.1.1.1:29872"

local client_defaults = {
	network_code = "123456",
	server = { "tcp://1.1.1.1:29872" },
	ip = "",
	device_id = "",
	device_name = "",
	password = "",
	tun_name = "vnt-tun",
	cert_mode = "skip",
	mtu = "1400",
	tunnel_port = "",
	device_mode = "tun",
	no_punch = "0",
	no_broadcast = "0",
	allow_ikev2 = "0",
	allow_wireguard = "0",
	rtx = "0",
	compress = "0",
	fec = "0",
	no_nat = "0",
	allow_mapping = "0",
	auto_sync_subnet = "0",
	outbound_interface = "",
	event_script = "",
	input = {},
	output = {},
	port_mapping = {},
	peer_address = {},
	turn = {},
	punch_model = {},
	subnet_mapping = {},
	tunnel_addr = {},
	udp_stun = {},
	tcp_stun = {}
}

local web_option_map = {
	network_code = "network_code",
	server = "server",
	peer_address = "peer_address",
	turn = "turn",
	punch_model = "punch_model",
	ip = "ip",
	device_id = "device_id",
	device_name = "device_name",
	password = "password",
	tun_name = "tun_name",
	cert_mode = "cert_mode",
	mtu = "mtu",
	tunnel_port = "tunnel_port",
	device_mode = "device_mode",
	no_punch = "no_punch",
	no_broadcast = "no_broadcast",
	allow_ikev2 = "allow_ikev2",
	allow_wireguard = "allow_wireguard",
	rtx = "rtx",
	compress = "compress",
	fec = "fec",
	no_nat = "no_nat",
	allow_mapping = "allow_mapping",
	subnet_mapping = "subnet_mapping",
	auto_sync_subnet = "auto_sync_subnet",
	outbound_interface = "outbound_interface",
	tunnel_addr = "tunnel_addr",
	event_script = "event_script",
	input = "input",
	output = "output",
	port_mapping = "port_mapping",
	udp_stun = "udp_stun",
	tcp_stun = "tcp_stun"
}

local web_order = {
	"network_code", "server", "peer_address", "turn", "punch_model", "ip", "device_id", "device_name", "password", "tun_name",
	"cert_mode", "mtu", "tunnel_port", "device_mode", "no_punch", "no_broadcast", "allow_ikev2", "allow_wireguard", "rtx", "compress",
	"fec", "no_nat", "allow_mapping", "subnet_mapping", "auto_sync_subnet", "outbound_interface", "tunnel_addr", "event_script",
	"input", "output", "port_mapping", "udp_stun", "tcp_stun"
}

local list_keys = {
	server = true,
	peer_address = true,
	turn = true,
	punch_model = true,
	input = true,
	output = true,
	port_mapping = true,
	udp_stun = true,
	tcp_stun = true,
	subnet_mapping = true,
	tunnel_addr = true
}

local bool_keys = {
	no_punch = true,
	no_broadcast = true,
	allow_ikev2 = true,
	allow_wireguard = true,
	rtx = true,
	compress = true,
	fec = true,
	no_nat = true,
	allow_mapping = true,
	auto_sync_subnet = true
}

local number_keys = {
	mtu = true,
	tunnel_port = true
}

local required_string_keys = {
	network_code = true,
	tun_name = true,
	cert_mode = true
}

local legacy_key_aliases = {
	cmd_port = "ctrl_port",
	port = "tunnel_port",
	use_channel_type = "rtx",
	compressor = "compress",
	use_fec = "fec",
	no_proxy = "no_nat",
	allow_wire_guard = "allow_wireguard",
	in_ips = "input",
	out_ips = "output",
	mapping = "port_mapping",
	stun_server = "udp_stun",
	stun_server_tcp = "tcp_stun"
}

local function trim(v)
	return util.trim(tostring(v or ""))
end

local function is_list_key(key)
	return list_keys[key] == true
end

local function is_bool_key(key)
	return bool_keys[key] == true
end

local function is_number_key(key)
	return number_keys[key] == true
end

local function normalize_list(value)
	local out = {}

	if type(value) == "string" then
		value = { value }
	end

	if type(value) ~= "table" then
		return out
	end

	for _, item in ipairs(value) do
		item = trim(item)
		if item ~= "" then
			out[#out + 1] = item
		end
	end

	return out
end

local function normalize_client_server_list(value)
	local out = normalize_list(value)

	if #out == 1 then
		local first = out[1]
		if first == LEGACY_DEFAULT_CLIENT_SERVER then
			return { DEFAULT_CLIENT_SERVER }
		end
	end

	return out
end

-- Control characters other than \n \r \t that must be escaped as \uXXXX
-- inside a TOML basic string. Built via string.char to avoid Lua pattern
-- escaping pitfalls.
local TOML_CONTROL_CHARS = "[" .. string.char(
	1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20,
	21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
) .. "]"

local function toml_escape(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "\\r")
	s = s:gsub("\t", "\\t")
	s = s:gsub(TOML_CONTROL_CHARS, function(c)
		return string.format("\\u%04X", string.byte(c))
	end)
	return s
end

local function toml_unescape(s)
	s = tostring(s or "")
	local out = {}
	local i = 1
	local len = #s

	while i <= len do
		local c = s:sub(i, i)
		if c == "\\" and i < len then
			local n = s:sub(i + 1, i + 1)
			if n == "n" then
				out[#out + 1] = "\n"
				i = i + 2
			elseif n == "r" then
				out[#out + 1] = "\r"
				i = i + 2
			elseif n == "t" then
				out[#out + 1] = "\t"
				i = i + 2
			elseif n == "u" then
				local hex = s:sub(i + 2, i + 5)
				if hex:match("^%x%x%x%x$") then
					local code = tonumber(hex, 16)
					out[#out + 1] = code < 128 and string.char(code) or "?"
					i = i + 6
				else
					out[#out + 1] = c
					i = i + 1
				end
			elseif n == '"' then
				out[#out + 1] = '"'
				i = i + 2
			elseif n == "\\" then
				out[#out + 1] = "\\"
				i = i + 2
			else
				out[#out + 1] = c
				i = i + 1
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end

	return table.concat(out)
end

local function parse_array(inner)
	local out = {}
	local pos = 1
	inner = trim(inner)
	if inner == "" then
		return out
	end

	while pos <= #inner do
		while pos <= #inner and inner:sub(pos, pos):match("[%s,]") do
			pos = pos + 1
		end
		if pos > #inner then
			break
		end

		if inner:sub(pos, pos) ~= '"' then
			return out
		end

		local start = pos + 1
		local i = start
		local escaped = false
		while i <= #inner do
			local char = inner:sub(i, i)
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				break
			end
			i = i + 1
		end
		if i > #inner then
			return out
		end

		out[#out + 1] = toml_unescape(inner:sub(start, i - 1))
		pos = i + 1
	end

	return out
end

local function get_client_uci_value(uci, section, option)
	if not section then
		return nil
	end

	local value = uci:get("vnt2", section, option)
	if value ~= nil then
		return value
	end

	if option == "tunnel_port" then
		return uci:get("vnt2", section, "port")
	end

	if option == "device_mode" then
		local legacy = uci:get("vnt2", section, "no_tun")
		if legacy ~= nil then
			return (trim(legacy) == "1" or trim(legacy) == "true") and "no" or "tun"
		end
	end

	return nil
end

local function strip_toml_comment(line)
	local quoted = false
	local escaped = false
	for i = 1, #line do
		local char = line:sub(i, i)
		if quoted then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				quoted = false
			end
		elseif char == '"' then
			quoted = true
		elseif char == "#" then
			return line:sub(1, i - 1)
		end
	end
	return line
end

local function encode_value(key, value)
	if is_list_key(key) then
		local vals = normalize_list(value)
		local parts = {}
		for _, item in ipairs(vals) do
			parts[#parts + 1] = '"' .. toml_escape(item) .. '"'
		end
		return "[" .. table.concat(parts, ", ") .. "]"
	end

	value = trim(value)

	if is_bool_key(key) then
		if value == "1" or value == "true" then
			return "true"
		end
		return "false"
	end

	if is_number_key(key) then
		local number = tonumber(trim(value))
		if not number then
			return nil
		end
		return tostring(number)
	end

	return '"' .. toml_escape(value) .. '"'
end

local function parse_value(key, raw)
	raw = trim(raw)

	if is_list_key(key) then
		local inner = raw:match("^%[(.*)%]$")
		if inner then
			return parse_array(inner)
		end
		-- Legacy configurations store scalars for keys that are lists now,
		-- for example stun_server = "stun.xx:3478". Keep the value as a
		-- single element list instead of silently dropping it.
		local quoted = raw:match('^"(.*)"$')
		return normalize_list(quoted or raw)
	end

	if is_bool_key(key) then
		return (raw == "true") and "1" or "0"
	end

	if is_number_key(key) then
		return trim(raw)
	end

	local quoted = raw:match('^"(.*)"$')
	if quoted ~= nil then
		return toml_unescape(quoted)
	end

	return raw
end

local function clone_defaults(src)
	local out = {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			out[k] = clone_defaults(v)
		else
			out[k] = v
		end
	end
	return out
end

function M.read_toml(path, defaults)
	local data = clone_defaults(defaults or {})
	local canonical_seen = {}

	if not fs.access(path) then
		return data
	end

	local content = fs.readfile(path) or ""
	local in_section = false
	for line in content:gmatch("[^\r\n]+") do
		local clean = trim(strip_toml_comment(line))
		if clean ~= "" then
			-- write_toml() emits a flat key = value document, so [section]
			-- headers are not part of the schema. A section line and every key
			-- below it belong to that table, so they are skipped instead of
			-- overwriting the top level values.
			local section = clean:match("^%[([%w_]+)%]$")
			if section then
				in_section = true
				io.stderr:write("vnt2_toml: ignoring TOML section [" .. section .. "]\n")
			elseif not in_section then
				local key, raw = clean:match("^([%w_.%-]+)%s*=%s*(.-)%s*$")
				if not key then
					key, raw = clean:match('^"(.-)"%s*=%s*(.-)%s*$')
				end
				if key then
					if key == "no_tun" then
						local old_value = trim(raw)
						data.no_tun = (old_value == "true" or old_value == "1") and "1" or "0"
						canonical_seen.no_tun = true
					else
						local target_key = legacy_key_aliases[key] or key
						local is_legacy = target_key ~= key
						if not (is_legacy and canonical_seen[target_key]) then
							data[target_key] = parse_value(target_key, raw)
							if not is_legacy then
								canonical_seen[target_key] = true
							end
						end
					end
				end
			end
		end
	end
	if not canonical_seen.device_mode and canonical_seen.no_tun then
		data.device_mode = data.no_tun == "1" and "no" or "tun"
	end

	return data
end

local function ensure_toml_parent(path)
	local dir = path:match("^(.+)/[^/]+$")
	if dir and dir ~= "" then
		-- Only tighten permissions on a directory this call created, so a
		-- directory an administrator already hardened is left untouched.
		if not fs.access(dir) then
			if not fs.mkdirr(dir) then
				return nil, "failed to create TOML parent directory"
			end
			if not fs.chmod(dir, "0755") then
				return nil, "failed to secure TOML parent directory"
			end
		end
	end
	return true
end

local function secure_existing_toml(path)
	local parent_ok, parent_err = ensure_toml_parent(path)
	if not parent_ok then
		return nil, parent_err
	end
	if not fs.chmod(path, "0600") then
		return nil, "failed to secure existing TOML file"
	end
	return true
end

function M.write_toml(path, data, order)
	local parent_ok, parent_err = ensure_toml_parent(path)
	if not parent_ok then
		return nil, parent_err
	end

	local lines = {}
	for _, key in ipairs(order) do
		local value = data[key]
		if value ~= nil then
			local keep = true

			if not is_list_key(key) and not is_bool_key(key) and not is_number_key(key) then
				value = trim(value)
				if value == "" and not required_string_keys[key] then
					keep = false
				end
			end
			if key == "tunnel_port" and (trim(value) == "" or trim(value) == "0") then
				keep = false
			end

			if keep then
				local encoded = encode_value(key, value)
				if encoded ~= nil then
					lines[#lines + 1] = string.format("%s = %s", key, encoded)
				end
			end
		end
	end

	lines[#lines + 1] = ""
	local temp = string.format("%s.tmp.%s", path, tostring(nixio.getpid()))
	local content = table.concat(lines, "\n")
	if not fs.writefile(temp, content) then
		fs.remove(temp)
		return nil, "failed to write temporary TOML file"
	end
	if not fs.chmod(temp, "0600") then
		fs.remove(temp)
		return nil, "failed to secure temporary TOML file"
	end
	-- Flush the temporary file to disk before it replaces the live config.
	sys.call("sync")
	if not os.rename(temp, path) then
		fs.remove(temp)
		return nil, "failed to replace TOML file"
	end
	return true
end

local function build_web_toml_data(uci)
	local data = clone_defaults(client_defaults)
	local section = uci:get_first("vnt2", "vnt2_web")

	for toml_key, uci_key in pairs(web_option_map) do
		if is_list_key(toml_key) then
			local val = section and uci:get_list("vnt2", section, uci_key) or data[toml_key]
			if toml_key == "server" then
				data[toml_key] = normalize_client_server_list(val)
			else
				data[toml_key] = normalize_list(val)
			end
		else
			local val = get_client_uci_value(uci, section, uci_key)
			if val ~= nil then
				data[toml_key] = trim(val)
			end
		end
	end
	if #normalize_list(data.tunnel_addr) > 0 then
		data.tunnel_port = nil
	end

	return data
end

-- Every LuCI request loads this module, so the permission repair for an
-- existing TOML file is rate limited to one check per interval.
local TOML_CHECK_INTERVAL = 60
local TOML_CHECK_STAMP = "/tmp/vnt2-toml.lastcheck"

local function toml_check_throttled()
	local last = tonumber(trim(fs.readfile(TOML_CHECK_STAMP) or "")) or 0
	local now = tonumber(os.time()) or 0
	if last > 0 and now - last < TOML_CHECK_INTERVAL then
		return true
	end

	local temp = string.format("%s.%s", TOML_CHECK_STAMP, tostring(nixio.getpid()))
	if fs.writefile(temp, tostring(now) .. "\n") and os.rename(temp, TOML_CHECK_STAMP) then
		return false
	end
	fs.remove(temp)
	return false
end

function M.ensure_toml_file(uci)
	if fs.access(M.TOML_FILE) then
		if toml_check_throttled() then
			return true
		end
		return secure_existing_toml(M.TOML_FILE)
	end

	return M.write_toml(M.TOML_FILE, build_web_toml_data(uci), web_order)
end

function M.export_uci_to_toml(uci)
	local web = build_web_toml_data(uci)

	local ok, err = M.write_toml(M.TOML_FILE, web, web_order)
	if not ok then
		return nil, err
	end

	return web
end

return M
