# kdeconnect-send.yazi

Send selected files to your smartphone or other devices using KDE Connect. This plugin allows you to quickly share files from Yazi file manager directly to any KDE Connect-paired device.

## Features

- Select and send multiple files to KDE Connect devices.
- **Fallback Support:** If no files are selected, the currently hovered file is sent.
- Automatically detects available and reachable KDE Connect devices.
- Automatically uses the only available device if there's just one.
- Prompts for device selection when multiple devices are available.
- Provides notifications for successful and failed transfers.
- **Directory Protection:** Warns and prevents sending directories (not supported by `kdeconnect-cli --share`).

## Requirements

- KDE Connect installed on your system.
- `kdeconnect-cli` command available in your PATH.
- At least one device paired and reachable via KDE Connect.

## Installation

### Using `ya pack`

```sh
ya pack -a tasnimAlam/kdeconnect-send
```

### Using Git

Clone the repository directly into your Yazi plugins directory:

```sh
git clone https://github.com/tasnimAlam/kdeconnect-send.yazi.git ~/.config/yazi/plugins/kdeconnect-send.yazi
```

## Usage

Add this to your `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "W"
run  = "plugin kdeconnect-send"
desc = "Send files via KDE Connect"
```

*Note: You can change `W` to any key combination you prefer.*

## How to Use

1. **Select files:** Use <kbd>Space</kbd> to select one or more files, or simply hover over a single file.
2. **Trigger Plugin:** Press <kbd>W</kbd> (or your custom key).
3. **Select Device:** If multiple devices are available, a list will appear. Press the number (e.g., `1`, `2`) corresponding to the device you want to use.
4. **Result:** The files will be sent, and you'll receive a notification indicating success or any errors encountered.

## License

This plugin is MIT-licensed.
