#!/usr/bin/env python3
"""Generate BreezeTTS.xcodeproj/project.pbxproj without Xcode or XcodeGen.

The project is small and flat, so a deterministic generator is easier to review
than a hand-edited pbxproj. Run it whenever files are added or removed:

    python3 scripts/gen_project.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_NAME = "BreezeTTS"


def uid(*parts):
    return hashlib.md5("::".join(parts).encode("utf-8")).hexdigest()[:24].upper()


def rel(path):
    return os.path.relpath(path, ROOT)


def walk_sources():
    """Returns {group: [(filename, full_path)]} for compileable sources."""
    groups = {"Core": [], "Bridge": [], "Services": [], "Models": [], "UI": [], "App": []}
    base = os.path.join(ROOT, PROJECT_NAME)
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in sorted(filenames):
            if not (name.endswith(".swift") or name.endswith(".mm") or name.endswith(".m")):
                continue
            full = os.path.join(dirpath, name)
            parent = os.path.basename(dirpath)
            key = parent if parent in groups else "App"
            groups[key].append((name, full))
    return {k: v for k, v in groups.items() if v}


def walk_resources():
    base = os.path.join(ROOT, PROJECT_NAME, "Resources")
    out = []
    if os.path.isdir(base):
        for name in sorted(os.listdir(base)):
            full = os.path.join(base, name)
            if name.endswith(".icns") or name.endswith(".png") or name.endswith(".json"):
                out.append((name, full))
            elif os.path.isdir(full) and name == "llama-bin":
                # 听书/对话用的 llama.cpp 子进程 + 依赖库，整体作为 folder
                # reference 拷进 Resources/llama-bin，StoryAnalyzer 从那里找。
                out.append((name, full))
    return out


def walk_headers():
    base = os.path.join(ROOT, PROJECT_NAME)
    out = []
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in sorted(filenames):
            if name.endswith(".h"):
                out.append((name, os.path.join(dirpath, name)))
    return out


def main():
    sources = walk_sources()
    headers = walk_headers()
    resources = walk_resources()

    dylib = os.path.join(ROOT, "Vendor", "libbreeze.dylib")
    vendor_header = os.path.join(ROOT, "Vendor", "include", "breeze", "breeze.h")
    info_plist = os.path.join(ROOT, PROJECT_NAME, "Info.plist")

    # --- ids -----------------------------------------------------------------
    project_id = uid("project")
    target_id = uid("target")
    product_id = uid("product")
    main_group = uid("group", "main")
    products_group = uid("group", "products")
    app_group = uid("group", "app")
    vendor_group = uid("group", "vendor")
    frameworks_group = uid("group", "frameworks")

    src_phase = uid("phase", "sources")
    fw_phase = uid("phase", "frameworks")
    res_phase = uid("phase", "resources")
    embed_phase = uid("phase", "embed")

    proj_cfg_list = uid("cfglist", "project")
    target_cfg_list = uid("cfglist", "target")

    file_refs = []
    build_files = []

    def add_source(name, path, compile_it=True):
        ref = uid("fileref", path)
        file_refs.append((ref, name, os.path.dirname(rel(path)), "sourcecode"))
        if compile_it:
            bf = uid("buildfile", path)
            build_files.append((bf, ref, name))
        return ref

    # Sources
    group_children = {}
    for group, files in sources.items():
        children = []
        for name, path in files:
            ref = add_source(name, path)
            children.append(ref)
        group_children[group] = children

    # Headers (visible, not compiled)
    header_children = []
    for name, path in headers:
        ref = uid("fileref", path)
        file_refs.append((ref, name, os.path.dirname(rel(path)), "sourcecode"))
        header_children.append(ref)
    group_children.setdefault("Bridge", []).extend(header_children)

    resource_build_files = []
    resource_children = []
    for name, path in resources:
        ref = uid("fileref", path)
        kind = "folder" if os.path.isdir(path) else "resource"
        file_refs.append((ref, name, "BreezeTTS/Resources", kind))
        bf = uid("buildfile", path)
        resource_build_files.append((bf, ref, name))
        resource_children.append(ref)

    plist_ref = uid("fileref", info_plist)
    file_refs.append((plist_ref, "Info.plist", rel(os.path.dirname(info_plist)), "text.plist"))

    dylib_ref = uid("fileref", dylib)
    file_refs.append((dylib_ref, "libbreeze.dylib", "Vendor", "compiled.mach-o.dylib"))
    dylib_build = uid("buildfile", dylib)
    build_files.append((dylib_build, dylib_ref, "libbreeze.dylib"))
    dylib_embed = uid("buildfile", dylib + "::embed")

    vendor_hdr_ref = uid("fileref", vendor_header)
    file_refs.append((vendor_hdr_ref, "breeze.h", "Vendor/include/breeze", "sourcecode"))

    # --- emit ----------------------------------------------------------------
    out = []
    w = out.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")
    w("")

    # PBXBuildFile
    w("/* Begin PBXBuildFile section */")
    for bf, ref, name in build_files:
        w(f"\t\t{bf} /* {name} in Sources/Frameworks */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
    for bf, ref, name in resource_build_files:
        w(f"\t\t{bf} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
    w(f"\t\t{dylib_embed} /* libbreeze.dylib in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {dylib_ref} /* libbreeze.dylib */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};")
    w("/* End PBXBuildFile section */")
    w("")

    # PBXCopyFilesBuildPhase
    w("/* Begin PBXCopyFilesBuildPhase section */")
    w(f"\t\t{embed_phase} /* Embed Frameworks */ = {{")
    w("\t\t\tisa = PBXCopyFilesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w(f"\t\t\tfiles = (\n\t\t\t\t{dylib_embed} /* libbreeze.dylib in Embed Frameworks */,\n\t\t\t);")
    w("\t\t\tname = \"Embed Frameworks\";")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t\tdstPath = \"\";")
    w("\t\t\tdstSubfolderSpec = 10;")
    w("\t\t};")
    w("/* End PBXCopyFilesBuildPhase section */")
    w("")

    # PBXFileReference
    w("/* Begin PBXFileReference section */")
    for ref, name, dirpath, kind in file_refs:
        if kind == "text.plist":
            w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = \"{name}\"; sourceTree = \"<group>\"; }};")
        elif kind == "folder":
            w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = \"{name}\"; sourceTree = \"<group>\"; }};")
        elif kind == "resource":
            ftype = "image.icns" if name.endswith(".icns") else ("image.png" if name.endswith(".png") else "text.json")
            w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = \"{name}\"; sourceTree = \"<group>\"; }};")
        elif kind == "compiled.mach-o.dylib":
            w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = \"compiled.mach-o.dylib\"; path = \"{name}\"; sourceTree = \"<group>\"; }};")
        else:
            filetype = "sourcecode.cpp.objcpp" if name.endswith(".mm") else \
                       ("sourcecode.c.objc" if name.endswith(".m") else
                        ("sourcecode.c.h" if name.endswith(".h") else "sourcecode.swift"))
            w(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype}; path = \"{name}\"; sourceTree = \"<group>\"; }};")
    w(f"\t\t{product_id} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"{PROJECT_NAME}.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};")
    w("/* End PBXFileReference section */")
    w("")

    # PBXFrameworksBuildPhase
    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{fw_phase} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w(f"\t\t\tfiles = (\n\t\t\t\t{dylib_build} /* libbreeze.dylib in Frameworks */,\n\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")
    w("")

    # PBXGroup
    w("/* Begin PBXGroup section */")

    order = ["App", "Core", "Bridge", "Services", "Models", "UI"]
    app_children = []
    for group in order:
        if group not in group_children or not group_children[group]:
            continue
        if group == "App":
            app_children.extend(group_children[group])
        else:
            gid = uid("group", group)
            app_children.append(gid)

    if resource_children:
        gid = uid("group", "Resources")
        app_children.append(gid)
        w(f"\t\t{gid} /* Resources */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for child in resource_children:
            w(f"\t\t\t\t{child},")
        w("\t\t\t);")
        w("\t\t\tpath = Resources;")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")

    w(f"\t\t{main_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{app_group} /* {PROJECT_NAME} */,")
    w(f"\t\t\t\t{vendor_group} /* Vendor */,")
    w(f"\t\t\t\t{frameworks_group} /* Frameworks */,")
    w(f"\t\t\t\t{products_group} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{app_group} /* {PROJECT_NAME} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for child in app_children:
        w(f"\t\t\t\t{child},")
    w(f"\t\t\t\t{plist_ref} /* Info.plist */,")
    w("\t\t\t);")
    w(f"\t\t\tpath = {PROJECT_NAME};")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    for group in order:
        if group == "App" or group not in group_children or not group_children[group]:
            continue
        gid = uid("group", group)
        w(f"\t\t{gid} /* {group} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for child in group_children[group]:
            w(f"\t\t\t\t{child},")
        w("\t\t\t);")
        w(f"\t\t\tpath = {group};")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")

    w(f"\t\t{vendor_group} /* Vendor */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{dylib_ref} /* libbreeze.dylib */,")
    w(f"\t\t\t\t{vendor_hdr_ref} /* breeze.h */,")
    w("\t\t\t);")
    w("\t\t\tpath = Vendor;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{frameworks_group} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w("\t\t\t);")
    w("\t\t\tname = Frameworks;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{products_group} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{product_id} /* {PROJECT_NAME}.app */,")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("/* End PBXGroup section */")
    w("")

    # PBXNativeTarget
    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{target_id} /* {PROJECT_NAME} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {target_cfg_list} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{src_phase} /* Sources */,")
    w(f"\t\t\t\t{fw_phase} /* Frameworks */,")
    w(f"\t\t\t\t{res_phase} /* Resources */,")
    w(f"\t\t\t\t{embed_phase} /* Embed Frameworks */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w(f"\t\t\tname = {PROJECT_NAME};")
    w(f"\t\t\tproductName = {PROJECT_NAME};")
    w(f"\t\t\tproductReference = {product_id} /* {PROJECT_NAME}.app */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")
    w("")

    # PBXProject
    w("/* Begin PBXProject section */")
    w(f"\t\t{project_id} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    w("\t\t\t\tLastUpgradeCheck = 1600;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target_id} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {proj_cfg_list} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = zh_CN;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t\t\"zh-Hans\",")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group};")
    w(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target_id} /* {PROJECT_NAME} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")

    # PBXResourcesBuildPhase
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{res_phase} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for bf, ref, name in resource_build_files:
        w(f"\t\t\t\t{bf} /* {name} in Resources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")
    w("")

    # PBXSourcesBuildPhase
    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{src_phase} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for bf, ref, name in build_files:
        if name == "libbreeze.dylib":
            continue
        w(f"\t\t\t\t{bf} /* {name} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")
    w("")

    # XCBuildConfiguration
    common_target = """\t\t\t\tCODE_SIGN_IDENTITY = "-";
\t\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_APP_SANDBOX = NO;
\t\t\t\tENABLE_HARDENED_RUNTIME = NO;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;
\t\t\t\tHEADER_SEARCH_PATHS = (
\t\t\t\t\t"$(SRCROOT)/Vendor/include",
\t\t\t\t);
\t\t\t\tINFOPLIST_FILE = BreezeTTS/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tLIBRARY_SEARCH_PATHS = (
\t\t\t\t\t"$(SRCROOT)/Vendor",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 2.0.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.breezespeak.mac;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = "BreezeTTS/Bridge/BreezeTTS-Bridging-Header.h";
\t\t\t\tSWIFT_VERSION = 5.0;
"""

    project_debug = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tOTHER_SWIFT_FLAGS = "-disable-sandbox";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
"""

    project_release = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tOTHER_SWIFT_FLAGS = "-disable-sandbox";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
"""

    proj_debug_id = uid("cfg", "project", "Debug")
    proj_release_id = uid("cfg", "project", "Release")
    tgt_debug_id = uid("cfg", "target", "Debug")
    tgt_release_id = uid("cfg", "target", "Release")

    w("/* Begin XCBuildConfiguration section */")
    w(f"\t\t{proj_debug_id} /* Debug */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    out.append(project_debug.rstrip("\n"))
    w("\t\t\t};")
    w("\t\t\tname = Debug;")
    w("\t\t};")

    w(f"\t\t{proj_release_id} /* Release */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    out.append(project_release.rstrip("\n"))
    w("\t\t\t};")
    w("\t\t\tname = Release;")
    w("\t\t};")

    for cid, name in ((tgt_debug_id, "Debug"), (tgt_release_id, "Release")):
        w(f"\t\t{cid} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        out.append(common_target.rstrip("\n"))
        w("\t\t\t\tARCHS = (\n\t\t\t\t\tarm64,\n\t\t\t\t\tx86_64,\n\t\t\t\t);")
        if name == "Debug":
            w("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
        else:
            w("\t\t\t\tONLY_ACTIVE_ARCH = NO;")
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    w("/* End XCBuildConfiguration section */")
    w("")

    # XCConfigurationList
    w("/* Begin XCConfigurationList section */")
    w(f"\t\t{proj_cfg_list} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{proj_debug_id} /* Debug */,")
    w(f"\t\t\t\t{proj_release_id} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w(f"\t\t{target_cfg_list} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{tgt_debug_id} /* Debug */,")
    w(f"\t\t\t\t{tgt_release_id} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("")

    w("\t};")
    w(f"\trootObject = {project_id} /* Project object */;")
    w("}")

    project_dir = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")
    os.makedirs(project_dir, exist_ok=True)
    with open(os.path.join(project_dir, "project.pbxproj"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")

    print(f"wrote {rel(os.path.join(project_dir, 'project.pbxproj'))} "
          f"({len(file_refs)} refs, {len(build_files)} build files)")


if __name__ == "__main__":
    main()
