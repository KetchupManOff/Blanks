extends "res://scripts/ui/menu_controller.gd"
## Pause overlay: resume, restart, settings, and return-to-menu with a
## confirmation step while a run is active. Pure UI: everything routes back
## through host commands.


func show_pause() -> void:
	# No ui_cancel back callback here: the pause key itself resumes through
	# the input controller's polling, and a second back callback would race
	# it into an instant re-pause.
	var host := _host
	var items: Array = [
		make_item("RESUME", Callable(host, "cmd_resume")),
	]
	if host.online_is_local():
		# Online rounds restart from the lobby, never mid-session.
		items.append(make_item("RESTART", Callable(host, "cmd_restart_run")))
	items.append(make_item("SETTINGS", Callable(host, "cmd_open_settings_from_pause")))
	items.append(make_item("MAIN MENU", Callable(host, "cmd_confirm_return_to_menu")))
	open(
		"PAUSED",
		"Simulation frozen",
		items
	)
	# The subtitle carries the freeze note; the detail line must not show
	# stale copy from whatever menu screen preceded the run.
	_detail.text = ""


func show_remote_pause() -> void:
	## Passive overlay for an online client while the host paused the
	## match: no local actions (only the host resumes), so no menu items.
	open("PAUSED", "The host paused the match", [])
	_detail.text = "HOST PAUSED - WAITING FOR THE HOST TO RESUME"


func show_return_confirm() -> void:
	var host := _host
	open(
		"RETURN TO MENU?",
		"The current run will be lost",
		[
			make_item("YES, END RUN", Callable(host, "cmd_return_to_menu")),
			make_item("NO, KEEP PLAYING", Callable(host, "cmd_resume")),
		]
	)
	_detail.text = ""
