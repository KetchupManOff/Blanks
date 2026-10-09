extends "res://scripts/ui/menu_controller.gd"
## Profile management screen: selects the profile for the next solo run,
## browses/creates/renames profiles, shows each profile's five-best result
## histories for every mode, and opens that profile's guided controller
## binding flow. In lobby mode it picks the joining profile for one coop
## slot and hides profiles already joined elsewhere. Everything mutates
## state through host commands; the screen itself only reads.

const ModeRules = preload("res://scripts/core/mode_rules.gd")

## Screen modes: "solo_start" (pick a profile, then start the pending
## mode), "lobby" (pick the joining profile for one slot), "manage"
## (browse/activate/rename/bind).
var _mode := "manage"
var _pending_game_mode: int = ModeRules.Mode.MARATHON
var _lobby_slot: int = -1
var _submenu_profile_id := ""


func _ready() -> void:
	super()
	layer = 15


# ---------------------------------------------------------------- lifecycle

func open_solo_start(game_mode: int) -> void:
	## Profile selection before a solo game; choosing a profile starts it.
	_mode = "solo_start"
	_pending_game_mode = game_mode
	_lobby_slot = -1
	_submenu_profile_id = ""
	var host := _host
	open(
		"SELECT PROFILE",
		"A / Enter: start with this profile    B / Esc: back",
		_build_items(),
		Callable(host, "cmd_profile_screen_back")
	)
	_update_detail()


func open_lobby_join(slot: int) -> void:
	## Profile selection for one coop lobby slot; profiles already joined
	## in another slot are hidden.
	_mode = "lobby"
	_lobby_slot = slot
	_pending_game_mode = ModeRules.Mode.MARATHON
	_submenu_profile_id = ""
	var host := _host
	open(
		"JOIN SLOT %d" % (slot + 1),
		"A / Enter: join with this profile    B / Esc: back",
		_build_items(),
		Callable(host, "cmd_profile_screen_back")
	)
	_update_detail()


func open_manage() -> void:
	## Profile browser from the main menu.
	_mode = "manage"
	_lobby_slot = -1
	_pending_game_mode = ModeRules.Mode.MARATHON
	_submenu_profile_id = ""
	var host := _host
	open(
		"PROFILES",
		"A / Enter: select    B / Esc: back",
		_build_items(),
		Callable(host, "cmd_profile_screen_back")
	)
	_update_detail()


func refresh() -> void:
	## Rebuild the item list after profile mutations (create/rename).
	if not visible:
		return
	var keep := _selected
	_items = _build_items()
	_selected = clampi(keep, 0, maxi(0, _items.size() - 1))
	_rebuild_items()
	_update_detail()


# --------------------------------------------------------------------- items

func _build_items() -> Array:
	var items: Array = []
	var settings = _host.settings
	if _submenu_profile_id.is_empty():
		var taken: Array = _taken_profile_ids()
		for profile in settings.profiles:
			var profile_id: String = profile["id"]
			var label: String = profile["name"]
			if _mode == "manage" and profile_id == settings.active_profile_id:
				label += "  [ACTIVE]"
			if _mode == "lobby" and taken.has(profile_id):
				continue
			items.append(make_item(label, Callable(self, "_choose_profile").bind(profile_id)))
		items.append(make_item("CREATE PROFILE", Callable(self, "_create_profile")))
	else:
		var profile: Dictionary = settings.find_profile(_submenu_profile_id)
		if profile.is_empty():
			_submenu_profile_id = ""
			return _build_items()
		var name: String = profile["name"]
		if settings.active_profile_id != _submenu_profile_id:
			items.append(make_item("SET ACTIVE", Callable(self, "_set_active").bind(_submenu_profile_id)))
		items.append(make_item("RENAME", Callable(self, "_rename_profile").bind(name)))
		items.append(make_item("CONTROLLER BINDINGS", Callable(self, "_bind_controller").bind(_submenu_profile_id)))
	items.append(make_item("BACK", Callable(self, "_item_back")))
	return items


func _taken_profile_ids() -> Array:
	## Profiles already joined to another lobby slot.
	if _mode != "lobby" or _host == null:
		return []
	return _host.lobby_taken_profile_ids(_lobby_slot)


func _choose_profile(profile_id: String) -> void:
	match _mode:
		"solo_start":
			_host.cmd_solo_profile_selected(profile_id, _pending_game_mode)
		"lobby":
			_host.cmd_lobby_join_profile(_lobby_slot, profile_id)
		"manage":
			_open_submenu(profile_id)


func _open_submenu(profile_id: String) -> void:
	_play_nav_sfx("menu_confirm")
	_submenu_profile_id = profile_id
	_selected = 0
	var profile: Dictionary = _host.settings.find_profile(profile_id)
	open(
		String(profile.get("name", "PROFILE")),
		"A / Enter: select    B / Esc: back",
		_build_items(),
		Callable(self, "_item_back")
	)
	_update_detail()


func _set_active(profile_id: String) -> void:
	_play_nav_sfx("menu_confirm")
	_host.cmd_set_active_profile(profile_id)
	_open_submenu(profile_id)


func _rename_profile(_current_name: String) -> void:
	_play_nav_sfx("menu_confirm")
	_host.cmd_open_name_rename(_submenu_profile_id)


func _bind_controller(profile_id: String) -> void:
	_play_nav_sfx("menu_confirm")
	_host.cmd_profile_bind_controller(profile_id)


func _create_profile() -> void:
	_play_nav_sfx("menu_confirm")
	_host.cmd_open_name_create(_lobby_slot)


func _item_back() -> void:
	_play_nav_sfx("menu_back")
	if _mode == "manage" and not _submenu_profile_id.is_empty():
		_open_list()
		return
	_host.cmd_profile_screen_back()


func _open_list() -> void:
	_submenu_profile_id = ""
	_selected = 0
	var host := _host
	open("PROFILES", "A / Enter: select    B / Esc: back", _build_items(), Callable(host, "cmd_profile_screen_back"))
	_update_detail()


# ------------------------------------------------------------------ histories

func _move(delta: int) -> void:
	super(delta)
	_update_detail()


## Fills the left detail panel with the selected profile's result
## histories, best first, using the mode descriptors for labels.
func _update_detail() -> void:
	if _detail == null or _host == null:
		return
	var settings = _host.settings
	var profile_id := _selected_profile_id()
	if profile_id.is_empty():
		_detail.text = "SELECT A PROFILE"
		return
	var profile: Dictionary = settings.find_profile(profile_id)
	if profile.is_empty():
		_detail.text = "SELECT A PROFILE"
		return
	var lines: Array[String] = [String(profile["name"]).to_upper(), ""]
	var any := false
	for descriptor in ModeRules.descriptors():
		var history: Array = settings.profile_history(profile_id, descriptor["key"])
		if history.is_empty():
			continue
		any = true
		var entries: Array[String] = []
		for record in history:
			if descriptor["ranking"] == ModeRules.RANK_SCORE_DESC:
				entries.append("%d" % int(record["score"]))
			else:
				entries.append(ModeRules.format_time(float(record["elapsed"])))
		lines.append("%s:" % descriptor["label"].to_upper())
		lines.append("  " + "  ".join(entries))
	if not any:
		lines.append("NO RESULTS YET")
	_detail.text = "\n".join(lines)


## The profile id of the selected row (submenu or list), or "" when the
## selection is a command row.
func _selected_profile_id() -> String:
	if not _submenu_profile_id.is_empty():
		return _submenu_profile_id
	if _selected < 0 or _selected >= _items.size():
		return ""
	var bound: Array = (_items[_selected].get("callback", Callable()) as Callable).get_bound_arguments()
	if bound.size() > 0:
		return String(bound[0])
	return ""
