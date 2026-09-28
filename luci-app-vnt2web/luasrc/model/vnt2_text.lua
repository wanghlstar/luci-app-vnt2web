local fs = require "nixio.fs"
local sys = require "luci.sys"
local util = require "luci.util"

local M = {}

-- Mojibake signatures: a UTF-8 byte triple that was decoded as GBK/GB18030
-- surfaces as one character plus the "?" replacement character. Each entry is
-- built from its three hex bytes because several of the decoded characters
-- differ only in a single byte and are indistinguishable on screen.
local function mojibake_marker(hex)
	local bytes = {}
	for byte in hex:gmatch("%x%x") do
		bytes[#bytes + 1] = string.char(tonumber(byte, 16))
	end
	return table.concat(bytes) .. "?"
end

local mojibake_markers = {
	mojibake_marker("E9 96 BA"), -- 闁?
	mojibake_marker("E9 97 81"), -- 闁?
	mojibake_marker("E6 BF A0"), -- 濠?
	mojibake_marker("E6 BF 9E"), -- 濞?
	mojibake_marker("E6 BF A1"), -- 濡?
	mojibake_marker("E9 97 82"), -- 闂?
	mojibake_marker("E9 96 BB"), -- 閻?
	mojibake_marker("E7 BC 82"), -- 缂?
	mojibake_marker("E9 96 B8"), -- 閸?
	mojibake_marker("E7 80 B9"), -- 瀹?
	mojibake_marker("E5 A9 B5"), -- 婵?
	mojibake_marker("E9 90 A0"), -- 鐠?
	mojibake_marker("E7 BC 81") -- 缁?
}

local function iconv_available()
	return sys.call("command -v iconv >/dev/null 2>&1") == 0
end

-- Large logs must not be passed on the command line, so repairs always stream
-- through a temporary file instead of a shell argument.
local function temp_path(suffix)
	local stat = fs.readfile("/proc/self/stat") or ""
	local pid = stat:match("^(%d+)") or tostring(os.time())
	return string.format("/tmp/vnt2-text.%s.%s.%s", pid, tostring(os.time()), suffix)
end

-- Round-trip the file through UTF-8 -> GB18030 -> UTF-8, which restores log
-- lines whose UTF-8 bytes were mistakenly decoded as GB18030.
local function run_iconv_chain(path)
	if not iconv_available() then
		return nil
	end

	local repaired_path = temp_path("repaired")
	if not repaired_path then
		return nil
	end

	local command = string.format(
		"iconv -f UTF-8 -t GB18030 <%s 2>/dev/null | iconv -f GB18030 -t UTF-8 >%s 2>/dev/null",
		util.shellquote(path), util.shellquote(repaired_path)
	)
	if sys.call(command) ~= 0 then
		fs.remove(repaired_path)
		return nil
	end

	local repaired = fs.readfile(repaired_path) or ""
	fs.remove(repaired_path)
	if repaired == "" then
		return nil
	end
	return repaired
end

local function count_mojibake_markers(content)
	content = tostring(content or "")
	local count = 0

	for _, marker in ipairs(mojibake_markers) do
		local pos = 1
		while true do
			local found = content:find(marker, pos, true)
			if not found then
				break
			end
			count = count + 1
			pos = found + #marker
		end
	end

	return count
end

local log_message_exact_map = {
	["start failed: missing executable vnt2_web"] = "启动失败：缺少可执行文件 vnt2_web",
	["start failed: client TOML validation failed"] = "启动失败：客户端 TOML 配置校验失败",
	["start failed: client network runtime preparation failed"] = "启动失败：客户端网络运行环境准备失败",
	["service start flow begin"] = "服务启动流程开始",
	["UCI to TOML export completed"] = "UCI 到 TOML 导出完成",
	["UCI to TOML export failed, continue with existing config"] = "UCI 到 TOML 导出失败，继续使用现有配置",
	["vnt2_web config section not found"] = "未找到 vnt2_web 配置节",
	["start_service finished"] = "服务启动流程结束",
	["service stop flow begin"] = "服务停止流程开始",
	["service stopped"] = "服务已停止",
	["bundle missing vnt2_web"] = "压缩包中缺少 vnt2_web",
	["install web bundle to /usr/bin failed"] = "安装 Web 程序包到 /usr/bin 失败"
}

local log_message_pattern_rules = {
	{ "^starting (.+) with config (.+)$", "正在启动 %1，配置文件：%2" },
	{ "^using (.+) on (.+), conf=(.+)$", "使用 %1 监听 %2，配置文件：%3" },
	{ "^checking (.+) releases list: (.+)$", "正在检查 %1 的 Releases 列表：%2" },
	{ "^checking release endpoint: (.+)$", "正在检查发布接口：%1" },
	{ "^checking releases list: (.+)$", "正在检查 Releases 列表：%1" },
	{ "^failed to create install directory (.+)$", "创建安装目录失败：%1" },
	{ "^failed to copy uploaded binary to (.+) from (.+)$", "复制已上传程序失败：目标=%1 来源=%2" },
	{ "^failed to chmod uploaded binary (.+)$", "设置已上传程序执行权限失败：%1" },
	{ "^uploaded binary not found after install (.+)$", "安装后未找到已上传程序：%1" },
	{ "^mirror (.+) not supported for repo (.+), fallback to (.+)$", "镜像 %1 不支持仓库 %2，已回退到 %3" },
	{ "^mirror strategy (.+) not supported for repo (.+), fallback to github$", "镜像策略 %1 不支持仓库 %2，已回退到 GitHub" },
	{ "^cached bundle found for (.+), reuse (.+)$", "发现 %1 的缓存程序包，复用目录：%2" },
	{ "^query target release repo=(.+) tag=(.+) arch=(.+) scope=(.+)$", "准备查询发行版：repo=%1 tag=%2 arch=%3 scope=%4" },
	{ "^querying (.+) release repo=(.+) tag=(.+) mirror=(.+) strategy=(.+) arch=(.+)$", "正在查询 %1 发行版：repo=%2 tag=%3 mirror=%4 strategy=%5 arch=%6" },
	{ "^querying (.+) release repo=(.+) tag=(.+) mirror=(.+) arch=(.+)$", "正在查询 %1 发行版：repo=%2 tag=%3 mirror=%4 arch=%5" },
	{ "^release query failed repo=(.+) tag=(.+) mirror=(.+)$", "发行版查询失败：repo=%1 tag=%2 mirror=%3" },
	{ "^release query ok: (.+)$", "发行版查询成功：%1" },
	{ "^no release asset matched arch=(.+) scope=(.+) mirror=(.+)$", "未找到匹配的发行资源：arch=%1 scope=%2 mirror=%3" },
	{ "^no release asset matched arch=(.+) scope=(.+)$", "未找到匹配的发行资源：arch=%1 scope=%2" },
	{ "^selected asset (.+) mirror=(.+)$", "已选择发行资源：%1 mirror=%2" },
	{ "^selected asset (.+)$", "已选择发行资源：%1" },
	{ "^reusing downloaded asset (.+)$", "复用已下载资源：%1" },
	{ "^cached asset invalid, remove and redownload (.+)$", "缓存资源无效，已删除并重新下载：%1" },
	{ "^asset download failed tool=(.+) mirror=(.+) url=(.+)$", "资源下载失败：工具=%1 mirror=%2 地址=%3" },
	{ "^asset download failed tool=(.+) url=(.+)$", "资源下载失败：工具=%1 地址=%2" },
	{ "^downloaded asset invalid or corrupted (.+)$", "已下载资源无效或已损坏：%1" },
	{ "^extract failed, remove cache and retry (.+)$", "解压失败，已删除缓存并重试：%1" },
	{ "^retry asset download failed tool=(.+) mirror=(.+) url=(.+)$", "重试下载资源失败：工具=%1 mirror=%2 地址=%3" },
	{ "^retry asset download failed tool=(.+) url=(.+)$", "重试下载资源失败：工具=%1 地址=%2" },
	{ "^retried asset still invalid (.+)$", "重试后资源仍然无效：%1" },
	{ "^extract asset failed (.+)$", "解压资源失败：%1" },
	{ "^bundle missing vnt2_web mirror=(.+)$", "压缩包中缺少 vnt2_web：mirror=%1" },
	{ "^web installed: web=(.+) mirror=(.+)$", "Web 安装完成：web=%1 mirror=%2" },
	{ "^web installed: web=(.+)$", "Web 安装完成：web=%1" },
	{ "^all download mirrors failed repo=(.+) tag=(.+) strategy=(.+) arch=(.+) scope=(.+)$", "所有下载镜像均失败：repo=%1 tag=%2 strategy=%3 arch=%4 scope=%5" },
	{ "^(.+) auto download failed, fallback to uploaded binary (.+)$", "%1 自动下载失败，已回退到已上传程序：%2" }
}

function M.sanitize_text(content)
	content = tostring(content or "")
	content = content:gsub("\27%[[%d;?]*[%a]", "")
	content = content:gsub("\27%][^\7]*\7", "")
	-- Drop NUL, CR and the remaining C0 control characters, including a stray
	-- escape and DEL, while keeping \n and \t for readable log output.
	content = content:gsub("[%c]", function(char)
		if char == "\n" or char == "\t" then
			return char
		end
		return ""
	end)
	return content
end

function M.translate_log_message(message)
	message = tostring(message or "")
	if message == "" then
		return message
	end

	if log_message_exact_map[message] then
		return log_message_exact_map[message]
	end

	for _, rule in ipairs(log_message_pattern_rules) do
		local translated, count = message:gsub(rule[1], rule[2])
		if count > 0 then
			return translated
		end
	end

	return message
end

function M.translate_log_text(content)
	content = tostring(content or "")
	if content == "" then
		return content
	end

	local has_trailing_newline = content:sub(-1) == "\n"
	local lines = {}

	for line in (content .. "\n"):gmatch("(.-)\n") do
		local prefix, message = line:match("^(.- : )(.*)$")
		if prefix then
			lines[#lines + 1] = prefix .. M.translate_log_message(message)
		else
			lines[#lines + 1] = M.translate_log_message(line)
		end
	end

	local translated = table.concat(lines, "\n")
	if not has_trailing_newline and translated:sub(-1) == "\n" then
		translated = translated:sub(1, -2)
	end
	return translated
end

function M.looks_like_mojibake(content)
	content = tostring(content or "")
	if content == "" then
		return false
	end

	for _, marker in ipairs(mojibake_markers) do
		if content:find(marker, 1, true) then
			return true
		end
	end

	return false
end

-- Keep the repaired text only when it removes mojibake markers, otherwise the
-- original content is returned untouched. A conversion that stops on invalid
-- input can leave a truncated prefix behind, which is rejected as well.
local function accept_repair(original, repaired)
	if not repaired or repaired == "" then
		return original
	end
	if count_mojibake_markers(repaired) >= count_mojibake_markers(original) then
		return original
	end
	if #repaired < #original and original:sub(1, #repaired) == repaired then
		return original
	end
	return repaired
end

function M.repair_mojibake_text(content)
	content = tostring(content or "")
	if content == "" or not M.looks_like_mojibake(content) then
		return content
	end

	local source_path = temp_path("source")
	if not source_path then
		return content
	end
	if not fs.writefile(source_path, content) then
		fs.remove(source_path)
		return content
	end

	local repaired = run_iconv_chain(source_path)
	fs.remove(source_path)
	return accept_repair(content, repaired)
end

function M.read_text_file(path)
	local content = path and path ~= "" and fs.access(path) and (fs.readfile(path) or "") or ""
	if content ~= "" and path and path ~= "" and M.looks_like_mojibake(content) then
		content = accept_repair(content, run_iconv_chain(path))
	end

	return M.sanitize_text(content)
end

function M.normalize_text(content)
	return M.sanitize_text(M.repair_mojibake_text(content))
end

function M.normalize_log_text(content)
	return M.translate_log_text(M.normalize_text(content))
end

local function keep_last_lines(content, max_lines)
	content = tostring(content or "")
	max_lines = tonumber(max_lines or 0) or 0
	if max_lines <= 0 or content == "" then
		return content
	end

	local has_trailing_newline = content:sub(-1) == "\n"
	local lines = {}
	for line in (content .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end

	if has_trailing_newline and lines[#lines] == "" then
		table.remove(lines, #lines)
	end

	if #lines <= max_lines then
		return table.concat(lines, "\n") .. (has_trailing_newline and #lines > 0 and "\n" or "")
	end

	local start_idx = #lines - max_lines + 1
	local out = {}
	for i = start_idx, #lines do
		out[#out + 1] = lines[i]
	end

	return table.concat(out, "\n") .. (has_trailing_newline and #out > 0 and "\n" or "")
end

function M.read_log_file(path, max_lines)
	local limit = tonumber(max_lines or 0) or 0
	if limit <= 0 then
		return M.normalize_log_text(M.read_text_file(path))
	end

	local content = ""
	if path and path ~= "" and fs.access(path) then
		local ok, tailed = pcall(sys.exec, string.format("tail -n %d %s 2>/dev/null", limit, util.shellquote(path)))
		if ok and tailed then
			content = tailed
		end
		if content == "" then
			content = keep_last_lines(M.read_text_file(path), limit)
			return M.normalize_log_text(content)
		end
	end

	return M.normalize_log_text(content)
end

return M
