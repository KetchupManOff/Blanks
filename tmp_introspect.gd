extends SceneTree

func _init() -> void:
	print("--- EOSGMultiplayerPeer signals ---")
	for s in ClassDB.class_get_signal_list("EOSGMultiplayerPeer", true):
		var arg_names: Array = []
		for a in s.get("args", []):
			arg_names.append(String(a.get("name", "")))
		print("  signal: %s args=%s" % [s.get("name"), arg_names])
	print("--- EOSGMultiplayerPeer properties ---")
	for p in ClassDB.class_get_property_list("EOSGMultiplayerPeer", true):
		print("  prop: %s type=%s" % [p.get("name"), p.get("type")])
	quit(0)
