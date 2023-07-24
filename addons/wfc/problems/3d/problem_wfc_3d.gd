extends WFCProblem

class_name WFC3DProblem

class WFC3DProblemSettings extends Resource:
	@export
	var rules: WFCRules3D

	@export
	var rect: AABB

var rules: WFCRules3D
var map: Node
var rect: AABB

var renderable_rect: AABB

var axes: Array[Vector3i] = []
var axis_matrices: Array[WFCBitMatrix] = []

func _init(settings: WFC3DProblemSettings, map_: Node):
	assert(settings.rules.mapper != null)
	assert(settings.rules.mapper.supports_map(map_))
	assert(settings.rules.mapper.size() > 0)
	assert(settings.rect.has_volume())

	map = map_
	rules = settings.rules
	rect = settings.rect
	renderable_rect = settings.rect

	for i in range(rules.axes.size()):
		axes.append(rules.axes[i])
		axis_matrices.append(rules.axis_matrices[i])

		axes.append(-rules.axes[i])
		axis_matrices.append(rules.axis_matrices[i].transpose())

# encode 3d coords to single int id
func coord_to_id(coord: Vector3i) -> int:
	return (rect.size.y * rect.size.x * coord.z) + (rect.size.x * coord.y) + coord.x
# decode int id to 3d coords
func id_to_coord(id: int) -> Vector3i:
	var szx: int = rect.size.x
	var szy: int = rect.size.y
	var half_decoded: int = id % (szx*szy)
	@warning_ignore("integer_division")
	return Vector3i(half_decoded % szx, half_decoded / szx, id / (szx*szy))

func get_cell_count() -> int:
	return rect.get_volume()

func get_default_domain() -> WFCBitSet:
	return WFCBitSet.new(rules.mapper.size(), true)

func populate_initial_state(state: WFCSolverState):
	var mapper: WFCMapper3D = rules.mapper

	for x in range(rect.size.x):
		for y in range(rect.size.y):
			for z in range(rect.size.z):
				var pos: Vector3i = Vector3i(x, y, z)
				# TODO check that the truncation of rect.position does not generate problems 
				var cell: int = mapper.read_cell(map, pos + Vector3i(rect.position))
				
				if cell >= 0:
					state.set_solution(coord_to_id(pos), cell)

func compute_cell_domain(state: WFCSolverState, cell_id: int) -> WFCBitSet:
	var res: WFCBitSet = state.cell_domains[cell_id].copy()
	var pos: Vector3i = id_to_coord(cell_id)
	
	for i in range(axes.size()):
		var other_pos: Vector3i = pos + axes[i]
		
		# TODO check that the truncation of rect.position does not generate problems 
		if not rect.has_point(other_pos + Vector3i(rect.position)):
			continue
		
		var other_id: int = coord_to_id(other_pos)
		
		if state.cell_solution_or_entropy[other_id] == WFCSolverState.CELL_SOLUTION_FAILED:
			continue

		var other_domain: WFCBitSet = state.cell_domains[other_id]
		res.intersect_in_place(axis_matrices[i].transform(other_domain))

	return res


func mark_related_cells(changed_cell_id: int, mark_cell: Callable):
	var pos: Vector3i = id_to_coord(changed_cell_id)
	
	for i in range(axes.size()):
		var other_pos: Vector3i = pos + axes[i]
		if rect.has_point(other_pos + Vector3i(rect.position)):
			mark_cell.call(coord_to_id(other_pos))

func render_state_to_map(state: WFCSolverState):
	assert(rect.encloses(renderable_rect))
	var mapper: WFCMapper3D = rules.mapper
	
	var render_rect_offset = renderable_rect.position - rect.position

	for x in range(renderable_rect.size.x):
		for y in range(renderable_rect.size.y):
			for z in range(renderable_rect.size.z):
				var local_coord: Vector3i = Vector3i(x, y, z) + render_rect_offset
				var cell: int = state.cell_solution_or_entropy[coord_to_id(local_coord)]
				
				if cell == WFCSolverState.CELL_SOLUTION_FAILED:
					cell = -1

				mapper.write_cell(
					map,
					local_coord + Vector3i(rect.position),
					cell
				)


func get_dependencies_range() -> Vector3i:
	var rx: int = 0
	var ry: int = 0
	var rz: int = 0
	
	for a in axes:
		rx = max(rx, abs(a.x))
		ry = max(ry, abs(a.y))
		rz = max(rz, abs(a.z))
	
	return Vector3i(rx, ry, rz)

func _split_range(first: int, size: int, partitions: int, min_partition_size: int) -> PackedInt64Array:
	assert(partitions > 0)

	@warning_ignore("integer_division")
	var approx_partition_size: int = size / partitions

	if approx_partition_size < min_partition_size:
		return _split_range(first, size, partitions - 1, min_partition_size)

	var res: PackedInt64Array = []

	for partition in range(partitions):
		@warning_ignore("integer_division")
		res.append(first + (size * partition) / partitions)

	res.append(first + size)

	return res

func split(concurrency_limit: int) -> Array[SubProblem]:
	if concurrency_limit < 2:
		return super.split(concurrency_limit)
	
	var rects: Array[AABB] = []
	
	var dependency_range: Vector3i = get_dependencies_range()
	var overlap_min: Vector3i = dependency_range / 2
	var overlap_max: Vector3i = overlap_min + dependency_range % 2

	var influence_range: Vector3i = rules.get_influence_range()
	var extra_overlap: Vector3i = Vector3i(0, 0, 0)

	var may_split_x: bool = influence_range.x < rect.size.x
	var may_split_y: bool = influence_range.y < rect.size.y
	var may_split_z: bool = influence_range.z < rect.size.z
	
	var split_x_overhead: int = influence_range.x * rect.size.y
	var split_y_overhead: int = influence_range.y * rect.size.x
	# TODO understand what this should be
	var split_z_overhead: int = influence_range.y * rect.size.x

	if may_split_x and ((not may_split_y) or (split_x_overhead <= split_y_overhead)):
		extra_overlap.x = influence_range.x * 2

		var partitions: PackedInt64Array = _split_range(
			rect.position.x,
			rect.size.x,
			concurrency_limit * 2,
			dependency_range.x + extra_overlap.x * 2
		)

		for i in range(partitions.size() - 1):
			rects.append(Rect2i(
				partitions[i],
				rect.position.x,
				partitions[i + 1] - partitions[i],
				rect.size.y
			))
	elif may_split_y and ((not may_split_x) or (split_y_overhead <= split_x_overhead)):
		extra_overlap.y = influence_range.y * 2

		var partitions: PackedInt64Array = _split_range(
			rect.position.y,
			rect.size.y,
			concurrency_limit * 2,
			dependency_range.y + extra_overlap.y * 2
		)

		for i in range(partitions.size() - 1):
			rects.append(Rect2i(
				rect.position.x,
				partitions[i],
				rect.size.x,
				partitions[i + 1] - partitions[i]
			))
	else:
		print_debug("Could not split the problem. influence_range=", influence_range, ", overhead_x=", split_x_overhead, ", overhead_y=", split_y_overhead)
		return super.split(concurrency_limit)

	if rects.size() < 3:
		print_debug("Could not split problem. produced_rects=", rects)
		return super.split(concurrency_limit)

	var res: Array[SubProblem] = []

	for i in range(rects.size()):
		var sub_renderable_rect: Rect2i = rects[i] \
			.grow_individual(overlap_min.x, overlap_min.y, overlap_max.x, overlap_max.y) \
			.intersection(rect)
		
		var sub_rect: Rect2i = sub_renderable_rect

		if (i & 1) == 0:
			sub_rect = sub_rect \
				.grow_individual(
					extra_overlap.x, extra_overlap.y,
					extra_overlap.x, extra_overlap.y
				) \
				.intersection(rect)

		var sub_settings: WFC3DProblemSettings = WFC3DProblemSettings.new()
		sub_settings.rules = rules
		sub_settings.rect = sub_rect

		var sub_problem: WFC3DProblem = WFC3DProblem.new(sub_settings, map)
		sub_problem.renderable_rect = sub_renderable_rect
		
		var dependencies: PackedInt64Array = []

		if (i & 1) == 1:
			if i > 0:
				dependencies.append(i - 1)
			
			if i < (rects.size() - 1):
				dependencies.append(i + 1)

		res.append(SubProblem.new(sub_problem, dependencies))

	return res








