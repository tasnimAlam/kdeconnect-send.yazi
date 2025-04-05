-- phone_send.lua - Yazi plugin to send files to mobile phone via KDE Connect
-- Save this file to ~/.config/yazi/plugins/phone_send.lua

local ya = require("ya")
local fs = require("fs")
local ui = require("ui")

-- Configuration (modify these according to your setup)
local config = {
	-- For KDE Connect
	kdeconnect_device = "", -- Your device ID, leave empty to prompt

	-- General
	notify = true, -- Show notifications when transfer completes
	debug = true, -- Enable debug logging
	log_file = os.getenv("HOME") .. "/.config/yazi/phone_send_debug.log", -- Debug log file path
}

-- Debug logging function
local function log_debug(message)
	if not config.debug then
		return
	end

	local log_file = io.open(config.log_file, "a")
	if log_file then
		local timestamp = os.date("%Y-%m-%d %H:%M:%S")
		log_file:write(string.format("[%s] %s\n", timestamp, message))
		log_file:close()
	end
end

-- Helper function to get file size in human-readable format
local function human_size(bytes)
	local units = { "B", "KB", "MB", "GB", "TB" }
	local size = bytes
	local unit_index = 1

	while size > 1024 and unit_index < #units do
		size = size / 1024
		unit_index = unit_index + 1
	end

	return string.format("%.2f %s", size, units[unit_index])
end

-- Helper function to show notification
local function notify(message)
	if config.notify then
		log_debug("Sending notification: " .. message)
		os.execute(string.format('notify-send "Yazi Phone Send" "%s"', message))
	end
end

-- Helper function to execute commands with output capture
local function exec_command(cmd)
	log_debug("Executing command: " .. cmd)

	local handle = io.popen(cmd .. " 2>&1")
	if not handle then
		log_debug("Failed to open pipe for command")
		return false, "Failed to execute command"
	end

	local output = handle:read("*a")
	local success = handle:close()

	log_debug("Command output: " .. output)
	log_debug("Command success: " .. tostring(success))

	return success, output
end

-- Send file via KDE Connect
local function send_via_kdeconnect(file_path, file_name)
	log_debug("Starting KDE Connect transfer for: " .. file_path)

	local device_id = config.kdeconnect_device

	-- If no device ID is specified, get a list of devices
	if device_id == "" then
		log_debug("No device ID specified, fetching connected devices")

		-- Get connected devices
		local success, devices_output = exec_command("kdeconnect-cli -l --id-only")

		if not success then
			log_debug("Failed to list KDE Connect devices")
			return false, "Failed to list KDE Connect devices"
		end

		-- Parse device IDs
		local devices = {}
		for device in string.gmatch(devices_output, "[%w_%-]+") do
			log_debug("Found device: " .. device)
			table.insert(devices, device)
		end

		if #devices == 0 then
			log_debug("No KDE Connect devices found")
			return false, "No KDE Connect devices found"
		elseif #devices == 1 then
			device_id = devices[1]
			log_debug("Using single device: " .. device_id)
		else
			-- Interactive device selection
			ui.notify("Multiple devices found. Please select one from the terminal.", "info")
			for i, dev in ipairs(devices) do
				-- Get device name for better identification
				local cmd = string.format("kdeconnect-cli -d %s --name", dev)
				local name_success, name_output = exec_command(cmd)
				local device_name = name_success and name_output:gsub("\n", "") or dev
				print(i .. ": " .. device_name .. " (" .. dev .. ")")
			end

			io.write("Select device (1-" .. #devices .. "): ")
			local choice = tonumber(io.read())
			if choice and choice >= 1 and choice <= #devices then
				device_id = devices[choice]
				log_debug("Selected device: " .. device_id)
			else
				log_debug("Invalid device selection")
				return false, "Invalid device selection"
			end
		end
	end

	log_debug("Sending file via KDE Connect to device ID: " .. device_id)

	local cmd = string.format('kdeconnect-cli -d %s --share "%s"', device_id, file_path)
	local success, output = exec_command(cmd)

	if success then
		log_debug("File transfer successful")
		return true, "File sent successfully via KDE Connect"
	else
		log_debug("File transfer failed: " .. (output or "unknown error"))
		return false, "Failed to send via KDE Connect: " .. (output or "unknown error")
	end
end

-- Main function to send file
local function send_to_phone()
	log_debug("------ Starting new phone send operation ------")

	local current = ya.manager.current
	local file_path = current.current.path
	local file_name = fs.basename(file_path)

	log_debug("Selected file: " .. file_path)

	-- Check if file exists and is readable
	local file_stat = fs.stat(file_path)
	if not file_stat then
		log_debug("File does not exist or is not accessible")
		ui.notify("File does not exist or is not accessible", "error")
		return
	end

	-- Get file size
	local size = file_stat.size
	local readable_size = human_size(size)
	log_debug("File size: " .. readable_size)

	-- Ask for confirmation
	ui.notify(string.format("Send '%s' (%s) to phone via KDE Connect?", file_name, readable_size), "info")
	io.write("Confirm send? (y/N): ")
	local confirm = io.read():lower()

	if confirm ~= "y" and confirm ~= "yes" then
		log_debug("Transfer cancelled by user")
		ui.notify("Transfer cancelled", "info")
		return
	end

	-- Attempt transfer
	log_debug("Starting transfer")
	local success, message = send_via_kdeconnect(file_path, file_name)

	if success then
		log_debug("Transfer completed successfully")
		ui.notify(message, "success")
		notify(message)
	else
		log_debug("Transfer failed: " .. message)
		ui.notify(message, "error")
		notify("Error: " .. message)
	end

	log_debug("------ Phone send operation complete ------")
end

-- Register plugin with Yazi
return {
	entry = function(args)
		send_to_phone()
	end,
}
