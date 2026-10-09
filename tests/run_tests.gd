extends SceneTree
## Headless test runner. Usage:
##   godot --headless --path <project_dir> --script res://tests/run_tests.gd
## Exits with code 0 when all checks pass, 1 otherwise.
## Tests run on the first process frame: the root (and every node added to
## it) is only inside the scene tree from that point on, which audio
## playback and tree-dependent helpers rely on.

const SUITES := [
	"res://tests/test_board.gd",
	"res://tests/test_srs.gd",
	"res://tests/test_bag.gd",
	"res://tests/test_gameplay.gd",
	"res://tests/test_tspin.gd",
	"res://tests/test_scoring.gd",
	"res://tests/test_settings.gd",
	"res://tests/test_theme.gd",
	"res://tests/test_bindings.gd",
	"res://tests/test_audio.gd",
	"res://tests/test_coop_core.gd",
	"res://tests/test_shell.gd",
	"res://tests/test_coop_shell.gd",
	"res://tests/test_online_core.gd",
	"res://tests/test_online_session.gd",
]

var _exit_code: int = 0
var _done: bool = false
# The developer's real user://settings.json is moved aside for the whole
# run so default-sensitive tests (theme selection, defaults) never read
# persisted personal settings; it is restored before the process exits.
var _settings_backup: PackedByteArray = PackedByteArray()
var _settings_existed: bool = false


func _process(_delta: float) -> bool:
	if not _done:
		_run_all()
	if _done:
		quit(_exit_code)
	return _done


func _run_all() -> void:
	if _done:
		return
	_done = true
	_set_user_settings_aside()
	var total_failures: int = 0
	var total_checks: int = 0
	var total_tests: int = 0
	print("=== Tetris Yank Edition headless test run ===")
	for suite_path in SUITES:
		var suite_script: GDScript = load(suite_path)
		if suite_script == null:
			print("!! cannot load suite: " + suite_path)
			_exit_code = 1
			total_failures += 1
			continue
		var suite: RefCounted = suite_script.new()
		var suite_name: String = suite_path.get_file().get_basename()
		var method_names: Array[String] = []
		for m in suite.get_method_list():
			var name: String = m["name"]
			if name.begins_with("test_") and not method_names.has(name):
				method_names.append(name)
		method_names.sort()
		var suite_failed_tests: int = 0
		if suite.has_method("setup_tree"):
			suite.setup_tree(self)
		suite.setup()
		for test_name in method_names:
			total_tests += 1
			var checks_before: int = suite.checks
			var failures_before: int = suite.failures
			suite.call(test_name)
			var new_failures: int = suite.failures - failures_before
			if new_failures == 0:
				print("  PASS  %s.%s" % [suite_name, test_name])
			else:
				suite_failed_tests += 1
				print("  FAIL  %s.%s" % [suite_name, test_name])
				for msg in suite.messages:
					print(msg)
				suite.messages.clear()
		suite.teardown()
		total_failures += suite.failures
		total_checks += suite.checks
		print("  %s: %d tests, %d failures" % [suite_name, method_names.size(), suite_failed_tests])
	print("=== %d tests, %d checks, %d failures ===" % [total_tests, total_checks, total_failures])
	if total_failures > 0:
		_exit_code = 1
	_restore_user_settings()


func _set_user_settings_aside() -> void:
	var path := "user://settings.json"
	_settings_existed = FileAccess.file_exists(path)
	if not _settings_existed:
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	_settings_backup = f.get_buffer(f.get_length())
	f.close()
	DirAccess.remove_absolute(path)


func _restore_user_settings() -> void:
	var path := "user://settings.json"
	if _settings_existed:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_settings_backup)
			f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	quit(_exit_code)
