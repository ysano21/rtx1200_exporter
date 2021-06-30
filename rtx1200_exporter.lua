#!./upload.sh
--[[
Prometheus exporter for RTX1200

lua /rtx1200_exporter.lua
show status lua

schedule at 1 startup * lua /rtx1200_exporter.lua 
]]
-- vim:fenc=cp932


-- start prometheus exporter

-- config
LUADEBUG = os.getenv("LUA_DEBUG")
if ((LUADEBUG == nil) or (LUADEBUG == "0"))
then
  syslogout = "off"
else
  syslogout = "on"
end

-- tcp socket ready
tcp = rt.socket.tcp()
tcp:setoption("reuseaddr", true)
res, err = tcp:bind("*", 9100)
if not res and err then
	rt.syslog("NOTICE", err)
	os.exit(1)
end
res, err = tcp:listen()
if not res and err then
	rt.syslog("NOTICE", err)
	os.exit(1)
end

-- until HTTP Method
while 1 do
	local control = assert(tcp:accept())

	local raddr, rport = control:getpeername()

	control:settimeout(30)
	local ok, err = pcall(function ()
		-- get request line
		local request, err, partial = control:receive()
		if err then error(err) end
		-- get request headers
		while 1 do
			local header, err, partial = control:receive()
			if err then error(err) end
			if header == "" then
				-- end of headers
				break
			else
				-- just ignore headers
			end
		end

		if string.find(request, "GET /metrics ") == 1 then
			local sent, err = control:send(
				"HTTP/1.0 200 OK\r\n"..
				"Connection: close\r\n"..
				"Content-Type: text/plain\r\n"..
				"\r\n"..
				"# Collecting metrics...\n"
			)
			if err then error(err) end

			local ok, result = rt.command("show environment", $"${syslogout}")
			if not ok then error("command failed") end
			local cpu5sec, cpu1min, cpu5min, memused = string.match(result, /CPU:\s*(\d+)%\(5sec\)\s*(\d+)%\(1min\)\s*(\d+)%\(5min\)\s*メモリ:\s*(\d+)% used/)
			local temperature = string.match(result, /筐体内温度\(.*\): (\d+)/)
			if (temperature == nil)
			then
				temperature = 0
			end
			local luacount = collectgarbage("count")

			local sent, err = control:send(
				"# TYPE yrhCpuUtil5sec gauge\n"..
				$"yrhCpuUtil5sec ${cpu5sec}\n"..
				"# TYPE yrhCpuUtil1min gauge\n"..
				$"yrhCpuUtil1min ${cpu1min}\n"..
				"# TYPE yrhCpuUtil5min gauge\n"..
				$"yrhCpuUtil5min ${cpu5min}\n"..
				"# TYPE yrhInboxTemperature gauge\n"..
				$"yrhInboxTemperature ${temperature}\n"..
				"# TYPE yrhMemoryUtil gauge\n"..
				$"yrhMemoryUtil ${memused}\n"..
				"# TYPE yrhLuaCount gauge\n"..
				$"yrhLuaCount ${luacount}\n"
			)
			if err then error(err) end

			local sent, err = control:send(
				"# TYPE ifOutOctets counter\n"..
				"# TYPE ifInOctets counter\n"..
				"# TYPE ifInOverflow counter\n"
			)
			if err then error(err) end

			-- nvr500/rtx830:2 rtx1200:3
			-- RTX830でgoto分がエラーになる為ifに変更
			for n = 1, 4 do
				local ok, result = rt.command($"show status lan${n}", $"${syslogout}")
				if ok then -- workaround: rtx830 'goto' do not work
					local txpackets, txoctets = string.match(result, /送信パケット:\s*(\d+)\s*パケット\((\d+)\s*オクテット\)/)
					local rxpackets, rxoctets = string.match(result, /受信パケット:\s*(\d+)\s*パケット\((\d+)\s*オクテット\)/)
					-- string.match内で長音記号を使用するとエラー終了するので.でmatchさせる
					local rxoverflow = string.match(result, "受信オ..バ..フロ..:%s+(%d*)")
					local sent, err = control:send(
						$"ifOutOctets{if=\"${n}\"} ${txoctets}\n"..
						$"ifInOctets{if=\"${n}\"} ${rxoctets}\n"..
						$"ifOutPkts{if=\"${n}\"} ${txpackets}\n"..
						$"ifInPkts{if=\"${n}\"} ${rxpackets}\n"..
						$"ifInOverflow{if=\"${n}\"} ${rxoverflow}\n"
					)
					if err then error(err) end
				end
			end

			local ok, result = rt.command("show ip connection summary", $"${syslogout}")
			local v4session, v4channel
			if (result == nil) then
				v4session = 0
				v4channel = 0
			else
				v4session, v4channel = string.match(result, /Total Session: (\d+)\s+Total Channel:\s*(\d+)/)
			end

			local ok, result = rt.command("show ipv6 connection summary", $"${syslogout}")
			local v6session, v6channel
			if (result == nil) then
				v6session = 0
				v6channel = 0
			else
				v6session, v6channel = string.match(result, /Total Session: (\d+)\s+Total Channel:\s*(\d+)/)
			end

			local sent, err = control:send(
				"# TYPE ipSession counter\n"..
				$"ipSession{proto=\"v4\"} ${v4session}\n"..
				$"ipSession{proto=\"v6\"} ${v6session}\n"..
				"# TYPE ipChannel counter\n"..
				$"ipChannel{proto=\"v4\"} ${v4channel}\n"..
				$"ipChannel{proto=\"v6\"} ${v6channel}\n"
			)
			if err then error(err) end

			local ok, result = rt.command("show status dhcp", $"${syslogout}")
			if (result ~= nil) then
				local dhcptotal = string.match(result, /全アドレス数:\s*(\d+)/)
				local dhcpexcluded = string.match(result, /除外アドレス数:\s*(\d+)/)
				local dhcpassigned = string.match(result, /割り当て中アドレス数:\s*(\d+)/)
				local dhcpavailable = string.match(result, /利用[^:]+?アドレス数:\s*(\d+)/)
				local sent, err = control:send(
					"# TYPE ipDhcp gauge\n"..
					$"ipDhcp{} ${dhcptotal}\n"..
					$"ipDhcp{type=\"excluded\"} ${dhcpexcluded}\n"..
					$"ipDhcp{type=\"assigned\"} ${dhcpassigned}\n"..
					$"ipDhcp{type=\"available\"} ${dhcpavailable}\n"
				)
			end
			if err then error(err) end

			-- nat descritor
			local sent, err = control:send(
				"# TYPE natDescriptorCurrent counter\n"..
				"# TYPE natDescriptorMax counter\n"
			)
			if err then error(err) end
			local ok, result = rt.command("show nat descriptor address all", $"${syslogout}")
			if not ok then error(result) end
			for port in string.gmatch(result, "参照NATディスクリプタ : (%d+),") do
				local ok, result = rt.command($"show nat descriptor masquerade port ${port} summary", $"${syslogout}")
				if ok then
					local cur, max = string.match(result, "(%d+)\/%s+(%d+)") do
						local sent, err = control:send(
							$"natDescriptorCurrent{port=\"${port}\"} ${cur}\n"..
							$"natDescriptorMax{port=\"${port}\"} ${max}\n"
						)
						if err then error(err) end
					end
				end
			end

		elseif string.find(request, "GET / ") == 1 then
			local sent, err = control:send(
				"HTTP/1.0 200 OK\r\n"..
				"Connection: close\r\n"..
				"Content-Type: text/html\r\n"..
				"\r\n"..
				"<!DOCTYPE html><title>RTX1200 Prometheus exporter</title><p><a href='/metrics'>/metrics</a>"
			)
		else
			local sent, err = control:send(
				"HTTP/1.0 404 Not Found\r\n"..
				"Connection: close\r\n"..
				"Content-Type: text/plain\r\n"..
				"\r\n"..
				"Not Found"
			)
			if err then error(err) end
		end
	end)
	if not ok then
		rt.syslog("INFO", "failed to response " .. err)
	end
	control:close()
	collectgarbage("collect")
end
