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
	if output.stderr and output.stderr:match("^0 devices found") then
		ya.dbg("[kdeconnect-send] Command reported 0 devices found in stderr. Returning empty.") -- source: 2
		return "", nil -- source: 2
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

-- Get selected files AND check for directories (requires sync context)
-- Returns: list of regular file paths, boolean indicating if a directory was selected
local get_selection_details = ya.sync(function() -- Renamed function
	ya.dbg("[kdeconnect-send] Entering get_selection_details sync block")
	local selected_map = cx.active.selected
	local regular_files = {}
	local directory_selected = false -- Flag to track if a directory is selected -- source: 3
	for idx, url in pairs(selected_map) do
		if url then
			if url.is_regular then
				local file_path = tostring(url)
				table.insert(regular_files, file_path)
			else
				ya.dbg("[kdeconnect-send] Non-regular file selected (likely directory): ", tostring(url))
				directory_selected = true -- source: 3
			end
		else
			ya.err("[kdeconnect-send] Encountered nil URL at index: ", idx)
		end
	end
	ya.dbg(
		"[kdeconnect-send] Exiting get_selection_details sync block. Found regular files: ",
		#regular_files,
		" Directory selected: ",
		directory_selected
	) -- source: 4
	return regular_files, directory_selected
end)

return {
	entry = function(_, job)
		ya.dbg("[kdeconnect-send] Plugin entry point triggered.") -- Debug log

		-- 1. Get selection details (files and directory flag)
		local selected_files, directory_selected = get_selection_details() -- Call updated function

		-- *** Add check for directory selection FIRST ***
		-- *** Add more logging around the check ***
		ya.dbg("[kdeconnect-send] Checking directory_selected flag. Value: ", directory_selected)
		if directory_selected then
			ya.dbg("[kdeconnect-send] directory_selected is true. Showing error and exiting.") -- Added log
			ya.warn("[kdeconnect-send] Directory selected. Exiting.")
			ya.notify({
				title = "KDE Connect Send",
				content = "Cannot send directories. Please select regular files only.",
				level = "error", -- Use error level
				timeout = 7,
			})
			return -- Exit if a directory was selected -- source: 5
		end
		-- *** Add log for when check passes ***
		ya.dbg("[kdeconnect-send] directory_selected is false. Proceeding.") -- source: 6

		-- Proceed only if no directory was selected
		ya.dbg("[kdeconnect-send] No directory selected. Checking number of regular files.")
		ya.dbg("[kdeconnect-send] Type of selected_files: ", type(selected_files))
		local len = -1
		if type(selected_files) == "table" then
			len = #selected_files
		end
		ya.dbg("[kdeconnect-send] Length of selected_files (#): ", len)

		-- If no *regular* files selected (and no directories were selected either), show notification and exit
		if len == 0 then
			ya.dbg("[kdeconnect-send] Length is 0. No regular files selected. Showing notification.") -- Debug
			ya.notify({
				title = "KDE Connect Send",
				content = "No regular files selected. Please select at least one file to send.", -- Adjusted message slightly
				level = "warn",
				timeout = 5,
			})
			return
		elseif len > 0 then
			ya.dbg("[kdeconnect-send] Length is > 0. Proceeding with device check.") -- Debug -- source: 7
		else
			-- This case handles potential errors from get_selection_details if it didn't return a table
			ya.err("[kdeconnect-send] Error determining selected files. Type: ", type(selected_files), ". Exiting.") -- source: 8
			ya.notify({
				title = "Plugin Error",
				content = "Could not determine selected files.",
				level = "error",
				timeout = 5,
			})
			return
		end

		-- 2. Get KDE Connect devices (Only runs if len > 0 and no directory selected)
		ya.dbg("[kdeconnect-send] Attempting to list KDE Connect devices with 'kdeconnect-cli -l'...") -- Debug log
		local devices_output, err = run_command({ "kdeconnect-cli", "-l" })

		-- Check for errors from run_command first
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

		-- Check if run_command returned empty string (meaning "0 devices found")
		if not devices_output or devices_output == "" then -- source: 9
			ya.dbg("[kdeconnect-send] No connected devices reported by kdeconnect-cli. Exiting silently.") -- Debug log
			-- Removed notification here previously to prevent hang
			return
		end

		-- 3. Parse devices (unchanged)
		local devices = {}
		local device_list_str = "Available Devices:\n"
		local has_reachable = false
		ya.dbg("[kdeconnect-send] Parsing device list (standard format)...")
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
					device_list_str = device_list_str .. "- " .. name .. " (ID: " .. id .. ") - Unreachable\n" -- source: 10
				end
			else
				ya.warn("[kdeconnect-send] Could not parse device line with pattern: ", line)
			end
		end

		-- Check if any *reachable* devices were found after parsing
		if not has_reachable then
			ya.dbg(
				"[kdeconnect-send] No *reachable* devices found after parsing. Exiting silently. List:\n",
				device_list_str
			) -- source: 11
			-- Removed notification here previously to prevent hang
			return
		end

		-- 4. Select Device (Corrected Version using ya.which)
		local device_id = nil
		local target_device_name = "Unknown" -- Initialize target_device_name here

		if #devices == 1 then
			device_id = devices[1].id
			target_device_name = devices[1].name -- Get name for single device case
			ya.dbg(
				"[kdeconnect-send] Only one reachable device found: ",
				target_device_name,
				" (",
				device_id,
				"). Using automatically."
			)
			ya.notify({
				title = "KDE Connect Send",
				content = "Sending to only available device: " .. target_device_name,
				level = "info",
				timeout = 3,
			})
		else
			-- *** MODIFIED PART START ***
			ya.dbg("[kdeconnect-send] Multiple reachable devices found. Prompting user with ya.which...")

			-- Prepare candidates for ya.which
			local device_choices = {}
			for i, device in ipairs(devices) do
				table.insert(device_choices, {
					-- Use index 'i' as the 'on' key for selection (ya.which returns the index)
					on = tostring(i),
					-- Display Name and ID in the description
					desc = string.format("%s (%s)", device.name, device.id),
				})
			end

			-- Add a cancel option
			table.insert(device_choices, { on = "q", desc = "Cancel" }) -- Or use "<Esc>", etc.

			-- Prompt the user to choose a device index
			local selected_index = ya.which({
				cands = device_choices,
				-- silent = false, -- Optional: Show key hints overlay
			})
			ya.dbg("[kdeconnect-send] ya.which returned index: ", selected_index or "nil")

			-- Check if the user cancelled or selected the cancel option
			if not selected_index or selected_index > #devices then -- Check if index is out of bounds (i.e., Cancel was chosen)
				ya.warn("[kdeconnect-send] Device selection cancelled by user.")
				ya.notify({ title = "KDE Connect Send", content = "Send cancelled.", level = "info", timeout = 3 })
				return
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
			-- *** MODIFIED PART END ***
		end

		-- 5. Validate Device ID (Validation loop removed as selection guarantees validity)
		ya.dbg(
			"[kdeconnect-send] Proceeding with selected device: ",
			device_id,
			" (",
			target_device_name,
			"). Starting file send loop..."
		)

		-- 6. Send files (unchanged logic, but uses corrected run_command)
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
			)
			-- Call the corrected run_command function
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
				success_count = success_count + 1 -- source: 16
			end
		end

		-- 7. Final Notification (unchanged)
		local final_message =
			string.format("Sent %d/%d files to %s.", success_count, #selected_files, target_device_name)
		local final_level = "info"
		if error_count > 0 then
			final_message = string.format(
				"Sent %d/%d files to %s. %d failed.", -- source: 17
				success_count,
				#selected_files,
				target_device_name,
				error_count
			) -- source: 17
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
