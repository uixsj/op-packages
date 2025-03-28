require "luci.sys"
local api = require "luci.passwall.api"
local appname = "passwall"

local var = api.get_args(arg)
local FLAG = var["-FLAG"]
local DNSMASQ_CONF_DIR = var["-DNSMASQ_CONF_DIR"]
local TMP_DNSMASQ_PATH = var["-TMP_DNSMASQ_PATH"]
local DNSMASQ_CONF_FILE = var["-DNSMASQ_CONF_FILE"]
local DEFAULT_DNS = var["-DEFAULT_DNS"]
local LOCAL_DNS = var["-LOCAL_DNS"]
local TUN_DNS = var["-TUN_DNS"]
local REMOTE_FAKEDNS = var["-REMOTE_FAKEDNS"]
local USE_DEFAULT_DNS = var["-USE_DEFAULT_DNS"]
local CHINADNS_DNS = var["-CHINADNS_DNS"]
local TCP_NODE = var["-TCP_NODE"]
local USE_DIRECT_LIST = var["-USE_DIRECT_LIST"]
local USE_PROXY_LIST = var["-USE_PROXY_LIST"]
local USE_BLOCK_LIST = var["-USE_BLOCK_LIST"]
local USE_GFW_LIST = var["-USE_GFW_LIST"]
local CHN_LIST = var["-CHN_LIST"]
local DEFAULT_PROXY_MODE = var["-DEFAULT_PROXY_MODE"]
local NO_PROXY_IPV6 = var["-NO_PROXY_IPV6"]
local NO_LOGIC_LOG = var["-NO_LOGIC_LOG"]
local NFTFLAG = var["-NFTFLAG"]
local CACHE_PATH = api.CACHE_PATH
local CACHE_FLAG = "dnsmasq_" .. FLAG
local CACHE_DNS_PATH = CACHE_PATH .. "/" .. CACHE_FLAG
local CACHE_TEXT_FILE = CACHE_DNS_PATH .. ".txt"

local uci = api.uci
local sys = api.sys
local fs = api.fs
local datatypes = api.datatypes

local list1 = {}
local excluded_domain = {}
local excluded_domain_str = "!"

local function log(...)
	if NO_LOGIC_LOG == "1" then
		return
	end
	api.log(...)
end

local function check_dns(domain, dns)
	if domain == "" or domain:find("#") then
		return false
	end
	if not dns then
		return
	end
	for k,v in ipairs(list1[domain].dns) do
		if dns == v then
			return true
		end
	end
	return false
end

local function check_ipset(domain, ipset)
	if domain == "" or domain:find("#") then
		return false
	end
	if not ipset then
		return
	end
	for k,v in ipairs(list1[domain].ipsets) do
		if ipset == v then
			return true
		end
	end
	return false
end

local function set_domain_address(domain, address)
	if domain == "" or domain:find("#") then
		return
	end
	if not list1[domain] then
		list1[domain] = {
			dns = {},
			ipsets = {}
		}
	end
	if not list1[domain].address then
		list1[domain].address = address
	end
end

local function set_domain_dns(domain, dns)
	if domain == "" or domain:find("#") then
		return
	end
	if not dns then
		return
	end
	if not list1[domain] then
		list1[domain] = {
			dns = {},
			ipsets = {}
		}
	end
	for line in string.gmatch(dns, '[^' .. "," .. ']+') do
		if not check_dns(domain, line) then
			table.insert(list1[domain].dns, line)
		end
	end
end

local function set_domain_ipset(domain, ipset)
	if domain == "" or domain:find("#") then
		return
	end
	if not ipset then
		return
	end
	if not list1[domain] then
		list1[domain] = {
			dns = {},
			ipsets = {}
		}
	end
	for line in string.gmatch(ipset, '[^' .. "," .. ']+') do
		if not check_ipset(domain, line) then
			table.insert(list1[domain].ipsets, line)
		end
	end
end

local function add_excluded_domain(domain)
	if domain == "" or domain:find("#") then
		return
	end
	table.insert(excluded_domain, domain)
	excluded_domain_str = excluded_domain_str .. "|" .. domain
end

local function check_excluded_domain(domain)
	if domain == "" or domain:find("#") then
		return false
	end
	for k,v in ipairs(excluded_domain) do
		if domain:find(v) then
			return true
		end
	end
	return false
end

local cache_text = ""
local nodes_address_md5 = luci.sys.exec("echo -n $(uci show passwall | grep '\\.address') | md5sum")
local new_rules = luci.sys.exec("echo -n $(find /usr/share/passwall/rules -type f | xargs md5sum)")
local new_text = TMP_DNSMASQ_PATH .. DNSMASQ_CONF_FILE .. DEFAULT_DNS .. LOCAL_DNS .. TUN_DNS .. REMOTE_FAKEDNS .. USE_DEFAULT_DNS .. CHINADNS_DNS .. USE_DIRECT_LIST .. USE_PROXY_LIST .. USE_BLOCK_LIST .. USE_GFW_LIST .. CHN_LIST .. DEFAULT_PROXY_MODE .. NO_PROXY_IPV6 .. nodes_address_md5 .. new_rules .. NFTFLAG
if fs.access(CACHE_TEXT_FILE) then
	for line in io.lines(CACHE_TEXT_FILE) do
		cache_text = line
	end
end

if cache_text ~= new_text then
	api.remove(CACHE_DNS_PATH .. "*")
end

local dnsmasq_default_dns
if USE_DEFAULT_DNS ~= "nil" then
	if USE_DEFAULT_DNS == "direct" then
		dnsmasq_default_dns = LOCAL_DNS
	end
	if USE_DEFAULT_DNS == "remote" then
		dnsmasq_default_dns = TUN_DNS
	end
	if USE_DEFAULT_DNS == "remote" and CHN_LIST == "direct" then
		dnsmasq_default_dns = TUN_DNS
	end
end

local only_global
if DEFAULT_PROXY_MODE == "proxy" and CHN_LIST == "0" and USE_GFW_LIST == "0" then
	--没有启用中国列表和GFW列表时
	dnsmasq_default_dns = TUN_DNS
	only_global = 1
end
if USE_DEFAULT_DNS == "chinadns_ng" and CHINADNS_DNS ~= "0" then
	dnsmasq_default_dns = CHINADNS_DNS
end

local setflag_4= (NFTFLAG == "1") and "4#inet#passwall#" or ""
local setflag_6= (NFTFLAG == "1") and "6#inet#passwall#" or ""

if not fs.access(CACHE_DNS_PATH) then
	fs.mkdir(DNSMASQ_CONF_DIR)
	fs.mkdir(CACHE_DNS_PATH)

	--屏蔽列表
	if USE_DEFAULT_DNS ~= "chinadns_ng" or CHINADNS_DNS == "0" then
		if USE_BLOCK_LIST == "1" then
			for line in io.lines("/usr/share/passwall/rules/block_host") do
				line = api.get_std_domain(line)
				if line ~= "" and not line:find("#") then
					set_domain_address(line, "")
				end
			end
		end
	end

	local fwd_dns
	local ipset_flag
	local no_ipv6

	--始终用国内DNS解析节点域名
	if true then
		fwd_dns = LOCAL_DNS
		if USE_DEFAULT_DNS == "chinadns_ng" and CHINADNS_DNS ~= "0" then
			fwd_dns = nil
		else
			uci:foreach(appname, "nodes", function(t)
				local address = t.address
				if address == "engage.cloudflareclient.com" then return end
				if datatypes.hostname(address) then
					set_domain_dns(address, fwd_dns)
					set_domain_ipset(address, setflag_4 .. "passwall_vpslist," .. setflag_6 .. "passwall_vpslist6")
				end
			end)
			log(string.format("  - 节点列表中的域名(vpslist)：%s", fwd_dns or "默认"))
		end
	end

	--直连（白名单）列表
	if USE_DIRECT_LIST == "1" then
		if fs.access("/usr/share/passwall/rules/direct_host") then
			fwd_dns = LOCAL_DNS
			if USE_DEFAULT_DNS == "chinadns_ng" and CHINADNS_DNS ~= "0" then
				fwd_dns = nil
			end
			if fwd_dns then
				--始终用国内DNS解析直连（白名单）列表
				for line in io.lines("/usr/share/passwall/rules/direct_host") do
					line = api.get_std_domain(line)
					if line ~= "" and not line:find("#") then
						add_excluded_domain(line)
						set_domain_dns(line, fwd_dns)
						set_domain_ipset(line, setflag_4 .. "passwall_whitelist," .. setflag_6 .. "passwall_whitelist6")
					end
				end
				log(string.format("  - 域名白名单(whitelist)：%s", fwd_dns or "默认"))
			end
		end
	end

	--代理（黑名单）列表
	if USE_PROXY_LIST == "1" then
		if fs.access("/usr/share/passwall/rules/proxy_host") then
			fwd_dns = TUN_DNS
			if USE_DEFAULT_DNS == "chinadns_ng" and CHINADNS_DNS ~= "0" then
				fwd_dns = nil
			end
			if fwd_dns then
				--始终使用远程DNS解析代理（黑名单）列表
				for line in io.lines("/usr/share/passwall/rules/proxy_host") do
					line = api.get_std_domain(line)
					if line ~= "" and not line:find("#") then
						add_excluded_domain(line)
						local ipset_flag = setflag_4 .. "passwall_blacklist," .. setflag_6 .. "passwall_blacklist6"
						if NO_PROXY_IPV6 == "1" then
							set_domain_address(line, "::")
							ipset_flag = setflag_4 .. "passwall_blacklist"
						end
						if REMOTE_FAKEDNS == "1" then
							ipset_flag = nil
						end
						set_domain_dns(line, fwd_dns)
						set_domain_ipset(line, ipset_flag)
					end
				end
				log(string.format("  - 代理域名表(blacklist)：%s", fwd_dns or "默认"))
			end
		end
	end

	--GFW列表
	if USE_GFW_LIST == "1" then
		if fs.access("/usr/share/passwall/rules/gfwlist") then
			fwd_dns = TUN_DNS
			if USE_DEFAULT_DNS == "chinadns_ng" and CHINADNS_DNS ~= "0" then
				fwd_dns = nil
			end
			if fwd_dns then
				local ipset_flag = setflag_4 .. "passwall_gfwlist," .. setflag_6 .. "passwall_gfwlist6"
				if NO_PROXY_IPV6 == "1" then
					ipset_flag = setflag_4 .. "passwall_gfwlist"
				end
				if REMOTE_FAKEDNS == "1" then
					ipset_flag = nil
				end
				local gfwlist_str = sys.exec('cat /usr/share/passwall/rules/gfwlist | grep -v -E "^#" | grep -v -E "' .. excluded_domain_str .. '"')
				for line in string.gmatch(gfwlist_str, "[^\r\n]+") do
					if line ~= "" then
						if NO_PROXY_IPV6 == "1" then
							set_domain_address(line, "::")
						end
						if dnsmasq_default_dns == fwd_dns then
							fwd_dns = nil
						else
							set_domain_dns(line, fwd_dns)
						end
						set_domain_ipset(line, ipset_flag)
					end
				end
				log(string.format("  - 防火墙域名表(gfwlist)：%s", fwd_dns or "默认"))
			end
		end
	end

	--中国列表
	if CHN_LIST ~= "0" then
		if fs.access("/usr/share/passwall/rules/chnlist") then
			fwd_dns = nil
			if CHN_LIST == "direct" then
				fwd_dns = LOCAL_DNS
			end
			if CHN_LIST == "proxy" then
				fwd_dns = TUN_DNS
			end
			if USE_DEFAULT_DNS == "chinadns_ng" and CHINADNS_DNS ~= "0" then
				fwd_dns = nil
			end
			if fwd_dns then
				local ipset_flag = setflag_4 .. "passwall_chnroute," .. setflag_6 .. "passwall_chnroute6"
				if CHN_LIST == "proxy" then
					if NO_PROXY_IPV6 == "1" then
						ipset_flag = setflag_4 .. "passwall_chnroute"
					end
					if REMOTE_FAKEDNS == "1" then
						ipset_flag = nil
					end
				end
				local chnlist_str = sys.exec('cat /usr/share/passwall/rules/chnlist | grep -v -E "^#" | grep -v -E "' .. excluded_domain_str .. '"')
				for line in string.gmatch(chnlist_str, "[^\r\n]+") do
					if line ~= "" then
						if CHN_LIST == "proxy" and NO_PROXY_IPV6 == "1" then
							set_domain_address(line, "::")
						end
						if dnsmasq_default_dns == fwd_dns then
							fwd_dns = nil
						else
							set_domain_dns(line, fwd_dns)
						end
						set_domain_ipset(line, ipset_flag)
					end
				end
				log(string.format("  - 中国域名表(chnroute)：%s", fwd_dns or "默认"))
			end
		end
	end

	--分流规则
	if uci:get(appname, TCP_NODE, "protocol") == "_shunt" and (USE_DEFAULT_DNS ~= "chinadns_ng" or CHINADNS_DNS == "0") then
		local t = uci:get_all(appname, TCP_NODE)
		local default_node_id = t["default_node"] or "_direct"
		uci:foreach(appname, "shunt_rules", function(s)
			local _node_id = t[s[".name"]] or "nil"
			if _node_id ~= "nil" and _node_id ~= "_blackhole" then
				if _node_id == "_default" then
					_node_id = default_node_id
				end

				fwd_dns = nil
				ipset_flag = nil
				no_ipv6 = nil

				if _node_id == "_direct" then
					fwd_dns = LOCAL_DNS
					ipset_flag = setflag_4 .. "passwall_whitelist," .. setflag_6 .. "passwall_whitelist6"
				else
					fwd_dns = TUN_DNS
					ipset_flag = setflag_4 .. "passwall_shuntlist," .. setflag_6 .. "passwall_shuntlist6"
					if NO_PROXY_IPV6 == "1" then
						ipset_flag = setflag_4 .. "passwall_shuntlist"
						no_ipv6 = true
					end
					if not only_global then
						if REMOTE_FAKEDNS == "1" then
							ipset_flag = nil
						end
					end
				end

				local domain_list = s.domain_list or ""
				for line in string.gmatch(domain_list, "[^\r\n]+") do
					if line ~= "" and not line:find("#") and not line:find("regexp:") and not line:find("geosite:") and not line:find("ext:") then
						if line:find("domain:") or line:find("full:") then
							line = string.match(line, ":([^:]+)$")
						end
						line = api.get_std_domain(line)
						add_excluded_domain(line)

						if no_ipv6 then
							set_domain_address(line, "::")
						end
						set_domain_dns(line, fwd_dns)
						set_domain_ipset(line, ipset_flag)
					end
				end
				if _node_id ~= "_direct" then
					log(string.format("  - Sing-Box/Xray分流规则(%s)：%s", s.remarks, fwd_dns or "默认"))
				end
			end
		end)
	elseif only_global == 1 and NO_PROXY_IPV6 == "1" then
		--节点：固定节点
		--代理模式：全局模式
		--过滤代理域名 IPv6：启用
		--禁止解析所有IPv6记录
		list1["#"] = {
			dns = {},
			ipsets = {},
			address = "::"
		}
	end

	if list1 and next(list1) then
		local address_out = io.open(CACHE_DNS_PATH .. "/000-address.conf", "a")
		local server_out = io.open(CACHE_DNS_PATH .. "/001-server.conf", "a")
		local ipset_out = io.open(CACHE_DNS_PATH .. "/ipset.conf", "a")
		local set_name = "ipset"
		if NFTFLAG == "1" then
			set_name = "nftset"
		end
		for key, value in pairs(list1) do
			if value.address then
				local domain = "." .. key
				if key == "#" then
					domain = key
				end
				address_out:write(string.format("address=/%s/%s\n", domain, value.address))
			end
			if value.dns and #value.dns > 0 then
				for i, dns in ipairs(value.dns) do
					server_out:write(string.format("server=/.%s/%s\n", key, dns))
				end
			end
			if value.ipsets and #value.ipsets > 0 then
				local ipsets_str = ""
				for i, ipset in ipairs(value.ipsets) do
					ipsets_str = ipsets_str .. ipset .. ","
				end
				ipsets_str = ipsets_str:sub(1, #ipsets_str - 1)
				ipset_out:write(string.format("%s=/.%s/%s\n", set_name, key, ipsets_str))
			end
		end
		address_out:close()
		server_out:close()
		ipset_out:close()
	end

	local f_out = io.open(CACHE_TEXT_FILE, "a")
	f_out:write(new_text)
	f_out:close()
end

if api.is_install("procd\\-ujail") then
	fs.copyr(CACHE_DNS_PATH, TMP_DNSMASQ_PATH)
else
	api.remove(TMP_DNSMASQ_PATH)
	fs.symlink(CACHE_DNS_PATH, TMP_DNSMASQ_PATH)
end

if DNSMASQ_CONF_FILE ~= "nil" then
	local conf_out = io.open(DNSMASQ_CONF_FILE, "a")
	conf_out:write(string.format("conf-dir=%s\n", TMP_DNSMASQ_PATH))
	if dnsmasq_default_dns then
		for s in string.gmatch(dnsmasq_default_dns, '[^' .. "," .. ']+') do
			conf_out:write(string.format("server=%s\n", s))
		end
		conf_out:write("all-servers\n")
		conf_out:write("no-poll\n")
		conf_out:write("no-resolv\n")
		conf_out:close()
		if USE_DEFAULT_DNS ~= "chinadns_ng" or CHINADNS_DNS == "0" then
			log(string.format("  - 默认：%s", dnsmasq_default_dns))
		end

		if FLAG == "default" then
			local f_out = io.open("/tmp/etc/passwall/default_DNS", "a")
			f_out:write(DEFAULT_DNS)
			f_out:close()
		end
	end
end

if USE_DEFAULT_DNS ~= "chinadns_ng" or CHINADNS_DNS == "0" then
	log("  - PassWall必须依赖于Dnsmasq，如果你自行配置了错误的DNS流程，将会导致域名(直连/代理域名)分流失效！！！")
end
