#!/usr/bin/env python3
"""Generate Fetch.xcodeproj. Deterministic: IDs are derived from names."""
import hashlib, pathlib

def oid(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

IDS = {k: oid(k) for k in [
    "project", "target", "appGroup", "mainGroup", "productRef", "productsGroup",
    "sourcesPhase", "frameworksPhase", "resourcesPhase",
    "projectConfigList", "targetConfigList",
    "projDebug", "projRelease", "targDebug", "targRelease",
    "packageRef", "packageDep", "packageBuildFile",
]}

COMMON = (
    'ALWAYS_SEARCH_USER_PATHS = NO; '
    'CLANG_ENABLE_OBJC_ARC = YES; '
    'ENABLE_HARDENED_RUNTIME = YES; '
    'MACOSX_DEPLOYMENT_TARGET = 26.0; '
    'SDKROOT = macosx; '
    'SWIFT_VERSION = 6.0; '
)
TARGET = (
    'CODE_SIGN_IDENTITY = "-"; '
    'CODE_SIGN_STYLE = Automatic; '
    'COMBINE_HIDPI_IMAGES = YES; '
    'CURRENT_PROJECT_VERSION = 1; '
    'GENERATE_INFOPLIST_FILE = NO; '
    'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; '
    'INFOPLIST_FILE = Fetch/Info.plist; '
    'INFOPLIST_KEY_NSHumanReadableCopyright = ""; '
    'INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities"; '
    'MARKETING_VERSION = 1.0; '
    'PRODUCT_BUNDLE_IDENTIFIER = dev.fetch.Fetch; '
    'PRODUCT_NAME = "$(TARGET_NAME)"; '
    'SWIFT_EMIT_LOC_STRINGS = YES; '
)

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	objectVersion = 77;
	objects = {{
		{IDS['sourcesPhase']} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
		{IDS['frameworksPhase']} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({IDS['packageBuildFile']}, ); runOnlyForDeploymentPostprocessing = 0; }};
		{IDS['resourcesPhase']} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
		{IDS['appGroup']} = {{isa = PBXFileSystemSynchronizedRootGroup; explicitFileTypes = {{}}; explicitFolders = (); path = Fetch; sourceTree = "<group>"; }};
		{IDS['productRef']} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Fetch.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{IDS['productsGroup']} = {{isa = PBXGroup; children = ({IDS['productRef']}, ); name = Products; sourceTree = "<group>"; }};
		{IDS['mainGroup']} = {{isa = PBXGroup; children = ({IDS['appGroup']}, {IDS['productsGroup']}, ); sourceTree = "<group>"; }};
		{IDS['packageRef']} = {{isa = XCLocalSwiftPackageReference; relativePath = FetchKit; }};
		{IDS['packageDep']} = {{isa = XCSwiftPackageProductDependency; productName = FetchKit; }};
		{IDS['packageBuildFile']} = {{isa = PBXBuildFile; productRef = {IDS['packageDep']}; }};
		{IDS['target']} = {{isa = PBXNativeTarget; buildConfigurationList = {IDS['targetConfigList']}; buildPhases = ({IDS['sourcesPhase']}, {IDS['frameworksPhase']}, {IDS['resourcesPhase']}, ); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = ({IDS['appGroup']}, ); name = Fetch; packageProductDependencies = ({IDS['packageDep']}, ); productName = Fetch; productReference = {IDS['productRef']}; productType = "com.apple.product-type.application"; }};
		{IDS['project']} = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2660; LastUpgradeCheck = 2660; }}; buildConfigurationList = {IDS['projectConfigList']}; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = {IDS['mainGroup']}; minimizedProjectReferenceProxies = 1; packageReferences = ({IDS['packageRef']}, ); preferredProjectObjectVersion = 77; productRefGroup = {IDS['productsGroup']}; projectDirPath = ""; projectRoot = ""; targets = ({IDS['target']}, ); }};
		{IDS['projectConfigList']} = {{isa = XCConfigurationList; buildConfigurations = ({IDS['projDebug']}, {IDS['projRelease']}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
		{IDS['targetConfigList']} = {{isa = XCConfigurationList; buildConfigurations = ({IDS['targDebug']}, {IDS['targRelease']}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
		{IDS['projDebug']} = {{isa = XCBuildConfiguration; buildSettings = {{{COMMON}SWIFT_OPTIMIZATION_LEVEL = "-Onone"; }}; name = Debug; }};
		{IDS['projRelease']} = {{isa = XCBuildConfiguration; buildSettings = {{{COMMON}}}; name = Release; }};
		{IDS['targDebug']} = {{isa = XCBuildConfiguration; buildSettings = {{{TARGET}}}; name = Debug; }};
		{IDS['targRelease']} = {{isa = XCBuildConfiguration; buildSettings = {{{TARGET}}}; name = Release; }};
	}};
	rootObject = {IDS['project']};
}}
"""

out = pathlib.Path("Fetch.xcodeproj")
out.mkdir(exist_ok=True)
(out / "project.pbxproj").write_text(pbx)
print(f"wrote {out / 'project.pbxproj'}")
