-- ~/.config/yazi/plugins/kdeconnect-send.yazi/main.lua

-- Function to run a command and get its output
local function run_command(cmd_args)
	ya.dbg("[kdeconnect-send] Running command: ", table.concat(cmd_args, " "))

	-- Separate the command from the arguments
	local command_name = cmd_args[1]
	local arguments = {}
	for i = 2, #cmd_args do
		table.insert(arguments, cmd_args[i])
	end
	ya.dbg("[kdeconnect-send] Command Name: ", command_name)
	ya.dbg("[kdeconnect-send] Arguments Table: ", arguments)

	-- Build the command correctly
	local cmd_builder = Command(command_name)
	if #arguments > 0 then
		cmd_builder:args(arguments)
	end

	local child, err = cmd_builder:stdout(Command.PIPED):stderr(Command.PIPED):spawn()

	if err then
		ya.err("[kdeconnect-send] Spawn error: ", err)
		return nil, err
	end
	local output, wait_err = child:wait_with_output()
	ya.dbg("[kdeconnect-send] wait_with_output finished.")
	if wait_err then
		ya.err("[kdeconnect-send] Wait error received: ", wait_err)
		return nil, wait_err
	end
	if not output then
		ya.err("[kdeconnect-send] Wait finished but output object is nil.")
		return nil, Error("Command wait returned nil output")
	end
	ya.dbg("[kdeconnect-send] Command Status Success: ", output.status.success)
	ya.dbg("[kdeconnect-send] Command Status Code: ", output.status.code)
	ya.dbg("[kdeconnect-send] Command Stdout: ", output.stdout or "nil")
	ya.dbg("[kdeconnect-send] Command Stderr: ", output.stderr or "nil")

	-- Note: The check for "0 devices found" might need adjustment depending on the output format of 'kdeconnect-cli -a'
	if output.stderr and output.stderr:match("^0 devices found") then
		ya.dbg("[kdeconnect-send] Command reported 0 devices found in stderr. Returning empty.")
		return "", nil
	end
	-- Also check stdout for potential "no devices" messages if -a uses stdout differently
	if output.stdout and output.stdout:match("no available devices found") then -- Example check, adjust if needed
		ya.dbg("[kdeconnect-send] Command reported no available devices in stdout. Returning empty.")
		return "", nil
	end

	if not output.status.success then
		local error_msg = "Command failed with code "
			.. tostring(output.status.code or "unknown")
			.. ": "
			.. command_name
		if output.stderr and #output.stderr > 0 then
			error_msg = error_msg .. "\nStderr: " .. output.stderr
		end
		if output.stdout and #output.stdout > 0 then
			error_msg = error_msg .. "\nStdout: " .. output.stdout
		end
		ya.err("[kdeconnect-send] Command execution failed: ", error_msg)
		return nil, Error(error_msg)
	end
	return output.stdout, nil
end

-- IMPROVED: Get selected files and check for directories
-- More reliable directory detection
local get_selection_details = ya.sync(function()
	ya.dbg("[kdeconnect-send] Entering improved get_selection_details sync block")
	local selected_map = cx.active.selected
	if not selected_map then
		ya.err("[kdeconnect-send] cx.active.selected is nil!")
		return {}, false -- Return empty table and false if selection map is nil
	end

	local regular_files = {}
	local directory_selected = false

	-- Use pcall to safely iterate in case pairs() or accessing selected_map fails
	local success, err = pcall(function()
		for idx, url in pairs(selected_map) do
			ya.dbg("[kdeconnect-send] Checking selection index: ", idx)
			if url then
				-- IMPROVED: More thorough checks for directory detection
				ya.dbg("[kdeconnect-send] URL type: ", type(url))

				-- Check if url has the is_dir property
				local is_dir = url.is_dir
				local is_regular = url.is_regular

				ya.dbg("[kdeconnect-send] URL: ", tostring(url), " Is Regular: ", is_regular, " Is Dir: ", is_dir)

				-- FIXED: Enhanced directory detection logic
				if is_dir == true then
					ya.dbg("[kdeconnect-send] Directory detected: ", tostring(url))
					directory_selected = true
				elseif is_regular == true then
					local file_path = tostring(url)
					table.insert(regular_files, file_path)
				else
					-- If can't determine clearly, extra check for directory-like properties
					local path_str = tostring(url)

					-- Try to use the command to check if it's a directory (async)
					ya.dbg("[kdeconnect-send] Neither is_dir nor is_regular is definitive. Extra check for: ", path_str)

					-- Fallback check - if not clearly regular, treat as potential directory for safety
					if is_regular ~= true then
						ya.warn(
							"[kdeconnect-send] Conservative approach: treating ambiguous item as directory: ",
							path_str
						)
						directory_selected = true
					else
						table.insert(regular_files, path_str)
					end
				end
			else
				ya.err("[kdeconnect-send] Encountered nil URL at index: ", idx)
			end
		end
	end)

	if not success then
		ya.err("[kdeconnect-send] Error during pairs(selected_map) iteration: ", err)
		return {}, false
	end

	ya.dbg(
		"[kdeconnect-send] Exiting get_selection_details sync block. Found regular files: ",
		#regular_files,
		" Directory selected: ",
		directory_selected
	)
	return regular_files, directory_selected
end)

-- ADDED: Secondary directory check using stat
local function double_check_for_directories(file_paths)
	ya.dbg("[kdeconnect-send] Running secondary directory check on", #file_paths, "paths")

	for _, path in ipairs(file_paths) do
		-- Try to use the 'test' command to check if it's a directory
		local _, dir_err = run_command({ "test", "-d", path })

		-- If test -d returns 0 (success/true), it's a directory
		if dir_err == nil then
			ya.dbg("[kdeconnect-send] Secondary check found directory:", path)
			return true -- Found at least one directory
		end
	end

	ya.dbg("[kdeconnect-send] Secondary check complete - no directories found")
	return false
end

return {
	entry = function(_, job)
		ya.dbg("[kdeconnect-send] Plugin entry point triggered.")

		-- 1. Get selection details (files and directory flag) using improved check
		local selected_files, directory_selected = get_selection_details()

		-- Handle potential errors if get_selection_details couldn't determine selection
		if not selected_files then
			ya.err("[kdeconnect-send] Failed to get selection details.")
			ya.notify({ title = "Plugin Error", content = "Could not read selection.", level = "error", timeout = 5 })
			return
		end

		-- 2. IMPROVED: Double-check for directories using secondary method
		local found_dir = directory_selected

		-- If primary check didn't find directories, try secondary check
		if not found_dir and #selected_files > 0 then
			found_dir = double_check_for_directories(selected_files)
		end

		ya.dbg("[kdeconnect-send] Directory detected: ", found_dir)

		if found_dir then
			ya.dbg("[kdeconnect-send] directory detected. Showing error and exiting.")
			ya.notify({
				title = "KDE Connect Send",
				content = "Cannot send directories. Please select regular files only.",
				level = "error",
				timeout = 7,
			})
			return -- Exit if a directory was detected
		end

		ya.dbg("[kdeconnect-send] No directories detected. Proceeding.")

		-- 3. Proceed only if no directory was detected and files exist
		ya.dbg("[kdeconnect-send] Checking number of regular files.")
		local len = #selected_files
		ya.dbg("[kdeconnect-send] Length of selected_files (#): ", len)

		if len == 0 then
			ya.dbg("[kdeconnect-send] Length is 0. No regular files to send.")
			-- Check if directory_selected was false - means no files were selected at all.
			if not directory_selected then
				ya.notify({
					title = "KDE Connect Send",
					content = "No regular files selected.",
					level = "warn",
					timeout = 5,
				})
			end
			return -- Exit cleanly
		end

		-- If we got here, directory_selected is false and len > 0.
		ya.dbg("[kdeconnect-send] Regular files found and no directories detected. Proceeding to device check.")

		-- 4. Get KDE Connect devices (using -a flag)
		ya.dbg("[kdeconnect-send] Attempting to list KDE Connect devices with 'kdeconnect-cli -a'...")
		local devices_output, err = run_command({ "kdeconnect-cli", "-a" }) -- Using -a flag

		if err then
			ya.err("[kdeconnect-send] Failed to list devices command: ", tostring(err), ". Exiting.")
			ya.notify({
				title = "KDE Connect Error",
				content = "Failed to run kdeconnect-cli -a: " .. tostring(err),
				level = "error",
				timeout = 5,
			})
			return
		end

		if not devices_output or devices_output == "" then
			ya.dbg("[kdeconnect-send] No available devices reported by kdeconnect-cli -a. Exiting silently.")
			ya.notify({
				title = "KDE Connect Send",
				content = "No available KDE Connect devices found.",
				level = "warn",
				timeout = 4,
			})
			return
		end

		-- 5. Parse devices (Adjust parsing for '-a' output format if needed)
		-- *** IMPORTANT: The parsing logic below ASSUMES '-a' output is similar to '-l' ***
		local devices = {}
		local device_list_str = "Available Devices:\n"
		local has_reachable = false -- Keep track if *any* device is found
		ya.dbg("[kdeconnect-send] Parsing device list (assuming -a format is like -l)...")
		local pattern = "^%-%s*(.+):%s*([%w_]+)%s*%((.-)%)$" -- Adjust if -a format differs
		for line in devices_output:gmatch("[^\r\n]+") do
			local name, id, status_line = line:match(pattern)
			if id and name and status_line then
				name = name:match("^%s*(.-)%s*$")
				table.insert(devices, { id = id, name = name, status = status_line })
				device_list_str = device_list_str
					.. "- "
					.. name
					.. " (ID: "
					.. id
					.. ") Status: "
					.. status_line
					.. "\n"
				has_reachable = true
			else
				ya.warn("[kdeconnect-send] Could not parse device line with pattern: ", line)
			end
		end

		if not has_reachable then
			ya.dbg(
				"[kdeconnect-send] No devices found after parsing output of 'kdeconnect-cli -a'. Exiting silently. List:\n",
				device_list_str
			)
			return
		end

		-- 6. Select Device (Using ya.which)
		local device_id = nil
		local target_device_name = "Unknown"

		if #devices == 1 then
			device_id = devices[1].id
			target_device_name = devices[1].name
			ya.dbg(
				"[kdeconnect-send] Only one device found: ",
				target_device_name,
				" (",
				device_id,
				"). Using automatically."
			)
		else
			ya.dbg("[kdeconnect-send] Multiple devices found. Prompting user with ya.which...")

			-- Prepare candidates for ya.which
			local device_choices = {}
			for i, device in ipairs(devices) do
				table.insert(device_choices, {
					on = tostring(i),
					desc = string.format("%s (%s) - %s", device.name, device.id, device.status), -- Show status in choice
				})
			end

			-- Add a cancel option
			table.insert(device_choices, { on = "q", desc = "Cancel" })

			-- Prompt the user to choose a device index
			local selected_index = ya.which({
				cands = device_choices,
			})
			ya.dbg("[kdeconnect-send] ya.which returned index: ", selected_index or "nil")

			-- Check if the user cancelled or selected the cancel option ('q')
			if not selected_index or selected_index > #devices then
				ya.warn("[kdeconnect-send] Device selection cancelled by user.")
				ya.notify({ title = "KDE Connect Send", content = "Send cancelled.", level = "info", timeout = 3 })
				return -- *** This return terminates the plugin ***
			end

			-- Get the device ID and name based on the selected index
			device_id = devices[selected_index].id
			target_device_name = devices[selected_index].name
			ya.dbg(
				"[kdeconnect-send] User selected device index ",
				selected_index,
				": ",
				target_device_name,
				" (",
				device_id,
				")"
			)
		end

		-- 7. Proceed with selected device
		ya.dbg(
			"[kdeconnect-send] Proceeding with selected device: ",
			device_id,
			" (",
			target_device_name,
			"). Starting file send loop..."
		)

		-- 8. Send files (Using selected_files list)
		local success_count = 0
		local error_count = 0
		for i, file_path in ipairs(selected_files) do -- Use selected_files here
			ya.dbg(
				"[kdeconnect-send] Sending file ",
				i,
				"/",
				#selected_files, -- Use #selected_files
				": ",
				file_path,
				" to ",
				target_device_name
			)
			local _, send_err = run_command({ "kdeconnect-cli", "--share", file_path, "--device", device_id })
			if send_err then
				error_count = error_count + 1
				ya.err("[kdeconnect-send] Failed to send file ", file_path, " to ", device_id, ": ", tostring(send_err))
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

		-- 9. Final Notification
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
		ya.dbg("[kdeconnect-send] Send process completed. Success: ", success_count, " Failed: ", error_count)
		ya.notify({ title = "KDE Connect Send Complete", content = final_message, level = final_level, timeout = 5 })
		ya.dbg("[kdeconnect-send] Plugin execution finished.")
	end,
}
