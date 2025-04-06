-- ~/.config/yazi/plugins/kdeconnect-send.yazi/main.lua

-- Function to run a command and get its output (Corrected Version)
local function run_command(cmd_args)
	ya.dbg("[kdeconnect-send] Running command: ", table.concat(cmd_args, " "))

	-- Separate the command from the arguments
	local command_name = cmd_args[1]
	local arguments = {}
	for i = 2, #cmd_args do
		table.insert(arguments, cmd_args[i])
	end
	ya.dbg("[kdeconnect-send] Command Name: ", command_name)
	ya.dbg("[kdeconnect-send] Arguments Table: ", arguments) -- Debug log for arguments

	-- Build the command correctly
	local cmd_builder = Command(command_name)
	if #arguments > 0 then
		cmd_builder:args(arguments) -- Pass only the arguments table
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
		ya.dbg("[kdeconnect-send] Command reported 0 devices found in stderr. Returning empty.") -- source: 2
		return "", nil -- source: 2
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
			.. command_name -- Use command_name here
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

-- Get selected file paths (sync context required for cx.active.selected)
-- Returns: list of selected file paths (strings)
local get_selected_paths = ya.sync(function()
	ya.dbg("[kdeconnect-send] Entering get_selected_paths sync block")
	local selected_map = cx.active.selected
	local paths = {}
	for idx, url in pairs(selected_map) do
		if url then
			table.insert(paths, tostring(url)) -- Store path as string
		else
			ya.err("[kdeconnect-send] Encountered nil URL at index: ", idx)
		end
	end
	ya.dbg("[kdeconnect-send] Exiting get_selected_paths sync block. Found paths: ", #paths)
	return paths
end)

return {
	entry = function(_, job)
		ya.dbg("[kdeconnect-send] Plugin entry point triggered.")

		-- 1. Get selected paths (Sync)
		local selected_paths = get_selected_paths() -- Use the modified get_selected_paths function

		-- Check if anything was selected
		if #selected_paths == 0 then
			ya.dbg("[kdeconnect-send] No files or directories selected.")
			ya.notify({
				title = "KDE Connect Send",
				content = "No files or directories selected.",
				level = "warn",
				timeout = 5,
			})
			return
		end
		ya.dbg("[kdeconnect-send] Selected paths: ", selected_paths)

		-- 2. *** NEW ASYNC DIRECTORY CHECK ***
		local contains_directory = false
		ya.dbg("[kdeconnect-send] Starting async directory check...")
		for i, path_str in ipairs(selected_paths) do
			local url = Url(path_str) -- Create Url object for fs.cha
			local cha, err = fs.cha(url, false) -- false = do not follow symlinks for the check

			if err then
				ya.err("[kdeconnect-send] Error checking file type for ", path_str, ": ", tostring(err))
			-- Optionally notify user about the error and exit, or just log and continue
			-- ya.notify({ title = "Plugin Error", content = "Could not check file type for: "..path_str, level = "error", timeout = 5 })
			-- return
			elseif cha and cha.is_dir then -- Check if fs.cha returned characteristics and if it's a directory [cite: 199]
				ya.warn("[kdeconnect-send] Directory selected: ", path_str)
				contains_directory = true
				break -- Exit loop early if a directory is found
			else
				-- It's either a file or cha was nil (maybe a broken link, etc.)
				-- For sending purposes, we treat non-directories as sendable for now.
				ya.dbg("[kdeconnect-send] Path is not confirmed as a directory: ", path_str)
			end
		end
		ya.dbg("[kdeconnect-send] Async directory check finished. contains_directory: ", contains_directory)

		-- 3. Exit if a directory was found
		if contains_directory then
			ya.notify({
				title = "KDE Connect Send",
				content = "Cannot send directories. Please select regular files only.",
				level = "error",
				timeout = 7,
			})
			return -- Exit plugin
		end

		-- If no directories were found, proceed with device listing and sending
		ya.dbg("[kdeconnect-send] No directories found in selection. Proceeding...")

		-- 4. Get KDE Connect devices (using -a flag)
		ya.dbg("[kdeconnect-send] Attempting to list KDE Connect devices with 'kdeconnect-cli -a'...") -- Debug log
		local devices_output, err = run_command({ "kdeconnect-cli", "-a" }) -- Using -a flag

		-- Check for errors from run_command first
		if err then
			ya.err("[kdeconnect-send] Failed to list devices command: ", tostring(err), ". Exiting.") -- Error log
			ya.notify({
				title = "KDE Connect Error",
				content = "Failed to run kdeconnect-cli -a: " .. tostring(err), -- Updated error message
				level = "error",
				timeout = 5,
			})
			return
		end

		-- Check if run_command returned empty string (meaning no devices found)
		-- This check might need adjustment based on 'kdeconnect-cli -a' output
		if not devices_output or devices_output == "" then
			ya.dbg("[kdeconnect-send] No available devices reported by kdeconnect-cli -a. Exiting silently.") -- Debug log
			-- Optional: Notify user no devices found
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

		-- Check if *any* devices were found after parsing
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

		-- 8. Send files (Using selected_paths)
		local success_count = 0
		local error_count = 0
		for i, file_path in ipairs(selected_paths) do -- Use selected_paths here
			ya.dbg(
				"[kdeconnect-send] Sending file ",
				i,
				"/",
				#selected_paths, -- Use #selected_paths
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
			string.format("Sent %d/%d files to %s.", success_count, #selected_paths, target_device_name)
		local final_level = "info"
		if error_count > 0 then
			final_message = string.format(
				"Sent %d/%d files to %s. %d failed.",
				success_count,
				#selected_paths,
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
