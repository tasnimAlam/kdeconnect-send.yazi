-- ~/.config/yazi/plugins/kdeconnect-send.yazi/main.lua

-- Function to run a command and get its output
local function run_command(cmd_args)
	ya.dbg("[kdeconnect-send] Running command: ", table.concat(cmd_args, " ")) -- Debug log
	local child, err = Command(cmd_args[1]):args(cmd_args):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if err then
		ya.err("[kdeconnect-send] Spawn error: ", err) -- Error log
		return nil, err
	end
	local output, err = child:wait_with_output()
	if err then
		ya.err("[kdeconnect-send] Wait error: ", err) -- Error log
		return nil, err
	end
	if not output.status.success then
		local error_msg = "Command failed with code "
			.. tostring(output.status.code or "unknown")
			.. ": "
			.. cmd_args[1]
		if output.stderr and #output.stderr > 0 then
			error_msg = error_msg .. "\nStderr: " .. output.stderr
		end
		if output.stdout and #output.stdout > 0 then
			error_msg = error_msg .. "\nStdout: " .. output.stdout
		end
		if output.stderr and output.stderr:match("No devices found") then
			ya.warn("[kdeconnect-send] Command reported no devices found.")
			return "", nil
		end
		ya.err("[kdeconnect-send] Command execution failed: ", error_msg) -- Error log
		return nil, Error(error_msg)
	end
	-- ya.dbg("[kdeconnect-send] Command stdout: ", output.stdout) -- Reduce log verbosity
	return output.stdout, nil --
end

-- Get selected files (requires sync context)
local get_selected_files = ya.sync(function() --
	ya.dbg("[kdeconnect-send] Entering get_selected_files sync block") -- Debug log
	local selected_map = cx.active.selected --
	local files = {}
	for idx, url in pairs(selected_map) do -- Use idx, url
		if url and url.is_regular then --
			local file_path = tostring(url)
			table.insert(files, file_path)
		elseif url then --
		else
			ya.err("[kdeconnect-send] Encountered nil URL at index: ", idx) -- Error log
		end
	end
	ya.dbg("[kdeconnect-send] Exiting get_selected_files sync block. Found files: ", #files) -- Debug log
	return files
end)

return {
	entry = function(_, job)
		ya.dbg("[kdeconnect-send] Plugin entry point triggered.") -- Debug log

		-- 1. Get selected files
		local selected_files = get_selected_files()

		ya.dbg("[kdeconnect-send] Returned from get_selected_files.")
		ya.dbg("[kdeconnect-send] Type of selected_files: ", type(selected_files))
		local len = -1
		if type(selected_files) == "table" then
			len = #selected_files
		end
		ya.dbg("[kdeconnect-send] Length of selected_files (#): ", len)

		-- *** If no files selected, show notification and exit ***
		if len == 0 then
			ya.dbg("[kdeconnect-send] Length is 0. No files selected. Showing notification.") -- Debug
			ya.notify({
				title = "KDE Connect Send",
				content = "No files selected. Please select at least one file to send.",
				level = "warn",
				timeout = 5,
			})
			return
		elseif len > 0 then
			ya.dbg("[kdeconnect-send] Length is > 0. Proceeding with device check.") -- Debug
		else
			ya.err(
				"[kdeconnect-send] Error determining selected files length or type was not table. Type: ",
				type(selected_files),
				". Exiting."
			)
			ya.notify({
				title = "Plugin Error",
				content = "Could not determine selected files.",
				level = "error",
				timeout = 5,
			})
			return
		end

		-- 2. Get KDE Connect devices (Only runs if len > 0)
		ya.dbg("[kdeconnect-send] Attempting to list KDE Connect devices with 'kdeconnect-cli -l'...") -- Debug log
		local devices_output, err = run_command({ "kdeconnect-cli", "-l" })
		if err then
			ya.err("[kdeconnect-send] Failed to list devices command: ", tostring(err), ". Exiting.") -- Error log
			ya.notify({
				title = "KDE Connect Error",
				content = "Failed to run kdeconnect-cli -l: " .. tostring(err),
				level = "error",
				timeout = 5,
			})
			return
		end
		if not devices_output or devices_output == "" then
			ya.warn("[kdeconnect-send] No connected devices reported by kdeconnect-cli. Exiting.") -- Warning log
			ya.notify({
				title = "KDE Connect Error",
				content = "No connected devices found.",
				level = "warn",
				timeout = 5,
			})
			return
		end

		-- 3. Parse devices
		local devices = {}
		local device_list_str = "Available Devices:\n"
		local has_reachable = false
		ya.dbg("[kdeconnect-send] Parsing device list (standard format)...") -- Debug log
		local pattern = "^%-%s*(.+):%s*([%w_]+)%s*%((.-)%)$"
		for line in devices_output:gmatch("[^\r\n]+") do
			local name, id, status_line = line:match(pattern)
			if id and name and status_line then
				local is_reachable = status_line:match("reachable")
				name = name:match("^%s*(.-)%s*$")
				if is_reachable then
					table.insert(devices, { id = id, name = name })
					device_list_str = device_list_str .. "- " .. name .. " (ID: " .. id .. ")\n"
					has_reachable = true
				else
					device_list_str = device_list_str .. "- " .. name .. " (ID: " .. id .. ") - Unreachable\n"
				end
			else
				ya.warn("[kdeconnect-send] Could not parse device line with pattern: ", line) -- Warning log
			end
		end

		if not has_reachable then
			ya.warn("[kdeconnect-send] No reachable devices found after parsing. Exiting. List:\n", device_list_str) -- Warning log
			ya.notify({
				title = "KDE Connect Send",
				content = "No *reachable* devices found.\n" .. device_list_str,
				level = "warn",
				timeout = 8,
			})
			return
		end

		-- Check number of reachable devices
		local device_id = nil
		if #devices == 1 then
			device_id = devices[1].id
			local device_name = devices[1].name
			ya.dbg(
				"[kdeconnect-send] Only one reachable device found: ",
				device_name,
				" (",
				device_id,
				"). Using automatically."
			) -- Debug log
			ya.notify({
				title = "KDE Connect Send",
				content = "Sending to only available device: " .. device_name,
				level = "info",
				timeout = 3,
			})
		else
			ya.dbg("[kdeconnect-send] Multiple reachable devices found. Prompting user...") -- Debug log
			local input_title = device_list_str .. "\nEnter Device ID to send " .. #selected_files .. " files to:"
			local default_value = devices[1].id

			local device_id_input = ya.input({
				title = input_title,
				value = default_value,
				position = { "center", w = 70 },
			})

			if not device_id_input then
				ya.err("[kdeconnect-send] Failed to create input prompt. Exiting.") -- Error log
				ya.notify({
					title = "Plugin Error",
					content = "Could not create input prompt.",
					level = "error",
					timeout = 5,
				})
				return
			end
			ya.dbg("[kdeconnect-send] Input prompt created. Waiting for user input... (Might hang)") -- Debug log

			local received_id, event = device_id_input:recv()
			ya.dbg("[kdeconnect-send] Input received. Device ID: ", received_id or "nil", " Event: ", event or "nil")

			if event ~= 1 or not received_id or #received_id == 0 then
				ya.warn("[kdeconnect-send] Input cancelled or invalid (event=" .. tostring(event) .. "). Exiting.") -- Warning log
				ya.notify({ title = "KDE Connect Send", content = "Send cancelled.", level = "info", timeout = 3 })
				return
			end
			device_id = received_id
		end

		-- Validate the chosen/entered device_id
		local valid_id = false
		local target_device_name = "Unknown"
		for _, d in ipairs(devices) do
			if d.id == device_id then
				valid_id = true
				target_device_name = d.name
				break
			end
		end

		if not valid_id then
			ya.err("[kdeconnect-send] Invalid or unreachable Device ID selected: ", device_id, ". Exiting.") -- Error log
			ya.notify({
				title = "KDE Connect Send",
				content = "Invalid or unreachable Device ID selected: " .. device_id,
				level = "error",
				timeout = 5,
			})
			return
		end
		ya.dbg(
			"[kdeconnect-send] Device ID validated: ",
			device_id,
			" (",
			target_device_name,
			"). Starting file send loop..."
		) -- Debug log

		-- 4. Send files
		local success_count = 0
		local error_count = 0
		for i, file_path in ipairs(selected_files) do
			ya.dbg(
				"[kdeconnect-send] Sending file ",
				i,
				"/",
				#selected_files,
				": ",
				file_path,
				" to ",
				target_device_name
			) -- Debug log
			local _, send_err = run_command({ "kdeconnect-cli", "--share", file_path, "--device", device_id })

			if send_err then
				error_count = error_count + 1
				ya.err("[kdeconnect-send] Failed to send file ", file_path, " to ", device_id, ": ", tostring(send_err)) -- Error log
				ya.notify({
					title = "KDE Connect Error",
					content = "Failed to send: " .. file_path .. "\n" .. tostring(send_err),
					level = "error",
					timeout = 5,
				})
			else
				success_count = success_count + 1
			end
		end

		-- 5. Final Notification
		local final_message =
			string.format("Sent %d/%d files to %s.", success_count, #selected_files, target_device_name)
		local final_level = "info"
		if error_count > 0 then
			final_message = string.format(
				"Sent %d/%d files to %s. %d failed.",
				success_count,
				#selected_files,
				target_device_name,
				error_count
			)
			final_level = "warn"
		end
		if success_count == 0 and error_count > 0 then
			final_level = "error"
		end
		ya.dbg("[kdeconnect-send] Send process completed. Success: ", success_count, " Failed: ", error_count) -- Debug log
		ya.notify({ title = "KDE Connect Send Complete", content = final_message, level = final_level, timeout = 5 })
		ya.dbg("[kdeconnect-send] Plugin execution finished.") -- Debug log
	end,
}
