import os, uuid
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "BreezeTTS-iOS", "Sources")
def uid(s): return uuid.uuid5(uuid.NAMESPACE_DNS, s).hex[:24].upper()
files = sorted(f for f in os.listdir(SRC) if f.endswith(".swift"))
file_refs, build_files, group_children = [], [], []
for f in files:
    rid, bid = uid("file:"+f), uid("bf:"+f)
    file_refs.append(f'\t\t{rid} /* {f} */ = {{isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
    build_files.append(f'\t\t{bid} /* {f} */ = {{isa = PBXBuildFile; fileRef = {rid} /* {f} */; }};')
    group_children.append(f'{rid} /* {f} */')

info_id, prod_id, group_id, main_id = uid("info"), uid("prod"), uid("grp"), uid("main")
src_id, fw_id, res_id = uid("srcphase"), uid("fwphase"), uid("resphase")
target_id, proj_id = uid("target"), uid("proj")
t_bcl, t_dbg, t_rel = uid("tbcl"), uid("tdbg"), uid("trel")
p_bcl, p_dbg, p_rel = uid("pbcl"), uid("pdbg"), uid("prel")

def block(ident, settings, name):
    lines = "".join(f'\n\t\t\t\t{k} = {v};' for k, v in settings)
    return f'''\t\t{ident} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{lines}
\t\t\t}};
\t\t\tname = {name};
\t\t}};
'''

proj_dbg = block(p_dbg, [("ALWAYS_SEARCH_USER_PATHS","NO"),("IPHONEOS_DEPLOYMENT_TARGET","17.0"),("SDKROOT","iphoneos"),("SWIFT_VERSION","5.9"),("TARGETED_DEVICE_FAMILY","1")], "Debug")
proj_rel = block(p_rel, [("ALWAYS_SEARCH_USER_PATHS","NO"),("IPHONEOS_DEPLOYMENT_TARGET","17.0"),("SDKROOT","iphoneos"),("SWIFT_VERSION","5.9"),("TARGETED_DEVICE_FAMILY","1")], "Release")
common_target = [
    ("PRODUCT_BUNDLE_IDENTIFIER",'"com.breezespeak.app"'),
    ("PRODUCT_NAME",'"BreezeTTS"'),
    ("DEVELOPMENT_TEAM","6S7H7VW64C"),
    ("CODE_SIGN_STYLE","Automatic"),
    ("CODE_SIGN_IDENTITY",'"Apple Development"'),
    ("OTHER_SWIFT_FLAGS",'"-disable-sandbox"'),
    ("INFOPLIST_FILE",'"BreezeTTS-iOS/Info.plist"'),
    ("LD_RUNPATH_SEARCH_PATHS",'"@executable_path/Frameworks"'),
    ("SWIFT_EMIT_LOC_STRINGS","YES"),
    ("TARGETED_DEVICE_FAMILY","1"),
    ("IPHONEOS_DEPLOYMENT_TARGET","17.0"),
    ("SDKROOT","iphoneos"),
    ("SWIFT_VERSION","5.9"),
]
t_dbg_b = block(t_dbg, common_target, "Debug")
t_rel_b = block(t_rel, common_target, "Release")

pbx = f'''// !$*UTF8*$!
{{
\tobjectVersion = 56;
\tobjects = {{
/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
\t\t{info_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{prod_id} /* BreezeTTS.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = BreezeTTS.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{fw_id} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{main_id} = {{isa = PBXGroup; children = ({group_id}, {prod_id}); sourceTree = "<group>"; }};
\t\t{group_id} /* Sources */ = {{isa = PBXGroup; children = ({info_id}, {", ".join(group_children)}); path = BreezeTTS-iOS/Sources; sourceTree = SOURCE_ROOT; }};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{target_id} = {{isa = PBXNativeTarget; buildConfigurationList = {t_bcl}; buildPhases = ({src_id}, {fw_id}, {res_id}); buildRules = (); dependencies = (); name = BreezeTTSiOS; productName = BreezeTTSiOS; productReference = {prod_id}; productType = "com.apple.product-type.application"; }};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{proj_id} = {{isa = PBXProject; attributes = {{ LastSwiftUpdateCheck = 1600; }}; buildConfigurationList = {p_bcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (zh, en, Base); mainGroup = {main_id}; targetAttributes = {{ {target_id} = {{}}; }}; targets = ({target_id}); }};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{res_id} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{src_id} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(f'{uid("bf:"+f)} /* {f} */' for f in files)}); runOnlyForDeploymentPostprocessing = 0; }};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{proj_dbg}{proj_rel}{t_dbg_b}{t_rel_b}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{t_bcl} = {{isa = XCConfigurationList; buildConfigurations = ({t_dbg}, {t_rel}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
\t\t{p_bcl} = {{isa = XCConfigurationList; buildConfigurations = ({p_dbg}, {p_rel}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
/* End XCConfigurationList section */
\t}};
\trootObject = {proj_id};
}}
'''
os.makedirs(os.path.join(ROOT, "BreezeTTS-iOS.xcodeproj"), exist_ok=True)
open(os.path.join(ROOT, "BreezeTTS-iOS.xcodeproj", "project.pbxproj"), "w").write(pbx)
print("written")
