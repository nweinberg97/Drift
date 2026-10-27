#!/usr/bin/env python3
"""Writes Drift.xcodeproj: the App Store build of Drift.

    python3 scripts/gen-xcodeproj.py

The project uses folder-synchronized groups (Xcode 16 or newer), so new
Swift files under Sources/ are picked up automatically; you only need to
rerun this script to change build settings. CI checks the checked-in
project matches what this script produces.

Two targets:
  DriftCore  static library   Sources/DriftCore  (parsing, timers, schedule)
  Drift      macOS app        Sources/Drift + packaging/AppStore/Resources

Everything you'd tweak lives in SETTINGS below. Signing is Automatic; pick
your team in Xcode (Signing & Capabilities) or set DEVELOPMENT_TEAM here.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SETTINGS = {
    "name": "Drift",                          # product + executable name
    "bundle_id": "com.nweinberg.drift",
    "marketing_version": "1.0",
    "build": "1",
    "deployment_target": "13.0",
    "team": "",                               # e.g. "ABCDE12345"; empty = choose in Xcode
}


def uid(name: str) -> str:
    """Stable 24-hex object IDs, so regenerating doesn't churn the file."""
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


S = SETTINGS
NAME = S["name"]
ids = {k: uid(k) for k in [
    "project", "main_group", "products_group", "config_group",
    "app_ref", "core_ref", "infoplist_ref", "entitlements_ref",
    "grp_app", "grp_core", "grp_res",
    "t_app", "t_core",
    "app_sources", "app_frameworks", "app_resources",
    "core_sources", "core_frameworks",
    "bf_core_lib", "dep_core", "proxy_core",
    "proj_cfgs", "proj_debug", "proj_release",
    "app_cfgs", "app_debug", "app_release",
    "core_cfgs", "core_debug", "core_release",
]}


def settings_block(d: dict, indent: str) -> str:
    out = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            items = "".join(f'{indent}\t\t"{x}",\n' for x in v)
            out.append(f"{indent}\t{k} = (\n{items}{indent}\t);\n")
        else:
            s = str(v)
            needs_quotes = s == "" or any(c in s for c in ' $()-+/,;"@') or not s.replace("_", "").replace(".", "").isalnum()
            out.append(f'{indent}\t{k} = "{s}";\n' if needs_quotes else f"{indent}\t{k} = {s};\n")
    return "".join(out)


project_common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": S["deployment_target"],
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
}
project_debug = {**project_common,
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}
project_release = {**project_common,
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
}
app_common = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_ENTITLEMENTS": "packaging/AppStore/Config/Drift.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": S["build"],
    "DEVELOPMENT_TEAM": S["team"],
    "ENABLE_APP_SANDBOX": "YES",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "packaging/AppStore/Config/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "MARKETING_VERSION": S["marketing_version"],
    "PRODUCT_BUNDLE_IDENTIFIER": S["bundle_id"],
    "PRODUCT_NAME": NAME,
    "SWIFT_EMIT_LOC_STRINGS": "NO",
}
core_common = {
    "CODE_SIGN_STYLE": "Automatic",
    "DEFINES_MODULE": "YES",
    "PRODUCT_NAME": "DriftCore",
    "SKIP_INSTALL": "YES",
}


def config(key, name, d):
    return f"""\t\t{ids[key]} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings_block(d, chr(9) * 3)}\t\t\t}};
\t\t\tname = {name};
\t\t}};
"""


pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
\t\t{ids['bf_core_lib']} /* libDriftCore.a in Frameworks */ = {{isa = PBXBuildFile; fileRef = {ids['core_ref']} /* libDriftCore.a */; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t{ids['proxy_core']} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {ids['project']} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {ids['t_core']};
\t\t\tremoteInfo = DriftCore;
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
\t\t{ids['app_ref']} /* {NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{ids['core_ref']} /* libDriftCore.a */ = {{isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libDriftCore.a; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{ids['infoplist_ref']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{ids['entitlements_ref']} /* Drift.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Drift.entitlements; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
\t\t{ids['grp_app']} /* Drift */ = {{isa = PBXFileSystemSynchronizedRootGroup; name = Drift; path = Sources/Drift; sourceTree = "<group>"; }};
\t\t{ids['grp_core']} /* DriftCore */ = {{isa = PBXFileSystemSynchronizedRootGroup; name = DriftCore; path = Sources/DriftCore; sourceTree = "<group>"; }};
\t\t{ids['grp_res']} /* Resources */ = {{isa = PBXFileSystemSynchronizedRootGroup; name = Resources; path = packaging/AppStore/Resources; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{ids['app_frameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ids['bf_core_lib']} /* libDriftCore.a in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['core_frameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{ids['main_group']} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['grp_app']} /* Drift */,
\t\t\t\t{ids['grp_core']} /* DriftCore */,
\t\t\t\t{ids['grp_res']} /* Resources */,
\t\t\t\t{ids['config_group']} /* Config */,
\t\t\t\t{ids['products_group']} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['config_group']} /* Config */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['infoplist_ref']} /* Info.plist */,
\t\t\t\t{ids['entitlements_ref']} /* Drift.entitlements */,
\t\t\t);
\t\t\tname = Config;
\t\t\tpath = packaging/AppStore/Config;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids['products_group']} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids['app_ref']} /* {NAME}.app */,
\t\t\t\t{ids['core_ref']} /* libDriftCore.a */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{ids['t_app']} /* Drift */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ids['app_cfgs']} /* Build configuration list for PBXNativeTarget "Drift" */;
\t\t\tbuildPhases = (
\t\t\t\t{ids['app_sources']} /* Sources */,
\t\t\t\t{ids['app_frameworks']} /* Frameworks */,
\t\t\t\t{ids['app_resources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{ids['dep_core']} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{ids['grp_app']} /* Drift */,
\t\t\t\t{ids['grp_res']} /* Resources */,
\t\t\t);
\t\t\tname = Drift;
\t\t\tproductName = Drift;
\t\t\tproductReference = {ids['app_ref']} /* {NAME}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t{ids['t_core']} /* DriftCore */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ids['core_cfgs']} /* Build configuration list for PBXNativeTarget "DriftCore" */;
\t\t\tbuildPhases = (
\t\t\t\t{ids['core_sources']} /* Sources */,
\t\t\t\t{ids['core_frameworks']} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{ids['grp_core']} /* DriftCore */,
\t\t\t);
\t\t\tname = DriftCore;
\t\t\tproductName = DriftCore;
\t\t\tproductReference = {ids['core_ref']} /* libDriftCore.a */;
\t\t\tproductType = "com.apple.product-type.library.static";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{ids['project']} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{ids['t_app']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t\t{ids['t_core']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {ids['proj_cfgs']} /* Build configuration list for PBXProject "Drift" */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {ids['main_group']};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {ids['products_group']} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{ids['t_app']} /* Drift */,
\t\t\t\t{ids['t_core']} /* DriftCore */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{ids['app_resources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{ids['app_sources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{ids['core_sources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{ids['dep_core']} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {ids['t_core']} /* DriftCore */;
\t\t\ttargetProxy = {ids['proxy_core']} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{config('proj_debug', 'Debug', project_debug)}{config('proj_release', 'Release', project_release)}{config('app_debug', 'Debug', app_common)}{config('app_release', 'Release', app_common)}{config('core_debug', 'Debug', core_common)}{config('core_release', 'Release', core_common)}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{ids['proj_cfgs']} /* Build configuration list for PBXProject "Drift" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids['proj_debug']} /* Debug */,
\t\t\t\t{ids['proj_release']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{ids['app_cfgs']} /* Build configuration list for PBXNativeTarget "Drift" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids['app_debug']} /* Debug */,
\t\t\t\t{ids['app_release']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{ids['core_cfgs']} /* Build configuration list for PBXNativeTarget "DriftCore" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids['core_debug']} /* Debug */,
\t\t\t\t{ids['core_release']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {ids['project']} /* Project object */;
}}
"""

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ids['t_app']}"
               BuildableName = "{NAME}.app"
               BlueprintName = "Drift"
               ReferencedContainer = "container:Drift.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ids['t_app']}"
            BuildableName = "{NAME}.app"
            BlueprintName = "Drift"
            ReferencedContainer = "container:Drift.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

proj = os.path.join(ROOT, "Drift.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(proj, "project.pbxproj"), "w") as f:
    f.write(pbx)
with open(os.path.join(proj, "xcshareddata", "xcschemes", "Drift.xcscheme"), "w") as f:
    f.write(scheme)
print(f"Wrote {proj}")
