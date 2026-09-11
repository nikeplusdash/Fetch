# The meadow for Fetch's landing page, rendered with Cycles.
#
#   /Applications/Blender.app/Contents/MacOS/Blender -b -P meadow.py -- <pass> <scale> <out>
#
# Passes: full | clouds | grass
#
# **Cycles, not EEVEE.** The references are soft-lit renders whose realism
# lives in three places EEVEE approximates at best: clouds that scatter light
# through their volume, grass that is actual fibres with translucency, and the
# gentle bounce of green up into every shadow. All three come from the path
# tracer for free.
import bpy
import sys
import math
import random

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
PASS = argv[0] if argv else "full"
SCALE = float(argv[1]) if len(argv) > 1 else 1.0
OUT = argv[2] if len(argv) > 2 else f"/tmp/meadow-{PASS}"

random.seed(20260812)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"

# Metal GPU if the machine has one; CPU silently otherwise.
prefs = bpy.context.preferences.addons.get("cycles")
if prefs:
    cprefs = prefs.preferences
    try:
        cprefs.compute_device_type = "METAL"
        cprefs.get_devices()
        for device in cprefs.devices:
            device.use = True
        scene.cycles.device = "GPU"
    except Exception:
        scene.cycles.device = "CPU"

scene.cycles.samples = 128
scene.cycles.use_denoising = True
# **The clouds are white because of this line.** Cycles ships with zero volume
# bounces, which is single scattering, which renders any optically thick cloud
# as charcoal — a real cumulus is white precisely because light ricochets
# through it dozens of times.
scene.cycles.volume_bounces = 12
scene.cycles.transparent_max_bounces = 24
scene.render.film_transparent = True
# Filmic, not AgX and not Standard: AgX washes saturated greens to mint, and
# Standard clips a physical sun into a white frame. Filmic keeps the vivid
# albedo the references have while still rolling the highlights off.
scene.view_settings.view_transform = "Filmic"
for look in ("Medium High Contrast", "Filmic - Medium High Contrast"):
    try:
        scene.view_settings.look = look
        break
    except TypeError:
        pass
scene.view_settings.exposure = -0.25


def principled(name, base, roughness=0.9):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = base
    bsdf.inputs["Roughness"].default_value = roughness
    return mat, bsdf


# ── sky and sun ──────────────────────────────────────────────────────────
world = bpy.data.worlds.new("Sky")
scene.world = world
world.use_nodes = True
nodes, links = world.node_tree.nodes, world.node_tree.links
nodes.clear()
coord = nodes.new("ShaderNodeTexCoord")
separate = nodes.new("ShaderNodeSeparateXYZ")
# Generated on a world background is the ray direction; its Z is how far up
# the ray points, -1 straight down to +1 straight up.
remap = nodes.new("ShaderNodeMapRange")
remap.inputs["From Min"].default_value = -0.05
remap.inputs["From Max"].default_value = 0.55
ramp = nodes.new("ShaderNodeValToRGB")
# Horizon to zenith: pale, then honest blue.
ramp.color_ramp.elements[0].position = 0.0
ramp.color_ramp.elements[0].color = (0.74, 0.91, 0.98, 1)
ramp.color_ramp.elements[1].position = 1.0
ramp.color_ramp.elements[1].color = (0.145, 0.48, 0.86, 1)
# Two skies: the one the camera photographs and the one that lights the
# scene. An art-directed gradient at photographic strength is far too dim to
# be the world's light source, and turning it up would blow the gradient to
# white — so diffuse rays get a 4x brighter copy and camera rays get the
# pretty one.
bg = nodes.new("ShaderNodeBackground")
bg.inputs["Strength"].default_value = 1.15
bg_light = nodes.new("ShaderNodeBackground")
bg_light.inputs["Strength"].default_value = 4.5
light_path = nodes.new("ShaderNodeLightPath")
mix = nodes.new("ShaderNodeMixShader")
out = nodes.new("ShaderNodeOutputWorld")
links.new(coord.outputs["Generated"], separate.inputs["Vector"])
links.new(separate.outputs["Z"], remap.inputs["Value"])
links.new(remap.outputs["Result"], ramp.inputs["Fac"])
links.new(ramp.outputs["Color"], bg.inputs["Color"])
links.new(ramp.outputs["Color"], bg_light.inputs["Color"])
links.new(light_path.outputs["Is Camera Ray"], mix.inputs["Fac"])
links.new(bg_light.outputs[0], mix.inputs[1])
links.new(bg.outputs[0], mix.inputs[2])
links.new(mix.outputs[0], out.inputs[0])

# The sun the sky texture used to bring with it.
sun_data = bpy.data.lights.new("Sun", type="SUN")
sun_data.energy = 7.0
sun_data.angle = math.radians(3)
sun_data.color = (1.0, 0.97, 0.90)
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(50), 0, math.radians(140))

# ── the ground, furred ───────────────────────────────────────────────────
# One landscape, one hair system. The near field is individual blades and the
# far hills dissolve into velvet on their own, which is exactly what happens
# to real grass with distance — no separate "far material" to keep in step.
bpy.ops.mesh.primitive_grid_add(x_subdivisions=260, y_subdivisions=260, size=560)
ground = bpy.context.object
ground.name = "Ground"
for poly in ground.data.polygons:
    poly.use_smooth = True

for label, size, strength, depth in (
        ("Landform", 120.0, 46.0, 2), ("Rolls", 38.0, 7.0, 3), ("Undulation", 9.0, 0.9, 2)):
    tex = bpy.data.textures.new(label, type="CLOUDS")
    tex.noise_scale = size
    tex.noise_depth = depth
    mod = ground.modifiers.new(label, "DISPLACE")
    mod.texture = tex
    mod.strength = strength
    mod.mid_level = 0.5
    mod.texture_coords = "GLOBAL"

soil_mat, soil_bsdf = principled("Soil", (0.05, 0.16, 0.015, 1), roughness=1.0)
ground.data.materials.append(soil_mat)

# Blades: translucent towards the sun, yellowing at the tip like the
# references, darker at the root where blades shade each other.
blade_mat = bpy.data.materials.new("Blade")
blade_mat.use_nodes = True
btree = blade_mat.node_tree
bnodes = btree.nodes
bnodes.clear()
info = bnodes.new("ShaderNodeHairInfo")
ramp = bnodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = (0.030, 0.11, 0.012, 1)     # root, in shade
ramp.color_ramp.elements[0].position = 0.0
mid = ramp.color_ramp.elements.new(0.62)
mid.color = (0.10, 0.27, 0.03, 1)
ramp.color_ramp.elements[-1].color = (0.27, 0.42, 0.06, 1)      # sunlit tip
bsdf = bnodes.new("ShaderNodeBsdfPrincipled")
bsdf.inputs["Roughness"].default_value = 0.7
translucent = bnodes.new("ShaderNodeBsdfTranslucent")
mix = bnodes.new("ShaderNodeMixShader")
mix.inputs["Fac"].default_value = 0.10
boutput = bnodes.new("ShaderNodeOutputMaterial")
btree.links.new(info.outputs["Intercept"], ramp.inputs["Fac"])
btree.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
btree.links.new(ramp.outputs["Color"], translucent.inputs["Color"])
btree.links.new(bsdf.outputs[0], mix.inputs[1])
btree.links.new(translucent.outputs[0], mix.inputs[2])
btree.links.new(mix.outputs[0], boutput.inputs[0])
ground.data.materials.append(blade_mat)

ground.modifiers.new("Fur", "PARTICLE_SYSTEM")
psys = ground.particle_systems[0]
settings = psys.settings
settings.type = "HAIR"
settings.count = 60000
settings.hair_length = 1.7
settings.hair_step = 3
settings.child_type = "INTERPOLATED"
settings.child_percent = 40
settings.rendered_child_count = 40
settings.child_length = 1.0
settings.clump_factor = 0.35
settings.roughness_1 = 0.35
settings.roughness_1_size = 1.4
settings.roughness_endpoint = 0.28
settings.material_slot = "Blade"
if hasattr(settings, "radius_scale"):
    settings.radius_scale = 0.03
    settings.root_radius = 1.0
    settings.tip_radius = 0.05
    settings.shape = 0.1

# ── daisies ──────────────────────────────────────────────────────────────
# One flower, instanced. Petals as a fan of squashed spheres reads fine at
# this size; what matters is the white dot pattern the references scatter
# through the foreground.
petal_mat, _ = principled("Petal", (0.95, 0.95, 0.92, 1), roughness=0.6)
centre_mat, _ = principled("Centre", (0.9, 0.62, 0.08, 1), roughness=0.5)

bpy.ops.mesh.primitive_uv_sphere_add(radius=0.09, location=(9999, 9999, 0))
head = bpy.context.object
head.name = "DaisyHead"
head.scale = (1, 1, 0.45)
head.data.materials.append(centre_mat)
petals = [head]
for n in range(8):
    a = n / 8 * math.tau
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=0.11, location=(9999 + math.cos(a) * 0.2, 9999 + math.sin(a) * 0.2, -0.01))
    petal = bpy.context.object
    petal.scale = (1.4, 0.55, 0.18)
    petal.rotation_euler = (0, 0, a)
    petal.data.materials.append(petal_mat)
    petals.append(petal)
bpy.ops.object.select_all(action="DESELECT")
for petal in petals:
    petal.select_set(True)
bpy.context.view_layer.objects.active = petals[0]
bpy.ops.object.join()
daisy = bpy.context.object
daisy.name = "Daisy"

ground.modifiers.new("Daisies", "PARTICLE_SYSTEM")
dsys = ground.particle_systems[1]
dsettings = dsys.settings
dsettings.type = "HAIR"
dsettings.count = 420
dsettings.use_advanced_hair = True
dsettings.render_type = "OBJECT"
dsettings.instance_object = daisy
dsettings.particle_size = 0.62
dsettings.size_random = 0.45
dsettings.count = 650
dsettings.use_rotations = True
dsettings.rotation_mode = "GLOB_Z"
dsettings.phase_factor_random = 2.0

# ── clouds, as volumes ───────────────────────────────────────────────────
# A displaced sphere bounding a Principled Volume. This is what gives the
# bright rims and the soft grey underside the references have — geometry with
# subsurface reads as wet stone instead.
def cloud_volume(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (1, 1, 1, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    for key, value in (("Subsurface Weight", 1.0),):
        if key in bsdf.inputs:
            bsdf.inputs[key].default_value = value
    if "Subsurface Radius" in bsdf.inputs:
        bsdf.inputs["Subsurface Radius"].default_value = (6.0, 5.5, 5.0)
    if "Subsurface Scale" in bsdf.inputs:
        bsdf.inputs["Subsurface Scale"].default_value = 1.0
    return mat

clouds = []
for index, (cx, cy, cz, base) in enumerate([
    (-70, 150, 48, 15),
    (55, 190, 62, 20),
    (185, 140, 40, 11),
    (-160, 240, 74, 17),
]):
    lobes = []
    # A wide flat base with lobes riding on top, biggest near the middle —
    # the construction every cumulus in the reference shows.
    for n, (dx, dy, dz, r) in enumerate([
        (0, 0, 0, 1.9), (-1.6, 0.2, 0.25, 1.25), (1.5, -0.1, 0.3, 1.35),
        (-0.7, 0.4, 0.85, 1.05), (0.6, -0.3, 0.95, 1.15), (0.1, 0.5, 1.15, 0.85),
        (2.6, 0.1, 0.1, 0.8), (-2.6, -0.2, 0.05, 0.7),
    ]):
        bpy.ops.mesh.primitive_uv_sphere_add(
            segments=32, ring_count=16,
            radius=base * r * 0.55,
            location=(cx + dx * base * 0.55, cy + dy * base * 0.55, cz + dz * base * 0.5))
        lobes.append(bpy.context.object)
    bpy.ops.object.select_all(action="DESELECT")
    for lobe in lobes:
        lobe.select_set(True)
    bpy.context.view_layer.objects.active = lobes[0]
    bpy.ops.object.join()
    cloud = bpy.context.object
    cloud.name = f"Cloud{index}"
    # Squash vertically and shave the underside flat.
    cloud.scale = (1.0, 0.9, 0.62)
    bpy.ops.object.transform_apply(scale=True)
    lump = bpy.data.textures.new(f"Lump{index}", type="CLOUDS")
    lump.noise_scale = 9.0
    lump.noise_depth = 2
    mod = cloud.modifiers.new("Lump", "DISPLACE")
    mod.texture = lump
    mod.strength = base * 0.17
    mod.texture_coords = "GLOBAL"
    for poly in cloud.data.polygons:
        poly.use_smooth = True
    cloud.data.materials.append(cloud_volume(f"CloudVol{index}"))
    clouds.append(cloud)

# ── camera ───────────────────────────────────────────────────────────────
cam_data = bpy.data.cameras.new("Camera")
cam_data.lens = 35
cam_data.dof.use_dof = True
cam_data.dof.focus_distance = 60
cam_data.dof.aperture_fstop = 5.6
camera = bpy.data.objects.new("Camera", cam_data)
scene.collection.objects.link(camera)
scene.camera = camera
camera.location = (0, -150, 9.0)
camera.rotation_euler = (math.radians(90.5), 0, 0)

# ── passes ───────────────────────────────────────────────────────────────
if PASS == "clouds":
    ground.hide_render = True
    daisy.hide_render = True
    bg.inputs["Strength"].default_value = 0.0
    cam_data.dof.use_dof = False
elif PASS == "grass":
    for cloud in clouds:
        cloud.hide_render = True
    bg.inputs["Strength"].default_value = 0.8

# Blender 5: the compositor is its own datablock, not scene.node_tree.
comp = bpy.data.node_groups.new("Grade", "CompositorNodeTree")
scene.compositing_node_group = comp
comp.nodes.clear()
layers = comp.nodes.new("CompositorNodeRLayers")
hsv = comp.nodes.new("CompositorNodeHueSat")
hsv.inputs["Saturation"].default_value = 1.26
contrast = comp.nodes.new("CompositorNodeBrightContrast")
contrast.inputs["Contrast"].default_value = 4.0
# Blender 5 again: no Composite node — a compositor group ends at a group
# output socket instead.
comp.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
composite = comp.nodes.new("NodeGroupOutput")
comp.links.new(layers.outputs["Image"], hsv.inputs["Image"])
comp.links.new(hsv.outputs["Image"], contrast.inputs["Image"])
comp.links.new(contrast.outputs["Image"], composite.inputs[0])

width, height = (2000, 1200) if PASS == "full" else (1800, 700)
scene.render.resolution_x = int(width * SCALE)
scene.render.resolution_y = int(height * SCALE)
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
print(f"RENDERED {PASS} -> {scene.render.filepath}.png at "
      f"{scene.render.resolution_x}x{scene.render.resolution_y}")
