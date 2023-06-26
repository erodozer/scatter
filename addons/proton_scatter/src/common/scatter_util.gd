extends Node

# To prevent the other core scripts from becoming too large, some of their
# utility functions are written here (only the functions that don't disturb
# reading the core code, mostly data validation and other verbose checks).


const ProtonScatter := preload("../scatter.gd")
const ProtonScatterItem := preload("../scatter_item.gd")
const ModifierStack := preload("../stack/modifier_stack.gd")

### SCATTER UTILITY FUNCTIONS ###


# Make sure the output node exists. This is the parent node to
# everything generated by the scatter mesh
static func ensure_output_root_exists(s: ProtonScatter) -> void:
	# Check if the node exists in the tree
	if not s.output_root:
		s.output_root = s.get_node_or_null("ScatterOutput")

	# If the node is valid, end here
	if is_instance_valid(s.output_root) and s.has_node(NodePath(s.output_root.name)):
		enforce_output_root_owner(s)
		return

	# Some conditions are not met, cleanup and recreate the root
	if s.output_root:
		if s.has_node(NodePath(s.output_root.name)):
			s.remove_node(s.output_root.name)
		s.output_root.queue_free()
		s.output_root = null

	s.output_root = Marker3D.new()
	s.output_root.name = "ScatterOutput"
	s.add_child(s.output_root, true)

	enforce_output_root_owner(s)


static func enforce_output_root_owner(s: ProtonScatter) -> void:
	if is_instance_valid(s.output_root) and s.is_inside_tree():
		if s.show_output_in_tree:
			set_owner_recursive(s.output_root, s.get_tree().get_edited_scene_root())
		else:
			set_owner_recursive(s.output_root, null)

		# TMP: Workaround to force the scene tree to update and take in account
		# the owner changes. Otherwise it doesn't show until much later.
		s.output_root.update_configuration_warnings()


# Item root is a Node3D placed as a child of the ScatterOutput node.
# Each ScatterItem has a corresponding output node, serving as a parent for
# the Multimeshes or duplicates generated by the Scatter node.
static func get_or_create_item_root(item: ProtonScatterItem) -> Node3D:
	var s: ProtonScatter = item.get_parent()
	ensure_output_root_exists(s)
	var item_root: Node3D = s.output_root.get_node_or_null(NodePath(item.name))

	if not item_root:
		item_root = Node3D.new()
		item_root.name = item.name
		s.output_root.add_child(item_root, true)

		if Engine.is_editor_hint():
			item_root.owner = item.get_tree().get_edited_scene_root()

	return item_root


static func get_or_create_multimesh(item: ProtonScatterItem, count: int) -> MultiMeshInstance3D:
	var item_root := get_or_create_item_root(item)
	var mmi: MultiMeshInstance3D = item_root.get_node_or_null("MultiMeshInstance3D")

	if not mmi:
		mmi = MultiMeshInstance3D.new()
		item_root.add_child(mmi, true)

		mmi.set_owner(item_root.owner)
		mmi.set_name("MultiMeshInstance3D")

	if not mmi.multimesh:
		mmi.multimesh = MultiMesh.new()

	mmi.position = Vector3.ZERO
	mmi.set_cast_shadows_setting(item.override_cast_shadow)
	mmi.set_material_override(item.override_material)

	var node = item.get_item()
	var mesh_instance: MeshInstance3D = get_merged_meshes_from(node)
	if not mesh_instance:
		return

	mmi.multimesh.instance_count = 0 # Set this to zero or you can't change the other values
	mmi.multimesh.mesh = mesh_instance.mesh
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.instance_count = count

	mesh_instance.queue_free()

	return mmi


static func get_or_create_particles(item: ProtonScatterItem) -> GPUParticles3D:
	var item_root := get_or_create_item_root(item)
	var particles: GPUParticles3D = item_root.get_node_or_null("GPUParticles3D")

	if not particles:
		particles = GPUParticles3D.new()
		item_root.add_child(particles)

		particles.set_name("GPUParticles3D")
		particles.set_owner(item_root.owner)

	var node = item.get_item()
	var mesh_instance: MeshInstance3D = get_merged_meshes_from(node)
	if not mesh_instance:
		return

	particles.set_draw_pass_mesh(0, mesh_instance.mesh)
	particles.position = Vector3.ZERO
	particles.local_coords = true

	# Use the user provided material if it exists.
	var process_material: Material = item.override_process_material

	# Or load the default one if there's nothing.
	if not process_material:
		process_material = ShaderMaterial.new()
		process_material.shader = preload("../particles/static.gdshader")

	particles.set_process_material(process_material)

	# TMP: Workaround to get infinite life time.
	# Should be fine, but extensive testing is required.
	# I can't get particles to restart when using emit_particle() from a script, so it's either
	# that, or encoding the transform array in a texture an read that data from the particle
	# shader, which is significantly harder.
	particles.lifetime = 1.79769e308

	# Kill previous particles or new ones will not spawn.
	particles.restart()

	return particles


# Called from child nodes who affect the rebuild process (like ScatterShape)
# Usually, it would be the Scatter node responsibility to listen to changes from
# the children nodes, but keeping track of the children is annoying (they can
# be moved around from a Scatter node to another, or put under a wrong node, or
# other edge cases).
# So instead, when a child change, it notifies the parent Scatter node through
# this method.
static func request_parent_to_rebuild(node: Node, deferred := true) -> void:
	var parent = node.get_parent()
	if not parent or not parent.is_inside_tree():
		return

	if parent and parent is ProtonScatter:
		if deferred:
			parent.rebuild.call_deferred(true)
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
		res.append_array(get_all_mesh_instances_from(c))

	return res


# Merge all the MeshInstances from the local node tree into a single MeshInstance.
# /!\ This is a best effort algorithm and will not work in some specific cases. /!\
#
# Mesh resources can have a maximum of 8 surfaces:
# + If less than 8 different surfaces are found across all the MeshInstances,
#   this returns a single instance with all the surfaces.
#
# + If more than 8 surfaces are found, but some shares the same material,
#   these surface will be merged together if there's less than 8 unique materials.
#
# + If there's more than 8 unique materials, everything will be merged into
#   a single surface. Material and custom data will NOT be preserved on the new mesh.
#
static func get_merged_meshes_from(source: Node) -> MeshInstance3D:
	if not source:
		return null

	# Do not alter the source node, use a duplicate instead.
	var node: Node = source.duplicate(0)
	if node is Node3D:
		node.transform = Transform3D()

	# Get all the mesh instances
	var mesh_instances: Array[MeshInstance3D] = get_all_mesh_instances_from(node)
	if mesh_instances.is_empty():
		return null

	# Only one mesh instance found, no merge required.
	# TODO: Uncomment these two lines once we find a way to make surface material
	# overrides play nicely with a single mesh and instancing.
	# For now, this means meshes will always be duplicated in each scenes, which is bad.
#	if mesh_instances.size() == 1:
#		return mesh_instances[0]

	# Helper lambdas
	var get_material_for_surface = func (mi: MeshInstance3D, idx: int) -> Material:
		if mi.get_material_override():
			return mi.get_material_override()

		if mi.get_surface_override_material(idx):
			return mi.get_surface_override_material(idx)

		if mi.mesh is PrimitiveMesh:
			return mi.mesh.get_material()

		return mi.mesh.surface_get_material(idx)

	# Count how many surfaces / materials there are in the source instances
	var total_surfaces := 0
	var surfaces_map := {}
	# Key: Material
	# data: Array[Dictionary]
	# 	"surface": surface index
	#	"mesh_instance": parent mesh instance

	for mi in mesh_instances:
		if not mi.mesh:
			continue # Should not happen

		# Update the total surface count
		var surface_count = mi.mesh.get_surface_count()
		total_surfaces += surface_count

		# Store surfaces in the material indexed dictionary
		for surface_index in surface_count:
			var material: Material = get_material_for_surface.call(mi, surface_index)
			if not material in surfaces_map:
				surfaces_map[material] = []

			surfaces_map[material].push_back({
				"surface": surface_index,
				"mesh_instance": mi,
			})

	# ------
	# Less than 8 surfaces, merge in a single MeshInstance
	# ------
	if total_surfaces <= 8:
		var array_mesh := ArrayMesh.new()

		for mi in mesh_instances:
			var inverse_transform := mi.transform.affine_inverse()

			for surface_index in mi.mesh.get_surface_count():
				# Retrieve surface data
				var primitive_type = Mesh.PRIMITIVE_TRIANGLES
				var format = 0
				var arrays := mi.mesh.surface_get_arrays(surface_index)
				if mi.mesh is ArrayMesh:
					primitive_type = mi.mesh.surface_get_primitive_type(surface_index)
					format = mi.mesh.surface_get_format(surface_index) # Preserve custom data format

				# Update vertex position based on MeshInstance transform
				var vertex_count = arrays[ArrayMesh.ARRAY_VERTEX].size()
				var vertex: Vector3
				for index in vertex_count:
					vertex = arrays[ArrayMesh.ARRAY_VERTEX][index] * inverse_transform
					arrays[ArrayMesh.ARRAY_VERTEX][index] = vertex

				# Store updated surface data in the new mesh
				array_mesh.add_surface_from_arrays(primitive_type, arrays, [], {}, format)

				# Restore material if any
				var material: Material = get_material_for_surface.call(mi, surface_index)
				array_mesh.surface_set_material(array_mesh.get_surface_count() - 1, material)

		var instance := MeshInstance3D.new()
		instance.mesh = array_mesh
		return instance

	# ------
	# Too many surfaces and materials, merge everything in a single one.
	# ------
	var total_unique_materials := surfaces_map.size()

	if total_unique_materials > 8:
		var surface_tool := SurfaceTool.new()
		surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

		for mi in mesh_instances:
			var mesh : Mesh = mi.mesh
			for surface_i in mesh.get_surface_count():
				surface_tool.append_from(mesh, surface_i, mi.transform)

		var instance = MeshInstance3D.new()
		instance.mesh = surface_tool.commit()
		return instance

	# ------
	# Merge surfaces grouped by their materials
	# ------
	var array_mesh := ArrayMesh.new()

	for material in surfaces_map.keys():
		var surface_tool := SurfaceTool.new()
		surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

		var surfaces: Array = surfaces_map[material]
		for data in surfaces:
			var idx: int = data["surface"]
			var mi: MeshInstance3D = data["mesh_instance"]

			surface_tool.append_from(mi.mesh, idx, mi.transform)

		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_tool.commit_to_arrays())
		array_mesh.surface_set_material(array_mesh.get_surface_count() - 1, material)

	var instance := MeshInstance3D.new()
	instance.mesh = array_mesh
	return instance


static func set_owner_recursive(node: Node, new_owner) -> void:
	node.set_owner(new_owner)

	if not node.get_scene_file_path().is_empty():
		return # Node is an instantiated scene, don't change its children owner.

	for c in node.get_children():
		set_owner_recursive(c, new_owner)
