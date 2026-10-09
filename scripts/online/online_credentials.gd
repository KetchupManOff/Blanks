extends RefCounted
## Loads EOS credentials from outside committed source.
##
## Search order (first hit wins):
##   1. res://eos_credentials.cfg         (local, git-ignored)
##   2. user://eos_credentials.cfg         (per-user overrides)
##
## The checked-in file is `eos_credentials.example.cfg` - it contains no
## secrets and documents every key. Nothing here ever logs the secret.

const CONFIG_PATHS := ["res://eos_credentials.cfg", "user://eos_credentials.cfg"]

const DEFAULTS := {
	"product_name": "Tetris Yank Edition",
	"product_version": "1.0.0",
	"product_id": "",
	"sandbox_id": "",
	"deployment_id": "",
	"client_id": "",
	"client_secret": "",
	"encryption_key": "",
	"devtool_url": "localhost:4545",
	"devtool_credential": "PlayerOne",
	"auth_mode": "",  # "" = auto (debug: devtool, release: device id), "devtool" | "device"
}


static func load_credentials() -> Dictionary:
	## Returns a flat credentials/config dictionary; missing values fall
	## back to DEFAULTS. A dictionary without a product_id/sandbox_id/
	## deployment_id/client_id/secret is treated as "not configured".
	var merged: Dictionary = DEFAULTS.duplicate()
	var source: String = ""
	for path in CONFIG_PATHS:
		if not FileAccess.file_exists(path):
			continue
		var config := ConfigFile.new()
		var err: int = config.load(path)
		if err != OK:
			push_warning("online: ignoring unreadable credentials file %s (err %d)" % [path, err])
			continue
		source = path
		for key in merged.keys():
			merged[key] = config.get_value("eos", key, merged[key])
		break
	merged["_source"] = source
	return merged


static func is_configured(creds: Dictionary) -> bool:
	## Minimum credential set required for EOS initialization. The client
	## secret and encryption key are never printed or exposed to UI code.
	for key in ["product_id", "sandbox_id", "deployment_id", "client_id", "client_secret"]:
		if String(creds.get(key, "")).strip_edges().is_empty():
			return false
	return true