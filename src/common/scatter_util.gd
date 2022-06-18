extends Node

# To prevent the other core scripts from becoming too large, some of their
# utility functions are written here (only the functions that don't disturb
# reading the core code, mostly data validation and other verbose checks).


const ModifierStack := preload("../stack/modifier_stack.gd")
const ScatterItem := preload("../scatter_item.gd")


### SCATTER UTILITY FUNCTIONS ###

# Find all ScatterItems nodes among first level children.
static func discover_items(s) -> void:
	s.items.clear()
	s.total_item_proportion = 0

	for c in s.get_children():
		if c is ScatterItem:
			s.items.append(c)
			s.total_item_proportion += c.proportion

	if s.is_inside_tree():
		s.get_tree().node_configuration_warning_changed.emit(s)


# Make sure the output node exists. This is the parent node to
# everything generated by the scatter mesh
static func ensure_output_root_exists(s) -> void:
	if not s.output_root or not is_instance_valid(s.output_root):
		s.output_root = s.get_node_or_null("./ScatterOutput")

	if not s.output_root:
		s.output_root = Position3D.new()
		s.output_root.name = "ScatterOutput"
		s.add_child(s.output_root)
		s.output_root.owner = s.get_tree().get_edited_scene_root()


# Item root is a Node3D placed as a child of the ScatterOutput node.
# Each ScatterItem has a corresponding output node, serving as a parent for
# the Multimeshes or duplicates generated by the Scatter node.
static func get_or_create_item_root(item: ScatterItem) -> Node3D:
	var s = item.get_parent()
	ensure_output_root_exists(s)
	var item_root = s.output_root.get_node_or_null(NodePath(item.name))

	if not item_root:
		item_root = Node3D.new()
		s.output_root.add_child(item_root)
		item_root.name = item.name
		item_root.owner = item_root.get_tree().get_edited_scene_root()

	return item_root


static func get_or_create_multimesh(item: ScatterItem, count: int) -> MultiMeshInstance3D:
	var item_root := get_or_create_item_root(item)
	var mmi: MultiMeshInstance3D = item_root.get_node_or_null("MultiMeshInstance3D")

	if not mmi:
		mmi = MultiMeshInstance3D.new()
		item_root.add_child(mmi)
		mmi.set_owner(item_root.owner)
		mmi.set_name("MultiMeshInstance3D")

	if not mmi.multimesh:
		mmi.multimesh = MultiMesh.new()

	mmi.position = Vector3.ZERO
	# item.update_shadows()

	var mesh_instance: MeshInstance3D = get_merged_meshes_from(item.get_item())
	if not mesh_instance:
		return

	mmi.multimesh.instance_count = 0 # Set this to zero or you can't change the other values
	mmi.multimesh.mesh = mesh_instance.mesh
	mmi.multimesh.transform_format = 1
	mmi.multimesh.instance_count = count

	mesh_instance.queue_free()

	return mmi


# Called from child nodes who affect the rebuild process (like ScatterShape)
# Usually, it would be the Scatter node responsibility to listen to changes from
# the children nodes, but keeping track of the children is annoying (they can
# be moved around from a Scatter node to another, or put under a wrong node, or
# other edge cases).
# So instead, when a child changed, it notifies the parent Scatter node through
# this method.
static func request_parent_to_rebuild(node: Node, deferred := false) -> void:
	var parent = node.get_parent()
	if not parent.is_inside_tree():
		return

	# Can't include the Scatter script here because of cyclic references so we
	# typecheck it differently
	if parent and parent.has_method("is_scatter_node"):
		if deferred:
			parent.call_deferred("rebuild", true)
		else:
			parent.rebuild(true)


### MESH UTILITY ###

# Recursively search for all MeshInstances3D in the node's children and
# returns them all in an array. If node is a MeshInstance, it will also be
# added to the array
static func get_all_mesh_instances_from(node: Node3D) -> Array[MeshInstance3D]:
	var res: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		res.push_back(node)

	for c in node.get_children():
		res += get_all_mesh_instances_from(c)

	return res

# Find all the meshes below node and create a new single mesh with multiple
# surfaces from all of them.
static func get_merged_meshes_from(node) -> MeshInstance3D:
	var instances := get_all_mesh_instances_from(node)
	if instances.is_empty():
		return null

	var total_surfaces = 0
	var array_mesh = ArrayMesh.new()

	for mi in instances:
		var mesh: Mesh = mi.mesh
		var surface_count = mesh.get_surface_count()

		for i in surface_count:
			var arrays = mesh.surface_get_arrays(i)
			var length = arrays[ArrayMesh.ARRAY_VERTEX].size()

			for j in length:
				var pos: Vector3 = arrays[ArrayMesh.ARRAY_VERTEX][j]
				pos = pos * mi.transform
				arrays[ArrayMesh.ARRAY_VERTEX][j] = pos

			array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

			# Retrieve the material on the MeshInstance first, if none is defined,
			# use the one from the mesh resource.
			var material = mi.get_surface_override_material(i)
			if not material:
				material = mesh.surface_get_material(i)
			array_mesh.surface_set_material(total_surfaces, material)

			total_surfaces += 1

	var res := MeshInstance3D.new()
	res.mesh = array_mesh
	return res
