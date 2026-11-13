#!/usr/bin/env python3
import argparse
import hashlib
import json
import plistlib
import re
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

parser = argparse.ArgumentParser(description="Generate a standard, shared-scheme Xcode project without requiring XcodeGen.")
parser.add_argument("--development-language", default="en",
                    help="Unused; the project language is always English.")
OPTIONS = parser.parse_args()
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(key_name, isa, **values):
    key = uid(key_name)
    objects[key] = {"isa": isa, **values}
    return key

def build(name, settings):
    return add(name, "XCBuildConfiguration", buildSettings=settings, name=name.rsplit("/", 1)[-1])

def configs(name, base, release_extra=None):
    debug = build(name + "/Debug", {**base, "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ONLY_ACTIVE_ARCH": "YES", "ENABLE_TESTABILITY": "YES"})
    release = build(name + "/Release", {**base, "SWIFT_OPTIMIZATION_LEVEL": "-O", **(release_extra or {})})
    return add(name + "/ConfigList", "XCConfigurationList", buildConfigurations=[debug, release], defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

app_id = uid("AppTarget")
app_product = add("AppProduct", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="iPadn.app", sourceTree="BUILT_PRODUCTS_DIR")
app_files, sources = [], []
for path in sorted((ROOT / "iPadn").rglob("*.swift")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
    app_files.append(reference)
    sources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
for path in sorted((ROOT / "iPadn").rglob("*.c")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="sourcecode.c.c", path=relative, sourceTree="<group>")
    app_files.append(reference)
    sources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
for path in sorted((ROOT / "iPadn").rglob("*.m")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="sourcecode.c.objc", path=relative, sourceTree="<group>")
    app_files.append(reference)
    sources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
for path in sorted((ROOT / "iPadn").rglob("*.h")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="sourcecode.c.h", path=relative, sourceTree="<group>")
    app_files.append(reference)
resources = []
for path, file_type in [("Resources/SAPRuntime", "folder"), ("Resources/Assets.xcassets", "folder.assetcatalog"), ("Resources/PrivacyInfo.xcprivacy", "text.xml"), ("Resources/app-name-directory.json", "text.json")]:
    reference = add("File/" + path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="<group>")
    app_files.append(reference)
    resources.append(add("Build/" + path, "PBXBuildFile", fileRef=reference))
ALTERNATE_ICONS = ["AppIconAuto", "AppIconFlat", "AppIconLight", "AppIconDark", "AppIconFlatLight", "AppIconFlatDark"]
for path in sorted((ROOT / "iPadn/Resources/AlternateIcons").glob("*.png")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="image.png", path=relative, sourceTree="<group>")
    app_files.append(reference)
    resources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
app_files.append(add("InfoPlist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
package = add("ZIPFoundation", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/weichsel/ZIPFoundation.git",
              requirement={"kind": "exactVersion", "version": "0.9.20"})
app_package = add("ZIPFoundation/App", "XCSwiftPackageProductDependency", package=package, productName="ZIPFoundation")
app_framework = add("ZIPFoundation/AppBuild", "PBXBuildFile", productRef=app_package)
app_group = add("AppGroup", "PBXGroup", children=app_files, path="iPadn", sourceTree="<group>")
products = add("Products", "PBXGroup", children=[app_product], name="Products", sourceTree="<group>")
root_group = add("MainGroup", "PBXGroup", children=[app_group, products], sourceTree="<group>")
app_sources = add("AppSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=sources, runOnlyForDeploymentPostprocessing="0")
app_resources = add("AppResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
app_frameworks = add("AppFrameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[app_framework], runOnlyForDeploymentPostprocessing="0")
assemble = add("AssembleWASM", "PBXShellScriptBuildPhase", buildActionMask="2147483647", files=[],
               inputPaths=["$(SRCROOT)/scripts/assemble_runtime.py", "$(SRCROOT)/vendor/SAPRuntime"],
               outputPaths=["$(SRCROOT)/iPadn/Resources/SAPRuntime/" + name for name in ["sap.wasm", "index.html", "sap-signer.js", "wasm_exec.js", "unicorn_x86.js", "libCoreADI.so", "libstoreservicescore.so"]],
               name="Verify local signing runtime", runOnlyForDeploymentPostprocessing="0", shellPath="/bin/bash",
               shellScript='set -euo pipefail\npython3 "$SRCROOT/scripts/assemble_runtime.py"\n', alwaysOutOfDate="1")
base = {"IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17", "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
project_configs = configs("Project", base, {"SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
app_settings = {"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadn", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "INFOPLIST_FILE": "iPadn/Info.plist",
                "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": "1.9.2", "CURRENT_PROJECT_VERSION": "27",
                "SWIFT_EMIT_LOC_STRINGS": "YES", "SWIFT_OBJC_BRIDGING_HEADER": "iPadn/iPadn-Bridging-Header.h",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                "ENABLE_PREVIEWS": "YES", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                "IPADN_MACPKG_LDFLAGS": "",
                "IPADN_NATIVE_LDFLAGS": "",
                "OTHER_LDFLAGS": ["$(inherited)", "-weak_framework", "Translation", "$(IPADN_MACPKG_LDFLAGS)", "$(IPADN_NATIVE_LDFLAGS)"]}
app_configs = configs("App", app_settings)
add("AppTarget", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[assemble, app_sources, app_frameworks, app_resources],
    buildRules=[], dependencies=[], name="iPadn", packageProductDependencies=[app_package], productName="iPadn",
    productReference=app_product, productType="com.apple.product-type.application")
extension_id = uid("ExtensionTarget")
extension_product = add("ExtensionProduct", "PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex="0", path="iPadnLiveActivity.appex", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(extension_product)
extension_files, extension_sources = [], []
for path in sorted((ROOT / "iPadnLiveActivity").glob("*.swift")):
    reference = add("ExtensionFile/" + path.name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
    extension_files.append(reference)
    extension_sources.append(add("ExtensionBuild/" + path.name, "PBXBuildFile", fileRef=reference))
extension_files.append(add("ExtensionInfoPlist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
extension_resources = add("ExtensionResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
objects[root_group]["children"].append(add("ExtensionGroup", "PBXGroup", children=extension_files, path="iPadnLiveActivity", sourceTree="<group>"))
extension_phase = add("ExtensionSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=extension_sources, runOnlyForDeploymentPostprocessing="0")
extension_settings = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadn.LiveActivity", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                      "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "INFOPLIST_FILE": "iPadnLiveActivity/Info.plist",
                      "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": app_settings["MARKETING_VERSION"],
                      "CURRENT_PROJECT_VERSION": app_settings["CURRENT_PROJECT_VERSION"], "SKIP_INSTALL": "YES",
                      "APPLICATION_EXTENSION_API_ONLY": "YES",
                      "SWIFT_EMIT_LOC_STRINGS": "YES",
                      "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]}
extension_configs = configs("Extension", extension_settings)
add("ExtensionTarget", "PBXNativeTarget", buildConfigurationList=extension_configs, buildPhases=[extension_phase, extension_resources], buildRules=[], dependencies=[],
    name="iPadnLiveActivity", productName="iPadnLiveActivity", productReference=extension_product,
    productType="com.apple.product-type.app-extension")
extension_proxy = add("ExtensionProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType="1", remoteGlobalIDString=extension_id, remoteInfo="iPadnLiveActivity")
objects[app_id]["dependencies"].append(add("ExtensionDependency", "PBXTargetDependency", target=extension_id, targetProxy=extension_proxy))
embed = add("EmbedExtension", "PBXBuildFile", fileRef=extension_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
objects[app_id]["buildPhases"].append(add("EmbedExtensions", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="",
    dstSubfolderSpec="13", files=[embed], name="Embed Foundation Extensions", runOnlyForDeploymentPostprocessing="0"))
project_id = add("Project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "1", "LastUpgradeCheck": "1600",
    "TargetAttributes": {app_id: {"CreatedOnToolsVersion": "16.0"}}},
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en",
    hasScannedForEncodings="0", knownRegions=["en", "Base"], mainGroup=root_group, productRefGroup=products,
    projectDirPath="", projectRoot="", targets=[app_id, extension_id], packageReferences=[package])

def render(value, indent=0):
    tab = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + render(str(k)) + " = " + render(v, indent + 1) + ";\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + render(v, indent + 1) + ",\n" for v in value) + tab + ")"
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_.]+", text) else json.dumps(text, ensure_ascii=False)

project = {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project_id}
directory = ROOT / "iPadn.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(project) + "\n")

scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
build_action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build_action, "BuildActionEntries")
def buildable(parent, ident, name, product):
    return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=ident,
                         BuildableName=product, BlueprintName=name, ReferencedContainer="container:iPadn.xcodeproj")
entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
buildable(entry, app_id, "iPadn", "iPadn.app")
ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn", shouldUseLaunchSchemeArgsEnv="YES", shouldAutocreateTestPlan="YES")
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), app_id, "iPadn", "iPadn.app")
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), app_id, "iPadn", "iPadn.app")
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
ET.indent(scheme)
scheme_dir = directory / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "iPadn.xcscheme").write_bytes(ET.tostring(scheme, encoding="utf-8", xml_declaration=True))
workspace = directory / "project.xcworkspace"
workspace.mkdir(exist_ok=True)
(workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')

info = {"CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleDisplayName": "iPadn", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True, "UILaunchScreen": {}, "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "CFBundleURLTypes": [{"CFBundleURLName": "app.local.iPadn", "CFBundleURLSchemes": ["ipadn"]}],
        "LSApplicationQueriesSchemes": ["itms-services"],
        "UIBackgroundModes": ["fetch", "audio"], "BGTaskSchedulerPermittedIdentifiers": ["app.local.iPadn.update-check"],
        "NSSupportsLiveActivities": True,
        "CADisableMinimumFrameDurationOnPhone": True,
        "CFBundleIcons": {"CFBundleAlternateIcons": {name: {"CFBundleIconFiles": [name + "60x60"], "UIPrerenderedIcon": False}
                                                    for name in ALTERNATE_ICONS}},
        "CFBundleIcons~ipad": {"CFBundleAlternateIcons": {name: {"CFBundleIconFiles": [name + "60x60", name + "76x76", name + "83x83"], "UIPrerenderedIcon": False}
                                                         for name in ALTERNATE_ICONS}},
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "IPA Package", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
                                   "LSItemContentTypes": ["com.apple.itunes.ipa", "public.zip-archive"]}],
        "UTImportedTypeDeclarations": [{"UTTypeIdentifier": "com.apple.itunes.ipa", "UTTypeDescription": "iOS App Archive",
                                        "UTTypeConformsTo": ["public.zip-archive"], "UTTypeTagSpecification": {"public.filename-extension": ["ipa"]}}],
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True,
                                    "NSExceptionDomains": {"127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}}},
        "NSLocalNetworkUsageDescription": "Loads signing resources and serves installation packages over this device's loopback address, finds this device's installation service, and, when you turn on Wi-Fi Transfer, offers packages to computers on the same network.",
        "NSFaceIDUsageDescription": "Unlocks iPadn with Face ID.",
        "NSBonjourServices": ["_remotepairing._tcp", "_remotepairing-pairable-host._tcp"]}
(ROOT / "iPadn/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
privacy = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
           "NSPrivacyAccessedAPITypes": [
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPITypeReasons": ["85F4.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]}
           ]}
(ROOT / "iPadn/Resources/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy, sort_keys=False))
print(f"Generated {directory.name}: {len(sources)} app sources, {len(objects)} project objects")
