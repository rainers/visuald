#!/usr/bin/env python3
"""
visuald2vcxproj.py -- convert a Visual D ".visualdproj" into a native MSBuild ".vcxproj".

The conversion is driven by three sources of truth in the repository:

  visuald/config.d                 the option model and the command lines Visual D builds
  msbuild/dmd.xml, msbuild/ldc.xml the DCompile property vocabulary of the MSBuild rules
  msbuild/dcompile_defaults.props  the defaults a vcxproj inherits for DCompile

Usage:
    python tools/visuald2vcxproj.py <project.visualdproj> [options]

Options:
    --out DIR          write <name>.vcxproj (+ .filters) into DIR (default: project dir)
    --name NAME        project name (default: file name without extension)
    --sln FILE         solution used to resolve project references
                       (default: the closest .sln above the project)
    --project-refs     emit <ProjectReference> instead of spelling out the outputs and
                       import paths of the referenced projects
    --keep-defaults    also emit metadata that equals the inherited default
    --no-filters       do not write the .vcxproj.filters file
    --no-native-tools  keep .idl/.rc custom steps as CustomBuild instead of upgrading
                       them to the Midl / ResourceCompile tools
    --dry-run          report only, write nothing
    --report FILE      also write the conversion report to FILE
"""
import argparse
import io
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET


# --------------------------------------------------------------------- small helpers

def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def flag(v):
    """Visual D stores booleans as 0/1 (and sometimes as an empty string)."""
    return (v or "").strip() not in ("", "0")


def as_int(v, default=0):
    try:
        return int((v or "").strip())
    except ValueError:
        return default


def words(s):
    """Split a whitespace separated option list, honouring "quoted" entries."""
    out, cur, quoted = [], "", False
    for ch in s or "":
        if ch == '"':
            quoted = not quoted
        elif ch in " \t\n\r" and not quoted:
            if cur:
                out.append(cur)
                cur = ""
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def normpath(p):
    """Normalize a Windows path that may still contain $(Macros)."""
    p = (p or "").replace("/", "\\")
    p = re.sub(r"(^|\\)\.($|\\)", r"\1", p)
    p = re.sub(r"\\{2,}", r"\\", p)
    return p


def normalize_macro_path(p):
    """Collapse "." and redundant separators in a path that may contain macros.

    A ".." is only folded away when the component before it is a plain folder
    name, so "$(ProjectDir)..\\..\\bin" survives.
    """
    p = (p or "").replace("/", "\\")
    for macro in TRAILING_SEP_MACROS:
        p = re.sub(r"(\$\(%s\))\\" % macro, r"\1", p, flags=re.I)
    parts = []
    for part in re.split(r"\\+", p):
        if part in ("", "."):
            continue
        if part == ".." and parts and parts[-1] != ".." \
                and not parts[-1].startswith("$(") and ":" not in parts[-1]:
            parts.pop()
            continue
        parts.append(part)
    return "\\".join(parts)


def substitute(s, env):
    """Replace $(Macro) occurrences by their value in env (case insensitive)."""
    for _ in range(6):
        prev = s
        for name, value in env.items():
            if value is None:
                continue
            s = re.sub(r"\$\(%s\)" % re.escape(name), lambda m, v=value: str(v), s, flags=re.I)
        if s == prev:
            break
    return s


def ci_dict(items):
    """Key a dict by the lower-cased key, for keys that are strings."""
    return {(k.lower() if isinstance(k, str) else k): v for k, v in items.items()}


MACRO_RE = re.compile(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)")

# MSBuild macros whose value already ends in a backslash, while the Visual D macro of the
# same name does not: "x$(OutDir)\foo" therefore has to become "x$(OutDir)foo".
TRAILING_SEP_MACROS = {
    "outdir", "intdir", "projectdir", "solutiondir", "inputdir", "targetdir",
    "vcinstalldir", "vctoolsinstalldir", "vsinstalldir", "devenvdir", "windowsdkdir",
    "dmdbindir", "ldcbindir", "userrootdir", "vctargetspath", "extensiondir", "projectpath",
}

# Macros a visualdproj uses that a vcxproj spells differently.
MACRO_ALIASES = ci_dict({
    "safeprojectname": "ProjectName",
    "fulloutdir": "OutDir",
    "fullintdir": "IntDir",
    "universalcrtsdkdir": "WindowsSdkDir",
    "windowsdkversion": "WindowsTargetPlatformVersion",
    # The C++ toolset defines $(Configuration) and $(Platform); the "...Name" spellings
    # the visualdproj uses are only defined by the Visual D rules inside the IDE.
    "configurationname": "Configuration",
    "platformname": "Platform",
})

# Macros that have no counterpart in a vcxproj.
MACRO_LOSSY = ci_dict({
    "visualdinstalldir": "the Visual D installation folder is not an MSBuild property",
    "cc": "the C++ compiler of the Visual D options is not an MSBuild property",
})

# Macros the custom build step understands; everywhere else they have to be spelled out.
INPUT_MACROS = {"inputpath", "inputname", "inputdir", "inputfilename", "inputext",
                "rootname", "ext", "filename", "filedir"}

# The same macros spelled as the item metadata MSBuild makes available to a custom build
# step, so that the command of the original project keeps working there.
INPUT_MACRO_METADATA = ci_dict({
    "inputpath": "%(Identity)",
    "inputfilename": "%(Filename)%(Extension)",
    "inputname": "%(Filename)",
    "rootname": "%(Filename)",
    "filename": "%(Filename)",
    "inputext": "%(Extension)",
    "ext": "%(Extension)",
    "inputdir": "%(RelativeDir)",
    "filedir": "%(RelativeDir)",
})


def escape_newlines(s):
    """Spell the line breaks of a multi line command as the escapes MSBuild turns back into
    newlines.  An XML parser folds the breaks of the element text into single spaces, so
    writing them out literally would run all command lines as one."""
    return re.sub(r"\r\n|\r|\n", "%0D%0A", s)


def translate_macros(s, report, where, custom=False):
    """Rewrite Visual D macros into their MSBuild spelling."""
    if s and "$" in s:
        for name, target in MACRO_ALIASES.items():
            s = re.sub(r"\$\(\s*%s\s*\)" % name, "$(" + target + ")", s, flags=re.I)
        for name in sorted(set(MACRO_RE.findall(s))):
            lossy = MACRO_LOSSY.get(name.lower())
            if lossy:
                report.lossy("%s: $(%s) %s" % (where, name, lossy))
            elif name.lower() in INPUT_MACROS and not custom:
                report.lossy("%s: $(%s) is only expanded by a custom build step" % (where, name))
        # drop the backslash the visualdproj writes after macros that carry one already
        s = re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)(\\\\|\\)",
                   lambda m: "$(" + m.group(1) + ")"
                             if m.group(1).lower() in TRAILING_SEP_MACROS else m.group(0),
                   s)
        if custom:
            # the input macros name the file the build step runs on
            s = re.sub(MACRO_RE,
                       lambda m: INPUT_MACRO_METADATA.get(m.group(1).lower(), m.group(0)), s)
    if custom:
        s = escape_newlines(s)
    return s


# --------------------------------------------------------------------- report

class Report:
    def __init__(self):
        self._lossy = []
        self._unsupported = []
        self._ignored = []
        self.notes = []

    def _add(self, bucket, msg):
        if msg not in bucket:
            bucket.append(msg)

    def lossy(self, msg):
        self._add(self._lossy, msg)

    def unsupported(self, msg):
        self._add(self._unsupported, msg)

    def ignored(self, msg):
        self._add(self._ignored, msg)

    def note(self, msg):
        self._add(self.notes, msg)

    def dump(self, stream=sys.stdout):
        for title, items in (("unsupported", self._unsupported), ("lossy", self._lossy),
                             ("ignored", self._ignored), ("notes", self.notes)):
            if not items:
                continue
            print("%s:" % title.upper(), file=stream)
            for m in items:
                print("  - %s" % m, file=stream)
            print(file=stream)

    def text(self):
        buf = io.StringIO()
        self.dump(buf)
        return buf.getvalue()


# --------------------------------------------------------------------- msbuild defaults

def msbuild_condition(cond, env):
    """Evaluate the subset of MSBuild conditions used by dcompile_defaults.props."""
    if not cond:
        return True

    def expand(text):
        text = text.strip()
        if text.startswith("'") and text.endswith("'"):
            text = text[1:-1]
        if "$" in text:
            text = MACRO_RE.sub(lambda mm: env.get(mm.group(1).lower(), ""), text)
        return text

    for part in re.split(r"\s+and\s+", cond):
        part = part.strip()
        if not part:
            continue
        m = re.match(r"^(.+?)\s*(==|!=)\s*(.+)$", part)
        if not m:
            return False
        lhs, rhs = expand(m.group(1)), expand(m.group(3))
        eq = lhs.casefold() == rhs.casefold()
        if (m.group(2) == "==") != eq:
            return False
    return True


MSB_NS = "{http://schemas.microsoft.com/developer/msbuild/2003}"


def load_dcompile_defaults(msbuild_dir):
    """[(name, value, condition)] of the DCompile ItemDefinitionGroup."""
    path = os.path.join(msbuild_dir, "dcompile_defaults.props")
    root = ET.parse(path).getroot()
    out = []
    for group in root.findall(MSB_NS + "ItemDefinitionGroup"):
        for item in group:
            for prop in item:
                out.append((prop.tag.replace(MSB_NS, ""), (prop.text or "").strip(),
                            prop.get("Condition")))
    return out


def load_rule_properties(msbuild_dir):
    """{property name: rule element} the MSBuild rules define for DCompile."""
    names = {}
    for rule in ("dmd.xml", "ldc.xml"):
        path = os.path.join(msbuild_dir, rule)
        if os.path.exists(path):
            for node in ET.parse(path).getroot().iter():
                if node.tag.endswith("Property") and node.get("Name"):
                    tag = node.tag.split("}", 1)[-1]
                    names.setdefault(node.get("Name"), tag)
    return names


# --------------------------------------------------------------------- visualdproj

class Config:
    def __init__(self, elem):
        self.name = elem.get("name")
        self.platform = elem.get("platform") or "Win32"
        self.v = {}
        for ch in elem:
            if ch.tag != "Config":
                self.v[ch.tag] = (ch.text or "").strip()

    def get(self, key, default=""):
        return self.v.get(key, default)

    def key(self):
        return "%s|%s" % (self.name, self.platform)

    def compiler(self):
        return {0: "DMD", 1: "GDC", 2: "LDC", 3: "SDC"}.get(as_int(self.get("compiler")), "DMD")

    def is64(self):
        return flag(self.get("isX86_64"))

    def mscoff(self):
        return flag(self.get("mscoff"))

    def output_type(self):
        return as_int(self.get("lib"))          # 0 = executable, 1 = static lib, 2 = dll

    def model(self):
        return as_int(self.get("singleFileCompilation"))


class Project:
    def __init__(self, path, name=None):
        self.path = os.path.abspath(path)
        self.dir = os.path.dirname(self.path) + "\\"
        self.name = name or os.path.splitext(os.path.basename(path))[0]
        self.root = parse_project(path)
        self.guid = (self.root.findtext("ProjectGuid") or "").strip().upper()
        self.configs = [Config(c) for c in self.root.findall("Config")]

    def config(self, key):
        for c in self.configs:
            if c.key() == key:
                return c
        return None


def _walk_up_for(start, test):
    d = os.path.abspath(start)
    while True:
        found = test(d)
        if found:
            return found
        parent = os.path.dirname(d)
        if not parent or parent == d:
            return None
        d = parent


def find_solution(project_dir):
    def test(d):
        for f in sorted(os.listdir(d)):
            if f.lower().endswith(".sln"):
                return os.path.join(d, f)
        return None
    return _walk_up_for(project_dir, test)


def find_msbuild_dir(project_dir):
    def test(d):
        cand = os.path.join(d, "msbuild")
        return cand if os.path.exists(os.path.join(cand, "dmd.xml")) else None
    return _walk_up_for(project_dir, test)


SLN_PROJECT_RE = re.compile(r'^Project\("\{[^}]*\}"\)\s*=\s*"[^"]*",\s*"([^"]*)"')


def read_text(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16")
    if data[:3] == b"\xef\xbb\xbf":
        return data[3:].decode("utf-8", "replace")
    return data.decode("utf-8", "replace")


# A conforming XML parser folds the line breaks inside an attribute value into spaces, and
# ElementTree does not report the original spelling.  The custom build commands the IDE
# writes do have real line breaks, so spell them as character references before parsing.
def tag_newlines(text):
    """Replace the line breaks inside the quoted attribute values of the start tags."""
    out = []
    i, n = 0, len(text)
    in_tag = False
    quote = ""
    while i < n:
        c = text[i]
        if not in_tag:
            if text.startswith("<!--", i) or text.startswith("<![CDATA[", i):
                end = "-->" if text[i + 1:i + 2] == "!" else "]]>"
                j = text.find(end, i)
                j = n if j < 0 else j + len(end)
                out.append(text[i:j])
                i = j
                continue
            out.append(c)
            in_tag = c == "<"
            i += 1
            continue
        if quote:
            if c == quote:
                quote = ""
            elif c in "\r\n":
                if c == "\r" and text[i + 1:i + 2] == "\n":
                    i += 1
                out.append("&#10;")
                i += 1
                continue
        elif c in "\"'":
            quote = c
        elif c == ">":
            in_tag = False
        out.append(c)
        i += 1
    return "".join(out)


XML_DECLARATION_RE = re.compile(r"^\s*<\?xml[^>]*\?>")


def parse_project(path):
    """The root element of a .visualdproj, keeping the line breaks of its attributes."""
    text = tag_newlines(read_text(path))
    return ET.fromstring(XML_DECLARATION_RE.sub("", text, count=1))


def parse_solution(sln_path):
    """Return ({project guid: path}, {project guid: [referenced guid, ...]})."""
    sln_path = os.path.abspath(sln_path)
    projects, deps = {}, {}
    current, in_deps = None, False
    for line in read_text(sln_path).splitlines():
        m = SLN_PROJECT_RE.match(line)
        if m:
            gm = re.search(r"(\{[0-9A-Fa-f-]+\})\"?\s*$", line)
            if gm:
                path = m.group(1).replace("\\", os.sep)
                full = os.path.abspath(os.path.join(os.path.dirname(sln_path), path))
                projects[gm.group(1).upper()] = full
                current = gm.group(1).upper()
            in_deps = False
            continue
        stripped = line.strip()
        if stripped.startswith("ProjectSection(ProjectDependencies)"):
            in_deps = True
            if current:
                deps.setdefault(current, [])
            continue
        if in_deps and stripped == "EndProjectSection":
            in_deps, current = False, None
            continue
        if in_deps and current:
            # "<dependency guid> = <project guid>"
            dm = re.match(r"\{([0-9A-Fa-f-]+)\}", stripped)
            if dm:
                deps[current].append(("{%s}" % dm.group(1)).upper())
    return projects, deps


# --------------------------------------------------------------------- option tables

SUBSYSTEM = ci_dict({1: "Console", 2: "Windows", 3: "Native", 4: "POSIX"})
BOUNDS = ci_dict({0: "", 1: "On", 2: "SafeOnly", 3: "Off"})
CONFIGURATION_TYPE = ci_dict({0: "Application", 1: "StaticLibrary", 2: "DynamicLibrary"})
TARGET_EXT = ci_dict({0: ".exe", 1: ".lib", 2: ".dll"})
DIR_MACRO = {"outdir": "OutDir", "intdir": "IntDir"}

# Visual D boolean option -> DCompile metadata
BOOL_META = [
    ("optimize", "Optimizer"), ("useInline", "Inliner"), ("genStackFrame", "StackFrame"),
    ("stackStomp", "StackStomp"), ("allinst", "AllInst"), ("useUnitTests", "Unittest"),
    ("cov", "Coverage"), ("trace", "Profile"), ("vtls", "ShowTLS"), ("vgc", "ShowGC"),
    ("verbose", "Verbose"), ("ignoreUnsupportedPragmas", "IgnorePragma"),
    ("preservePaths", "PreserveSourcePath"), ("betterC", "BetterC"),
    ("dip25", "DIP25"), ("dip1000", "DIP1000"), ("dip1008", "DIP1008"),
    ("dip1021", "DIP1021"), ("revert_import", "RevertImport"),
    ("transition_field", "TransitionField"),
    ("transition_checkimports", "TransitionCheckImports"),
    ("transition_complex", "TransitionComplex"),
    ("transition_vmarkdown", "TransitionVMarkdown"),
    ("preview_dtorfields", "PreviewDtorFields"),
    ("preview_intpromote", "PreviewIntPromote"),
    ("preview_fixAliasThis", "PreviewFixAliasThis"),
    ("preview_rvaluerefparam", "PreviewRvalueRefParam"),
    ("preview_nosharedaccess", "PreviewNoSharedAccess"),
    ("preview_markdown", "PreviewMarkdown"),
    ("preview_in", "PreviewIn"),
    ("preview_inclincontracts", "PreviewInclusiveInContracts"),
    ("preview_shortenedMethods", "PreviewShortenedMethods"),
]

# options Visual D itself no longer turns into a compiler or linker switch
DEAD_OPTIONS = {s.lower() for s in {
    "obj", "link", "multiobj", "oneobj", "cpu", "scheduler", "pic", "debuglevel",
    "versionlevel", "dump_source", "useAssert", "useInvariants", "useIn", "useOut",
    "useArrayBounds", "useSwitchError", "noboundscheck", "libname",
    "isLinux", "isOSX", "isWindows", "isFreeBSD", "isSolaris",
}}

# options Visual D uses but that a vcxproj cannot express
UNSUPPORTED_OPTIONS = ci_dict({
    "run": "Visual D runs the target after building; a vcxproj has no equivalent",
    "runargs": "see the 'run' option",
    "pauseAfterRunning": "an option of the Visual D run command",
    "debugStdOutToOutputWindow": "an option of the Visual D debugger panel",
    "debugEngine": "the debugger engine is selected by Visual Studio, not by the project",
    "debugremote": "no vcxproj property selects a remote debugger for a D target",
    "filesToClean": "Visual D deletes these on clean; MSBuild uses its own .tlog files",
    "modules_ddoc": "Visual D generates a separate ddoc batch for these modules",
    "ddocfiles": "used by the 'modules_ddoc' option only",
    "moduleDepsFile": "MSBuild tracks module dependencies in its own .tlog files",
    "useStdLibPath": "the MSBuild rules always add the compiler library search path",
    "runCv2pdb": "cv2pdb is not part of the MSBuild build",
    "pathCv2pdb": "cv2pdb is not part of the MSBuild build",
    "cv2pdbNoDemangle": "cv2pdb is not part of the MSBuild build",
    "cv2pdbEnumType": "cv2pdb is not part of the MSBuild build",
    "cv2pdbOptions": "cv2pdb is not part of the MSBuild build",
    "cccmd": "only used to translate C++ sources for GDC",
    "ccTransOpt": "only used to translate C++ sources for GDC",
})

# options that are converted, but not one-to-one
MAPPED_OPTIONS = ci_dict({
    "objname": "DCompile ObjectFileName (it names the object file of the whole project)",
    "resfile": "added to the linker inputs",
    "deffile": "Link ModuleDefinitionFile",
    "mapverbosity": "Link GenerateMapFile (the level itself only matters when dmd links)",
    "createImplib": "Link ImportLibrary",
    "addDepImp": "resolved through the solution into explicit import paths and libraries",
    "privatePhobos": "-defaultlib=<objdir>privatephobos.lib",
    "doXGeneration": "DCompile JSONFile, or a bare -X when no file is given",
    "doDocComments": "DCompile DocDir/DocFile, or a bare -D when neither is given",
    "doHdrGeneration": "DCompile HeaderDir/HeaderFile, or a bare -H when neither is given",
    "preBuildCommand": "PreBuildEvent (runs before every target, not only before linking)",
    "postBuildCommand": "PostBuildEvent",
    "debugtarget": "LocalDebuggerCommand",
    "debugarguments": "LocalDebuggerCommandArguments",
    "debugworkingdir": "LocalDebuggerWorkingDirectory",
    "debugattach": "LocalDebuggerAttach",
    "otherDMD": "DCompile CompilerExe",
    "program": "the compiler executable, taken literally",
    "enableMixin": "DCompile EnableDebugMixin and DebugMixin",
    "singleFileCompilation": "DCompile CompilationModel (and DoNotLink for 'compile only')",
    "mscoff": "DCompile CodeGeneration",
    "compiler": "the DCompiler property",
    "isX86_64": "DCompile CodeGeneration",
    "cRuntime": "the libraries passed to the linker (Visual D never passes -mscrtlib)",
    "subsystem": "Link SubSystem",
    "lib": "the ConfigurationType property",
    "exefile": "TargetName/TargetExt and Link or Lib OutputFile",
    "additionalOptions": "DCompile AdditionalOptions; -L<switch> goes to the linker",
    "linkswitches": "Link AdditionalOptions",
    "symdebug": "DCompile DebugInfo and Link GenerateDebugInformation",
    "warnings": "DCompile Warnings",
    "infowarnings": "DCompile Warnings",
    "useDeprecated": "DCompile Deprecations",
    "errDeprecated": "DCompile Deprecations",
    "release": "DCompile DebugCode",
    "boundscheck": "DCompile BoundsCheck",
    "imppath": "DCompile ImportPaths",
    "fileImppath": "DCompile StringImportPaths",
    "versionids": "DCompile VersionIdentifiers",
    "debugids": "DCompile DebugIdentifiers",
    "outdir": "the OutDir property",
    "objdir": "the IntDir property",
    "objfiles": "Link AdditionalDependencies",
    "libfiles": "Link AdditionalDependencies",
    "libpaths": "Link AdditionalLibraryDirectories",
    "pdbfile": "Link ProgramDatabaseFile",
    "mapfile": "Link MapFileName",
    "impfile": "Link ImportLibrary",
    "quiet": "DCompile AdditionalOptions",
    "nofloat": "DCompile AdditionalOptions",
    "defaultlibname": "DCompile AdditionalOptions -defaultlib=",
    "debuglibname": "DCompile AdditionalOptions -debuglib=",
    "debuglib": "DCompile AdditionalOptions -link-debuglib (LDC only)",
})

KNOWN_OPTIONS = (set(DEAD_OPTIONS) | set(UNSUPPORTED_OPTIONS) | set(MAPPED_OPTIONS)
                 | {s.lower() for s in {
                     "symdebugref", "optimize", "useInline", "genStackFrame", "stackStomp",
                     "allinst", "useUnitTests", "cov", "trace", "vtls", "vgc", "verbose",
                     "ignoreUnsupportedPragmas", "preservePaths", "betterC", "dip25",
                     "dip1000", "dip1008", "dip1021", "revert_import",
                     "transition_field", "transition_checkimports", "transition_complex",
                     "transition_vmarkdown", "preview_dtorfields", "preview_intpromote",
                     "preview_fixAliasThis", "preview_rvaluerefparam",
                     "preview_nosharedaccess", "preview_markdown", "preview_in",
                     "preview_inclincontracts", "preview_shortenedMethods",
                     "docdir", "docname", "hdrdir", "hdrname", "xfilename",
                     "mixinPath", "compiler", "otherDMD"}})

# --------------------------------------------------------------------- converter

class Converter:
    def __init__(self, project, opts, report):
        self.p = project
        self.opts = opts
        self.report = report
        self.defaults = load_dcompile_defaults(opts.msbuild_dir)
        self.rule_props = load_rule_properties(opts.msbuild_dir)
        self.sln_projects, self.sln_deps = {}, {}
        if opts.sln:
            self.sln_projects, self.sln_deps = parse_solution(opts.sln)
        self.items = []          # (itemtype, path, filter, metadata, per-config attributes)
        self.folders = []
        self.def_items = []
        self.res_items = []
        self.outfile = None
        self._env_cache = {}

    # ---------------- macros and paths

    def macro_env(self, proj, cfg):
        """        Return (env, env_abs): env keeps the VC macro spelling, env_abs resolves
        the same macros to absolute paths so that paths can be relativized."""
        # Key on the project file, not its directory: two projects can share a directory
        # (vdc\vdserver and vdc\parser do), and their macros then differ.
        key = (proj.path.lower(), cfg.key())
        if key in self._env_cache:
            return self._env_cache[key]
        base = ci_dict({
            "projectdir": proj.dir,
            "projectname": proj.name,
            "projectext": ".vcxproj", "projectfilename": proj.name + ".vcxproj",
            "msbuildprojectname": proj.name,
            "configuration": cfg.name, "configurationname": cfg.name,
            "platform": cfg.platform, "platformname": cfg.platform,
            "targetname": proj.name,
            "targetext": TARGET_EXT.get(cfg.output_type(), ".exe"),
        })
        if self.opts.sln:
            base["solutiondir"] = os.path.dirname(self.opts.sln)
            base["solutionname"] = os.path.splitext(os.path.basename(self.opts.sln))[0]
            base["solutionext"] = os.path.splitext(self.opts.sln)[1]
            base["solutionfilename"] = os.path.basename(self.opts.sln)
        env = ci_dict(dict(base))
        env_abs = ci_dict(dict(base))
        env_abs["projectdir"] = proj.dir
        if self.opts.sln:
            env_abs["solutiondir"] = os.path.dirname(self.opts.sln)
        # OutDir and IntDir first: IntDir is usually written as $(OutDir)$(Platform)...
        for name, raw in (("outdir", cfg.get("outdir")), ("intdir", cfg.get("objdir"))):
            if not raw:
                continue
            expr = normalize_macro_path(translate_macros(raw, self.report, key))
            if not re.match(r"^(?:[a-zA-Z]:|[\\$])", expr):
                expr = "$(ProjectDir)" + expr
            resolved = substitute(expr, env_abs)
            if not re.match(r"^[a-zA-Z]:[\\/]|^[\\/]", resolved):
                resolved = os.path.join(proj.dir, resolved)
            env_abs[name] = os.path.normpath(resolved) + os.sep
            env[name] = expr + "\\"
        if env_abs.get("outdir"):
            env_abs["targetdir"] = env_abs["outdir"]
            env_abs["targetpath"] = (env_abs["outdir"] + env_abs["targetname"]
                                     + env_abs["targetext"])
        self._env_cache[key] = (env, env_abs)
        return self._env_cache[key]

    def expand(self, s, proj, cfg):
        """Translate macros to their MSBuild spelling, expanding the fixed ones."""
        s = translate_macros(s, self.report, cfg.key())
        env, _ = self.macro_env(proj, cfg)
        return substitute(s, env)

    def macro_path(self, s, proj, cfg):
        """Spell a path as $(OutDir)..., $(IntDir)... or project relative."""
        _, env_abs = self.macro_env(proj, cfg)
        translated = normalize_macro_path(translate_macros(s, self.report, cfg.key()))
        if re.match(r"^\$\((?:OutDir|IntDir|ProjectDir|SolutionDir|TargetDir|TargetPath"
                    r"|TargetName|TargetExt)\)", translated, re.I):
            return translated
        full = substitute(translated, env_abs)
        if "$" in full:
            return translated
        norm = os.path.normpath(full)
        for name in ("intdir", "outdir"):   # IntDir first: it is the more specific base
            base = env_abs.get(name)
            if not base:
                continue
            base = os.path.normpath(base)
            if os.path.normcase(norm).startswith(os.path.normcase(base) + os.sep):
                return "$(%s)" % DIR_MACRO[name] + norm[len(base) + 1:].replace(os.sep, "\\")
        rel = os.path.relpath(norm, proj.dir.rstrip("\\")).replace(os.sep, "\\")
        return rel if rel.startswith("..") else ".\\" + rel

    # ---------------- referenced projects

    def dependency_projects(self, proj, seen):
        out = []
        for guid in self.sln_deps.get(proj.guid, []):
            path = self.sln_projects.get(guid)
            if not path:
                continue
            if not path.lower().endswith(".visualdproj"):
                # a project that has been converted already: fall back to its visualdproj
                alt = os.path.splitext(path)[0] + ".visualdproj"
                if not os.path.exists(alt):
                    self.report.lossy("referenced project %s is not a .visualdproj; its outputs "
                                      "are not added to this project" % os.path.basename(path))
                    continue
                path = alt
            if path in seen:
                continue
            seen.add(path)
            try:
                out.append(Project(path))
            except (OSError, ET.ParseError) as e:
                self.report.lossy("cannot read referenced project %s (%s)" % (path, e))
        return out

    def dependency_import_dirs(self, proj, cfg, seen):
        """getImportsFromDependentProjects(): the directory of every referenced project plus
        its own import paths resolved relative to that project, recursively."""
        imports = []

        def add(path):
            if path and path not in imports:
                imports.append(path)

        base = self.p.dir.rstrip("\\")
        for dep in self.dependency_projects(proj, seen):
            dcfg = dep.config(cfg.key()) or (dep.configs[0] if dep.configs else None)
            if dcfg is None:
                self.report.lossy("%s: referenced project %s has no configuration"
                                  % (cfg.key(), dep.name))
                continue
            dep_dir = dep.dir.rstrip("\\")
            add(os.path.relpath(dep_dir, base).replace(os.sep, "\\"))
            for imp in words(dcfg.get("imppath")):
                full = os.path.normpath(os.path.join(dep_dir, imp))
                add(os.path.relpath(full, base).replace(os.sep, "\\"))
            for rel in self.dependency_import_dirs(dep, dcfg, seen):
                add(rel)
        return imports

    def dependency_outputs(self, proj, cfg, seen):
        """getLibsFromDependentProjects(): the file every referenced project produces."""
        out = []
        for dep in self.dependency_projects(proj, seen):
            dcfg = dep.config(cfg.key()) or (dep.configs[0] if dep.configs else None)
            if dcfg is None:
                continue
            target = dcfg.get("exefile")
            _, dep_abs = self.macro_env(dep, dcfg)
            if not target:
                target = (dep_abs.get("outdir") or dep.dir) + dep.name + \
                         TARGET_EXT.get(dcfg.output_type(), ".exe")
            full = substitute(translate_macros(target, self.report, dcfg.key()), dep_abs)
            if "$" in full:
                self.report.lossy("%s: the target of referenced project %s keeps macros (%s)"
                                  % (cfg.key(), dep.name, target))
                continue
            if not re.match(r"^[a-zA-Z]:[\\/]|^[\\/]", full):
                full = os.path.join(dep.dir, full)
            self.report.note("the file referenced project %s contributes is taken from its "
                             "'exefile' setting; the IDE asks the project for its build outputs"
                             % dep.name)
            out.append((dep, os.path.normpath(full)))
        return out

    # ---------------- per-config groups

    def code_generation(self, cfg):
        compiler = cfg.compiler()
        if compiler not in ("DMD", "LDC"):
            self.report.unsupported("%s: compiler '%s' has no MSBuild rule; the DCompiler "
                                    "property only offers DMD and LDC" % (cfg.key(), compiler))
        if cfg.platform.lower() == "arm64":
            return "ARM64"
        if cfg.is64():
            return "64Bits"
        if compiler == "LDC":
            return "32Bits"
        if not cfg.mscoff():
            self.report.unsupported("%s: DMD for Win32 without mscoff links with optlink, "
                                    "which the MSBuild rules cannot drive; the config is "
                                    "converted as 32-bit MS-COFF" % cfg.key())
        return "32BitsMS-COFF"

    def config_properties(self, cfg):
        compiler = cfg.compiler()
        return [("ConfigurationType", CONFIGURATION_TYPE.get(cfg.output_type(), "Application")),
                ("PlatformToolset", "$(DefaultPlatformToolset)"),
                ("CharacterSet", "Unicode"),
                ("DCompiler", compiler if compiler in ("DMD", "LDC") else "DMD")]

    def debugger_properties(self, cfg):
        out = []
        for src, dst in (("debugtarget", "LocalDebuggerCommand"),
                         ("debugarguments", "LocalDebuggerCommandArguments"),
                         ("debugworkingdir", "LocalDebuggerWorkingDirectory")):
            if cfg.get(src):
                out.append((dst, translate_macros(cfg.get(src), self.report, cfg.key())))
        if "debugattach" in cfg.v:
            out.append(("LocalDebuggerAttach",
                        "true" if flag(cfg.get("debugattach")) else "false"))
        return out

    def target_name_ext(self, cfg):
        """Split 'exefile' into TargetName/TargetExt, plus an OutputFile if needed."""
        exefile = cfg.get("exefile")
        if not exefile:
            return None, None, None
        _, env_abs = self.macro_env(self.p, cfg)
        full = substitute(translate_macros(exefile, self.report, cfg.key()), env_abs)
        if "$" in full:
            return None, None, self.macro_path(exefile, self.p, cfg)
        norm = os.path.normpath(full)
        base, ext = os.path.splitext(os.path.basename(norm))
        # Only spell TargetName/TargetExt out when they differ from what the
        # configuration type gives a vcxproj by default.
        name = None if base.lower() == self.p.name.lower() else base
        default_ext = TARGET_EXT.get(cfg.output_type(), ".exe")
        ext = None if ext.lower() == default_ext.lower() else ext
        outfile = None
        outdir = env_abs.get("outdir")
        if outdir and os.path.normcase(os.path.dirname(norm)) != os.path.normcase(
                os.path.normpath(outdir)):
            outfile = self.macro_path(exefile, self.p, cfg)
        return name, ext, outfile

    def user_properties(self, cfg):
        env, _ = self.macro_env(self.p, cfg)
        props = []
        if cfg.get("outdir"):
            props.append(("OutDir", env["outdir"]))
        if cfg.get("objdir"):
            props.append(("IntDir", env["intdir"]))
        props.append(("LinkIncremental", "false"))  # Visual D links with /INCREMENTAL:NO
        name, ext, outfile = self.target_name_ext(cfg)
        self.outfile = outfile
        if name:
            props.append(("TargetName", name))
        if ext:
            props.append(("TargetExt", ext))
        props.extend(self.debugger_properties(cfg))
        return props

    def dcompile_metadata(self, cfg):
        d = []
        compiler = cfg.compiler()
        d.append(("CodeGeneration", self.code_generation(cfg)))

        if flag(cfg.get("warnings")):
            d.append(("Warnings", "Error"))
        elif flag(cfg.get("infowarnings")):
            d.append(("Warnings", "Info"))
        else:
            d.append(("Warnings", "None"))

        if flag(cfg.get("useDeprecated")):
            d.append(("Deprecations", "Allow"))
        elif flag(cfg.get("errDeprecated")):
            d.append(("Deprecations", "Error"))
        else:
            d.append(("Deprecations", "Info"))

        d.append(("DebugCode", {0: "Debug", 1: "Release", 2: "Default"}
                  .get(as_int(cfg.get("release")), "Default")))
        symdebug = flag(cfg.get("symdebug"))
        d.append(("DebugInfo", "Mago" if symdebug else "None"))
        # dmd only accepts -gf together with -g
        d.append(("DebugFull", "true" if symdebug and flag(cfg.get("symdebugref")) else "false"))
        d.append(("BoundsCheck", BOUNDS.get(as_int(cfg.get("boundscheck")), "")))

        model = cfg.model()
        if model == 4:
            self.report.unsupported("%s: the compilation model 'compile through dub' has no "
                                    "MSBuild equivalent" % cfg.key())
        compile_model = "Project" if model in (0, 4) else "File"
        # Compiling a whole static library into one object file makes the library a single
        # archive member, so linking it pulls in every module's external references.
        # Visual D's own build hands all modules to "dmd -lib", which archives one member per
        # module; keep the project's model and let the compiler do the archiving.
        lib_archive = compile_model == "Project" and cfg.output_type() == 1
        d.append(("CompilationModel", compile_model))
        if model == 3:
            d.append(("DoNotLink", "true"))
            self.report.note("%s: compilation model 'separate compile only' -> DoNotLink=true"
                             % cfg.key())

        for src, meta in BOOL_META:
            if src in cfg.v:
                d.append((meta, "true" if flag(cfg.get(src)) else "false"))

        imps = words(cfg.get("imppath"))
        if flag(cfg.get("addDepImp")):
            if not self.sln_deps.get(self.p.guid):
                self.report.lossy("%s: addDepImp=1 but the solution does not list any project "
                                  "reference of this project" % cfg.key())
            elif not self.opts.project_refs:
                for imp in self.dependency_import_dirs(self.p, cfg, set()):
                    if imp not in imps:
                        imps.append(imp)
        if imps:
            d.append(("ImportPaths", ";".join(translate_macros(i, self.report, cfg.key())
                                              for i in imps)))
        fimps = words(cfg.get("fileImppath"))
        if fimps:
            d.append(("StringImportPaths",
                      ";".join(translate_macros(i, self.report, cfg.key()) for i in fimps)))
        vids = words(cfg.get("versionids"))
        if vids:
            d.append(("VersionIdentifiers",
                      ";".join(translate_macros(i, self.report, cfg.key()) for i in vids)))
        dids = words(cfg.get("debugids"))
        if dids:
            d.append(("DebugIdentifiers",
                      ";".join(translate_macros(i, self.report, cfg.key()) for i in dids)))

        # The rules have no on/off switch for -D, -H and -X, only the -Dd/-Df, -Hd/-Hf and
        # -Xf forms, so a bare switch has to go into AdditionalOptions.
        extra = []
        if flag(cfg.get("doDocComments")):
            if cfg.get("docdir"):
                d.append(("DocDir", translate_macros(cfg.get("docdir"), self.report, cfg.key())))
            if cfg.get("docname"):
                d.append(("DocFile", translate_macros(cfg.get("docname"), self.report, cfg.key())))
            if not cfg.get("docdir") and not cfg.get("docname"):
                extra.append("-D")
        if flag(cfg.get("doHdrGeneration")):
            if cfg.get("hdrdir"):
                d.append(("HeaderDir", translate_macros(cfg.get("hdrdir"), self.report, cfg.key())))
            if cfg.get("hdrname"):
                d.append(("HeaderFile", translate_macros(cfg.get("hdrname"), self.report, cfg.key())))
            if not cfg.get("hdrdir") and not cfg.get("hdrname"):
                extra.append("-H")
        if flag(cfg.get("doXGeneration")):
            if cfg.get("xfilename"):
                d.append(("JSONFile", translate_macros(cfg.get("xfilename"),
                                                       self.report, cfg.key())))
            else:
                extra.append("-X")
        if flag(cfg.get("enableMixin")):
            d.append(("EnableDebugMixin", "true"))
            if cfg.get("mixinPath"):
                d.append(("DebugMixin", translate_macros(cfg.get("mixinPath"),
                                                         self.report, cfg.key())))
        if cfg.get("objname"):
            d.append(("ObjectFileName", translate_macros(cfg.get("objname"),
                                                         self.report, cfg.key())))

        if lib_archive:
            # The compiler archives one object per module rather than the Lib tool collecting
            # the single object file the combined model produces.
            extra.append("-lib")
            self.report.note("%s: the static library is archived by the compiler ('-lib') "
                             "rather than by the Lib tool, so that the library holds one "
                             "object per module as Visual D's own build does" % cfg.key())

        linkopts = []
        for tok in words(cfg.get("additionalOptions")):
            if tok.startswith("-L"):
                linkopts.append(tok[2:])
            else:
                extra.append(tok)
        if flag(cfg.get("quiet")):
            extra.append("-quiet")
        if flag(cfg.get("nofloat")):
            extra.append("-nofloat")
        if flag(cfg.get("privatePhobos")):
            extra.append("-defaultlib=" + normpath(cfg.get("objdir")) + "\\privatephobos.lib")
        if cfg.get("defaultlibname"):
            extra.append("-defaultlib=" + cfg.get("defaultlibname"))
        if cfg.get("debuglibname"):
            extra.append("-debuglib=" + cfg.get("debuglibname"))
        if flag(cfg.get("debuglib")):
            if compiler == "LDC":
                extra.append("-link-debuglib")
            else:
                self.report.ignored("%s: <debuglib> is an LDC switch and has no effect for %s"
                                    % (cfg.key(), compiler))
        if extra:
            d.append(("AdditionalOptions",
                      " ".join(translate_macros(e, self.report, cfg.key()) for e in extra)))

        if flag(cfg.get("otherDMD")) and cfg.get("program"):
            d.append(("CompilerExe", translate_macros(cfg.get("program"),
                                                      self.report, cfg.key())))
        return d, linkopts

    def setting_path(self, raw, cfg):
        """Resolve a path setting; None when macros keep it from resolving."""
        _, env_abs = self.macro_env(self.p, cfg)
        full = substitute(translate_macros(raw, self.report, cfg.key()), env_abs)
        if "$" in full:
            return None
        if not re.match(r"^[a-zA-Z]:[\\/]|^[\\/]", full):
            full = os.path.join(self.p.dir, full)
        return os.path.normpath(full)

    def default_path(self, cfg, ext):
        """The file the linker produces when the corresponding setting is left out."""
        name, ext_override, _ = self.target_name_ext(cfg)
        _, env_abs = self.macro_env(self.p, cfg)
        outdir = env_abs.get("outdir")
        if not outdir:
            return None
        tname = name or self.p.name
        return os.path.normpath(os.path.join(outdir, tname + ext))

    def link_metadata(self, cfg, linkopts):
        otype = cfg.output_type()
        compiler = cfg.compiler()
        cruntime = as_int(cfg.get("cRuntime"), 1)
        symdebug = flag(cfg.get("symdebug"))
        link, lib = [], []

        deps = []
        if not self.opts.project_refs:
            for dep, full in self.dependency_outputs(self.p, cfg, set()):
                deps.append(self.macro_path(full, self.p, cfg))
        for w in words(cfg.get("objfiles")) + words(cfg.get("libfiles")):
            if w.startswith("-l"):                     # a gcc style library name
                self.report.lossy("%s: '%s' rewritten to the MSVC library name %s.lib"
                                  % (cfg.key(), w, w[2:]))
                w = w[2:] + ".lib"
            deps.append(translate_macros(w, self.report, cfg.key()))
        for res in self.res_items:
            deps.append(translate_macros(res, self.report, cfg.key()))
        if cfg.get("resfile"):
            deps.append(translate_macros(cfg.get("resfile"), self.report, cfg.key()))
        # config.d appends these two to every link command line
        deps += ["user32.lib", "kernel32.lib"]
        if compiler == "LDC" or (compiler == "DMD" and (cfg.is64() or cfg.mscoff())):
            deps.append("legacy_stdio_definitions.lib")
        crtlib = {2: "libcmtd.lib", 3: "msvcrt.lib", 4: "msvcrtd.lib"}.get(cruntime)
        if crtlib:
            deps.append(crtlib)
        if cruntime in (0, 2, 3, 4):
            link.append(("IgnoreSpecificDefaultLibraries", "libcmt.lib"))

        if otype == 1:                    # a static library is built by the Lib tool
            if self.outfile:
                lib.append(("OutputFile", self.outfile))
            for opt in linkopts:
                lib.append(("AdditionalOptions", translate_macros(opt, self.report, cfg.key())))
            return link, lib

        sub = SUBSYSTEM.get(as_int(cfg.get("subsystem")))
        if sub:
            link.append(("SubSystem", sub))
        link.append(("GenerateDebugInformation", "true" if symdebug else "false"))
        if symdebug and cfg.get("pdbfile"):
            got = self.setting_path(cfg.get("pdbfile"), cfg)
            default = self.default_path(cfg, ".pdb")
            if got is None or default is None or os.path.normcase(got) != os.path.normcase(default):
                link.append(("ProgramDatabaseFile", self.macro_path(cfg.get("pdbfile"), self.p, cfg)))

        mapv = as_int(cfg.get("mapverbosity"))
        if mapv > 0:
            # The mapverbosity level only selects /MAPINFO or optlink's /MAP:ADDRESS when
            # dmd drives the linker; the MSVC linker just gets the map file itself.
            link.append(("GenerateMapFile", "true"))
            if cfg.get("mapfile"):
                got = self.setting_path(cfg.get("mapfile"), cfg)
                default = self.default_path(cfg, ".map")
                if got is None or default is None or os.path.normcase(got) != os.path.normcase(default):
                    link.append(("MapFileName", self.macro_path(cfg.get("mapfile"), self.p, cfg)))
            if mapv in (1, 3, 4):
                self.report.note("%s: mapverbosity=%d also asks for the export listing in "
                                 "the map file, which the MSVC linker is not given by "
                                 "Visual D" % (cfg.key(), mapv))
        if flag(cfg.get("createImplib")) and cfg.get("impfile"):
            got = self.setting_path(cfg.get("impfile"), cfg)
            default = self.default_path(cfg, ".lib")
            if got is None or default is None or os.path.normcase(got) != os.path.normcase(default):
                link.append(("ImportLibrary", self.macro_path(cfg.get("impfile"), self.p, cfg)))

        libpaths = words(cfg.get("libpaths"))
        if libpaths:
            link.append(("AdditionalLibraryDirectories",
                         ";".join(translate_macros(p, self.report, cfg.key()) for p in libpaths)))
        if deps:
            link.append(("AdditionalDependencies", ";".join(deps)))

        extra = []
        deffile = cfg.get("deffile")
        if deffile:
            link.append(("ModuleDefinitionFile",
                         translate_macros(deffile, self.report, cfg.key())))
        elif self.def_items:
            link.append(("ModuleDefinitionFile", self.def_items[0]))
            for d in self.def_items[1:]:
                extra.append('/DEF:"%s"' % d)

        for opt in linkopts:
            o = opt.strip('"')
            up = o.upper()
            if up.startswith("/STACK:"):
                val = o[7:]
                if "," in val:
                    res, com = val.split(",", 1)
                    link.append(("StackReserveSize", res))
                    link.append(("StackCommitSize", com))
                else:
                    link.append(("StackReserveSize", val))
            elif up.startswith("/SUBSYSTEM:"):
                val = o.split(":", 1)[1].split(",")[0]
                if val.upper() in ("CONSOLE", "WINDOWS", "NATIVE", "POSIX"):
                    link.append(("SubSystem", val.upper()))
                else:
                    extra.append(o)
            else:
                extra.append(o)
        for opt in words(cfg.get("linkswitches")):
            extra.append(translate_macros(opt, self.report, cfg.key()))
        if extra:
            link.append(("AdditionalOptions", " ".join(extra)))
        if self.outfile:
            link.append(("OutputFile", self.outfile))
        return link, lib

    def events(self, cfg):
        out = []
        if cfg.get("preBuildCommand").strip():
            out.append(("PreBuildEvent", "Command",
                        translate_macros(cfg.get("preBuildCommand"), self.report, cfg.key())))
        if cfg.get("postBuildCommand").strip():
            out.append(("PostBuildEvent", "Command",
                        translate_macros(cfg.get("postBuildCommand"), self.report, cfg.key())))
        return out

    # ---------------- items

    def item_type(self, path, tool):
        ext = os.path.splitext(path)[1].lower()
        if tool in ("DMD", "DMDsingle", "RDMD"):
            return "DCompile"
        if tool == "Resource Compiler":
            return "ResourceCompile"
        if tool == "C/C++":
            return "ClCompile"
        if ext in (".d", ".ddoc"):
            return "DCompile"
        if ext == ".rc":
            return "ResourceCompile"
        if ext == ".idl":
            return "Midl"
        if ext in (".h", ".hpp", ".hxx", ".inl", ".r", ".di"):
            return "ClInclude"
        if ext in (".c", ".cpp", ".cxx", ".cc"):
            return "ClCompile"
        if ext == ".lib":
            return "Library"
        if ext in (".obj", ".o"):
            return "Object"
        if ext == ".def":
            return "Def"
        return "None"

    def walk(self, node, filterpath, root=False):
        for ch in node:
            if ch.tag == "Folder":
                if root:  # the <Folder> below <Project> is the project node itself
                    self.walk(ch, filterpath)
                    continue
                sub = ch.get("name") or ""
                fp = sub if not filterpath else filterpath + "\\" + sub
                if fp:
                    self.folders.append(fp)
                self.walk(ch, fp)
            elif ch.tag == "File":
                self.add_file(ch, filterpath)
            elif ch.tag == "Config" or root:
                pass
            else:
                raise SystemExit("unexpected <%s> element in %s" % (ch.tag, self.p.path))

    def add_file(self, elem, filterpath):
        path = elem.get("path") or ""
        tool = elem.get("tool") or ""
        base = self.item_type(path, tool)
        percfg = {s.get("name"): dict(s.attrib) for s in elem.findall("Config")}

        if tool == "Custom":
            self.add_custom_build(elem, percfg, filterpath, path)
            return
        if base == "Def":
            self.def_items.append(translate_macros(path, self.report, path))
            self.report.note("%s: handed to the linker as ModuleDefinitionFile" % path)
            self.items.append(("None", path, filterpath, [], percfg))
            return
        if os.path.splitext(path)[1].lower() == ".res":
            self.res_items.append(path)
        meta = []
        if elem.get("addopt"):
            meta.append(("AdditionalOptions", translate_macros(elem.get("addopt"),
                                                               self.report, path)))
        if elem.get("outfile") and base == "DCompile":
            meta.append(("ObjectFileName", translate_macros(elem.get("outfile"),
                                                            self.report, path)))
            self.report.lossy("%s: 'outfile' names the object file of this module" % path)
        if elem.get("dependencies") and base == "DCompile":
            self.report.lossy("%s: per-file dependencies are tracked by MSBuild itself" % path)
        if tool == "None":
            meta.append(("ExcludedFromBuild", "true"))
        self.items.append((base, path, filterpath, meta, percfg))

    def add_custom_build(self, elem, percfg, filterpath, path):
        cmd = elem.get("customcmd") or ""
        ext = os.path.splitext(path)[1].lower()
        if cmd and not self.opts.no_native_tools and ext in (".idl", ".rc"):
            kind = "midl" if ext == ".idl" else "rc"
            parsed = self.parse_tool_cmd(cmd, kind, path)
            if parsed is not None:
                self.add_native_tool(kind, path, parsed, elem, percfg, filterpath)
                return
            self.report.lossy("%s: the custom command is not a plain %s invocation; it is "
                              "kept as a CustomBuild step" % (path, kind))
        if not cmd:
            self.items.append((self.item_type(path, ""), path, filterpath, [], percfg))
            return
        meta = [("Command", translate_macros(cmd, self.report, path, True))]
        if elem.get("outfile"):
            meta.append(("Outputs", translate_macros(elem.get("outfile"), self.report, path, True)))
        if elem.get("dependencies"):
            meta.append(("AdditionalDependencies",
                         ";".join(translate_macros(d, self.report, path, True)
                                  for d in words(elem.get("dependencies")))))
        if elem.get("linkoutput") == "true":
            meta.append(("LinkObjects", "true"))
            self.report.note("%s: the output of the custom build step is linked "
                             "(CustomBuild LinkObjects=true)" % path)
        if elem.get("uptodateWithSameTime") == "true":
            self.report.lossy("%s: 'uptodateWithSameTime' has no CustomBuild equivalent" % path)
        self.items.append(("CustomBuild", path, filterpath, meta, percfg))

    # The preamble of the midl/rc custom steps only sets up the environment a C++ project
    # already has, so those lines can be dropped.
    SKIP_LINE_PREFIX = ("set ", "if ", "call ", "goto ", "echo", "@", ":", "rem ")

    SWITCH_PREFIXES = ("errorchecknone", "app_config", "oicf", "nologo", "env", "char",
                       "error", "target", "wmf", "fo", "out", "tlb", "h", "i", "d", "w",
                       "r", "m", "c", "u", "l", "t", "x")
    VALUE_SWITCHES = {"midl": {"d", "u", "i", "out", "tlb", "h", "env", "char", "error",
                               "target", "wmf", "prefix", "server", "x"},
                      "rc": {"fo", "i", "d", "u", "l", "c", "t"}}

    # the values Microsoft.Cpp.Common.props inherits for the C++ tools
    MIDL_DEFAULTS = ci_dict({"typelibraryname": "$(IntDir)$(ProjectName).tlb",
                             "warninglevel": "1", "defaultchartype": "Signed",
                             "suppressstartupbanner": "true",
                             "headerfilename": "%(Filename)_h.h",
                             "minimumtargetsystem": "NT60"})
    RC_DEFAULTS = ci_dict({"resourceoutputfilename": "$(IntDir)%(Filename).res",
                           "suppressstartupbanner": "true", "culture": "0x0409"})

    MIDL_ENV = ci_dict({"win32": "Win32", "x64": "X64", "arm32": "ARM32",
                        "arm64": "ARM64", "ia64": "Itanium", "x86": "Win32"})
    MIDL_CHAR = ci_dict({"signed": "Signed", "unsigned": "Unsigned", "ascii7": "Ascii",
                         "ascii": "Ascii"})
    MIDL_ERRORCHECK = ci_dict({"stub_data": "ErrorCheckStubData",
                               "allocations": "ErrorCheckAllocations",
                               "bounds": "ErrorCheckBounds",
                               "enumrange": "ErrorCheckEnumRange",
                               "refpointers": "ErrorCheckRefPointers"})

    def expand_input_macros(self, s, path):
        """$(InputName) and friends are only expanded for custom build steps."""
        full = os.path.normpath(self.p.dir + os.path.normpath(path))
        base = os.path.splitext(os.path.basename(path))[0]
        rep = {"inputpath": full, "inputfilename": os.path.basename(path),
               "inputname": base, "rootname": base, "filename": base,
               "inputdir": os.path.dirname(full) + "\\",
               "inputext": os.path.splitext(path)[1], "ext": os.path.splitext(path)[1]}
        return MACRO_RE.sub(lambda m: rep.get(m.group(1).lower(), m.group(0)), s)

    def tool_value(self, path, value):
        return translate_macros(normpath(self.expand_input_macros(value, path)),
                                self.report, path)

    def is_tool_token(self, tok, kind):
        """Is this token a command position for midl/rc (bare, %var% or a full path)?"""
        if "=" in tok:
            return False
        t = tok.strip('"')
        if t.startswith("%") and t.endswith("%"):
            t = t[1:-1]
        t = t.replace("\\", "/").rstrip("/").lower()
        if t.endswith(".exe"):
            t = t[:-4]
        return t == kind or t.endswith("/" + kind)

    def parse_tool_cmd(self, cmd, kind, path):
        """Recognize a plain midl/rc invocation behind the usual environment preamble.

        The XML parser folds the newlines of the multi-line command into spaces, so the
        invocation is found by scanning the tokens: it is the last command of the step."""
        toks = words(cmd)
        start = None
        for i, tok in enumerate(toks):
            if tok in ("&&", "|", "(", ")"):
                continue
            if self.is_tool_token(tok, kind):
                start = i
        if start is None:
            return None
        args = []
        for tok in toks[start + 1:]:
            if tok in ("&&", "|", ")"):
                break
            args.append(tok)
        if start:
            self.report.note("%s: the environment setup of the custom step is dropped, a C++ "
                             "project already has it" % path)

        switches, positional = {}, []
        i = 0
        while i < len(args):
            a = args[i]
            if not a.startswith(("/", "-")):
                positional.append(a.strip('"'))
                i += 1
                continue
            sw = a[1:]
            name, val = sw, ""
            for sep in (":", "="):
                if sep in sw:
                    name, val = sw.split(sep, 1)
                    break
            if not val:
                for prefix in self.SWITCH_PREFIXES:
                    if sw.lower().startswith(prefix):
                        name, val = prefix, sw[len(prefix):]
                        break
            name = name.lower()
            if not val.strip('"') and name in self.VALUE_SWITCHES[kind] and i + 1 < len(args):
                val = args[i + 1]
                i += 1
            switches.setdefault(name, []).append(val.strip('"'))
            i += 1

        # the source file the step is run for is implied by the item
        inputs = {"$(inputpath)", "$(inputdir)$(inputfilename)", os.path.normpath(path).lower()}
        extra = [p for p in positional if p.lower() not in inputs]
        return switches, extra

    def add_native_tool(self, kind, path, parsed, elem, percfg, filterpath):
        switches, extra = parsed
        meta = []
        deps = elem.get("dependencies")
        if deps:
            meta.append(("AdditionalDependenciesMetadata",
                         ";".join(translate_macros(d, self.report, path, True)
                                  for d in words(deps))))
        if kind == "midl":
            self.report.note("%s: custom build step converted to the Midl tool" % path)
            if switches.get("d"):
                meta.append(("PreprocessorDefinitions",
                             ";".join(switches["d"]) + ";%(PreprocessorDefinitions)"))
            if switches.get("i"):
                meta.append(("AdditionalIncludeDirectories",
                             ";".join(self.tool_value(path, i) for i in switches["i"])
                             + ";%(AdditionalIncludeDirectories)"))
            if switches.get("out"):
                meta.append(("OutputDirectory", self.tool_value(path, switches["out"][-1])))
            if switches.get("tlb"):
                tlb = self.tool_value(path, switches["tlb"][-1])
                if os.path.splitext(os.path.basename(tlb))[0].lower() != self.p.name.lower():
                    meta.append(("TypeLibraryName", tlb))
                else:
                    self.report.note("%s: the type library keeps the default name" % path)
            if "oicf" in switches:
                meta.append(("GenerateStublessProxies", "true"))
            for err in switches.get("error", []):
                for word in words(err):
                    prop = self.MIDL_ERRORCHECK.get(word.lower())
                    if prop:
                        meta.append((prop, "true"))
                    else:
                        extra.append("error " + word)
            if switches.get("env"):
                meta.append(("TargetEnvironment",
                             self.MIDL_ENV.get(switches["env"][-1], switches["env"][-1])))
            if switches.get("char"):
                meta.append(("DefaultCharType",
                             self.MIDL_CHAR.get(switches["char"][-1].lower(),
                                                switches["char"][-1])))
            if "nologo" not in switches:
                meta.append(("SuppressStartupBanner", "false"))
            if switches.get("w"):
                meta.append(("WarningLevel", switches["w"][-1]))
            else:
                meta.append(("WarningLevel", ""))
            if switches.get("h"):
                meta.append(("HeaderFileName", self.tool_value(path, switches["h"][-1])))
            else:
                meta.append(("HeaderFileName", ""))
            if switches.get("target"):
                meta.append(("MinimumTargetSystem", switches["target"][-1]))
            else:
                meta.append(("MinimumTargetSystem", ""))
            known = {"d", "i", "u", "out", "tlb", "oicf", "error", "env", "char", "h", "w",
                     "target", "nologo", "errorchecknone", "wmf", "app_config", "prefix"}
            for name in sorted(set(switches) - known):
                for val in switches[name]:
                    extra.append(name + (" " + val if val else ""))
        else:
            self.report.note("%s: custom build step converted to the ResourceCompile tool"
                             % path)
            if switches.get("fo"):
                meta.append(("ResourceOutputFileName", self.tool_value(path, switches["fo"][-1])))
            if switches.get("i"):
                meta.append(("AdditionalIncludeDirectories",
                             ";".join(self.tool_value(path, i) for i in switches["i"])
                             + ";%(AdditionalIncludeDirectories)"))
            if switches.get("d"):
                meta.append(("PreprocessorDefinitions",
                             ";".join(switches["d"]) + ";%(PreprocessorDefinitions)"))
            if switches.get("l"):
                meta.append(("Culture", switches["l"][-1]))
            if "nologo" not in switches:
                meta.append(("SuppressStartupBanner", "false"))
            known = {"fo", "i", "d", "u", "l", "c", "r", "nologo", "language", "t"}
            for name in sorted(set(switches) - known):
                for val in switches[name]:
                    extra.append(name + (" " + val if val else ""))
            if elem.get("linkoutput") == "true":
                self.report.note("%s: the .res produced by ResourceCompile is linked by the "
                                 "C++ build" % path)
        if switches.get("u"):
            meta.append(("AdditionalOptions",
                         " ".join("/U %s" % u for u in switches["u"])))
        if extra:
            self.report.lossy("%s: %s cannot be expressed as %s metadata and is passed as "
                              "AdditionalOptions: %s"
                              % (path, ", ".join(extra),
                                 "Midl" if kind == "midl" else "ResourceCompile",
                                 " ".join("/" + e for e in extra)))
            opt = " ".join("/" + e for e in extra)
            if meta and meta[-1][0] == "AdditionalOptions":
                meta[-1] = ("AdditionalOptions", meta[-1][1] + " " + opt)
            else:
                meta.append(("AdditionalOptions", opt))
        defaults = self.MIDL_DEFAULTS if kind == "midl" else self.RC_DEFAULTS
        meta = [(k, v) for k, v in meta if defaults.get(k.lower()) != v]
        self.items.append(("Midl" if kind == "midl" else "ResourceCompile",
                           path, filterpath, meta, percfg))

    PERCFG_META = {"customcmd": "Command", "outfile": "Outputs", "addopt": "AdditionalOptions"}

    def per_config_metadata(self, percfg, custom=False):
        """Per-configuration file overrides become conditioned metadata.  `custom` selects the
        spelling a custom build step needs."""
        out = []
        for name in sorted(percfg):
            cond = "'$(Configuration)|$(Platform)'=='%s'" % name
            attrs = percfg[name]
            for key in sorted(attrs):
                val = attrs[key]
                if key == "name":
                    continue
                if key == "tool":
                    if val == "None":
                        out.append(("ExcludedFromBuild", "true", [cond]))
                    else:
                        self.report.lossy("per-config file tool '%s' is not converted (%s)"
                                          % (val, name))
                    continue
                if key == "linkoutput":
                    if val == "true":
                        out.append(("LinkObjects", "true", [cond]))
                    continue
                if key == "dependencies":
                    out.append(("AdditionalDependencies",
                                ";".join(translate_macros(d, self.report, name, custom)
                                         for d in words(val)), [cond]))
                    continue
                meta = self.PERCFG_META.get(key)
                if not meta:
                    self.report.lossy("per-config file attribute '%s' is not converted (%s)"
                                      % (key, name))
                    continue
                out.append((meta, translate_macros(val, self.report, name, custom), [cond]))
        merged = {}
        for k, v, conds in out:
            merged.setdefault((k, v), []).extend(conds)
        result = []
        for (k, v), conds in merged.items():
            if len(conds) >= len(self.p.configs):
                result.append((k, v))
            else:
                result.append((k, v, conds))
        return result

    # ---------------- driver

    def convert(self):
        seen = set()
        for cfg in self.p.configs:
            seen.update(cfg.v)
        for key in sorted(seen):
            low = key.lower()
            if low in DEAD_OPTIONS:
                self.report.ignored("<%s> has no effect in Visual D either" % key)
            elif low in UNSUPPORTED_OPTIONS:
                if any(cfg.get(key) not in ("", "0") for cfg in self.p.configs):
                    self.report.unsupported("<%s>: %s" % (key, UNSUPPORTED_OPTIONS[low]))
            elif low in MAPPED_OPTIONS:
                self.report.note("<%s>: %s" % (key, MAPPED_OPTIONS[low]))
            elif low not in KNOWN_OPTIONS:
                self.report.unsupported("option <%s> is not known to the converter" % key)

        self.walk(self.p.root, "", True)
        for cfg in self.p.configs:
            d, linkopts = self.dcompile_metadata(cfg)
            props = self.user_properties(cfg)      # also computes self.outfile
            link, lib = self.link_metadata(cfg, linkopts)
            cfg.dcompile = self.strip_defaults(cfg, d)
            cfg.link, cfg.lib = link, lib
            cfg.props = self.config_properties(cfg)
            cfg.dirs = props
            cfg.events = self.events(cfg)
        self.check_metadata_names()

    def check_metadata_names(self):
        for cfg in self.p.configs:
            for name, _ in cfg.dcompile:
                if name not in self.rule_props:
                    self.report.unsupported("%s: the DCompile property '%s' is not defined "
                                            "by the MSBuild rules" % (cfg.key(), name))

    def strip_defaults(self, cfg, d):
        if self.opts.keep_defaults:
            return [(k, v) for k, v in d if v is not None]
        env = ci_dict({"DCompiler": cfg.compiler(), "Platform": cfg.platform,
                       "Configuration": cfg.name})
        defaults = {}
        for name, value, cond in self.defaults:
            if msbuild_condition(cond, env):
                defaults[name] = value
        out = []
        for k, v in d:
            if v is None or (k in defaults and defaults[k] == v):
                continue
            # A rule boolean without SwitchFalse emits nothing for "false".
            if v == "false" and self.rule_props.get(k) == "BoolProperty" \
                    and defaults.get(k, "false") == "false":
                continue
            out.append((k, v))
        return out

    # ---------------- emit

    ITEM_ORDER = ["DCompile", "Midl", "ResourceCompile", "ClCompile", "ClInclude",
                  "CustomBuild", "Library", "Object", "None"]

    def emit_metadata(self, A, items):
        for item in items:
            if len(item) == 2:
                k, v, conds = item[0], item[1], [None]
            else:
                k, v, conds = item[0], item[1], item[2]
            for cond in conds:
                attr = ' Condition="%s"' % esc(cond) if cond else ""
                if v == "":
                    A('      <%s%s></%s>' % (k, attr, k))
                else:
                    A('      <%s%s>%s</%s>' % (k, attr, esc(v), k))

    def emit(self):
        L = []
        A = L.append
        A('<?xml version="1.0" encoding="utf-8"?>')
        A('<Project DefaultTargets="Build" ToolsVersion="Current" '
          'xmlns="http://schemas.microsoft.com/developer/msbuild/2003">')
        A('  <ItemGroup Label="ProjectConfigurations">')
        for cfg in self.p.configs:
            A('    <ProjectConfiguration Include="%s|%s">' % (esc(cfg.name), esc(cfg.platform)))
            A('      <Configuration>%s</Configuration>' % esc(cfg.name))
            A('      <Platform>%s</Platform>' % esc(cfg.platform))
            A('    </ProjectConfiguration>')
        A('  </ItemGroup>')
        A('  <PropertyGroup Label="Globals">')
        A('    <ProjectGuid>%s</ProjectGuid>' % esc(self.p.guid))
        A('    <Keyword>Win32Proj</Keyword>')
        A('    <RootNamespace>%s</RootNamespace>' % esc(self.p.name))
        A('    <WindowsTargetPlatformVersion>10.0</WindowsTargetPlatformVersion>')
        A('  </PropertyGroup>')
        A('  <Import Project="$(VCTargetsPath)\\Microsoft.Cpp.Default.props" />')
        for cfg in self.p.configs:
            A('  <PropertyGroup Condition="\'$(Configuration)|$(Platform)\'==\'%s|%s\'" '
              'Label="Configuration">' % (esc(cfg.name), esc(cfg.platform)))
            for k, v in cfg.props:
                A('    <%s>%s</%s>' % (k, esc(v), k))
            A('  </PropertyGroup>')
        A('  <Import Project="$(VCTargetsPath)\\Microsoft.Cpp.props" />')
        A('  <ImportGroup Label="ExtensionSettings">')
        A('  </ImportGroup>')
        A('  <ImportGroup Label="PropertySheets">')
        A('    <Import Project="$(UserRootDir)\\Microsoft.Cpp.$(Platform).user.props" '
          'Condition="exists(\'$(UserRootDir)\\Microsoft.Cpp.$(Platform).user.props\')" '
          'Label="LocalAppDataPlatform" />')
        A('  </ImportGroup>')
        A('  <PropertyGroup Label="UserMacros" />')
        for cfg in self.p.configs:
            A('  <PropertyGroup Condition="\'$(Configuration)|$(Platform)\'==\'%s|%s\'">'
              % (esc(cfg.name), esc(cfg.platform)))
            for k, v in cfg.dirs:
                A('    <%s>%s</%s>' % (k, esc(v), k))
            A('  </PropertyGroup>')

        for cfg in self.p.configs:
            if not (cfg.dcompile or cfg.link or cfg.lib or cfg.events):
                continue
            A('  <ItemDefinitionGroup Condition="\'$(Configuration)|$(Platform)\'==\'%s|%s\'">'
              % (esc(cfg.name), esc(cfg.platform)))
            if cfg.dcompile:
                A('    <DCompile>')
                self.emit_metadata(A, cfg.dcompile)
                A('    </DCompile>')
            for tag, items in (("Link", cfg.link), ("Lib", cfg.lib)):
                if not items:
                    continue
                A('    <%s>' % tag)
                self.emit_metadata(A, items)
                A('    </%s>' % tag)
            for group, meta, val in cfg.events:
                A('    <%s>' % group)
                A('      <%s>%s</%s>' % (meta, esc(val), meta))
                A('    </%s>' % group)
            A('  </ItemDefinitionGroup>')

        if self.opts.project_refs:
            refs = []
            for cfg in self.p.configs:
                for guid in self.sln_deps.get(self.p.guid, []):
                    path = self.sln_projects.get(guid)
                    if not path:
                        continue
                    rel = os.path.relpath(path, self.p.dir.rstrip("\\")).replace(os.sep, "\\")
                    if (rel, guid) not in refs:
                        refs.append((rel, guid))
            if refs:
                A('  <ItemGroup>')
                for rel, guid in refs:
                    A('    <ProjectReference Include="%s">' % esc(rel))
                    A('      <Project>%s</Project>' % esc(guid))
                    A('    </ProjectReference>')
                A('  </ItemGroup>')

        A('  <ItemGroup>')
        for it in self.ITEM_ORDER:
            for t, path, fp, meta, percfg in self.items:
                if t != it:
                    continue
                allmeta = list(meta) + self.per_config_metadata(percfg, t == "CustomBuild")
                if not allmeta:
                    A('    <%s Include="%s" />' % (t, esc(path)))
                    continue
                A('    <%s Include="%s">' % (t, esc(path)))
                self.emit_metadata(A, allmeta)
                A('    </%s>' % t)
        A('  </ItemGroup>')
        A('  <Import Project="$(VCTargetsPath)\\Microsoft.Cpp.targets" />')
        A('  <ImportGroup Label="ExtensionTargets">')
        A('  </ImportGroup>')
        A('</Project>')
        return "\n".join(L) + "\n"

    def emit_filters(self):
        L = []
        A = L.append
        A('<?xml version="1.0" encoding="utf-8"?>')
        A('<Project ToolsVersion="Current" '
          'xmlns="http://schemas.microsoft.com/developer/msbuild/2003">')
        A('  <ItemGroup>')
        for fp in dict.fromkeys(self.folders):
            gid = uuid.uuid5(uuid.NAMESPACE_URL, "visuald/" + self.p.name + "/" + fp)
            A('    <Filter Include="%s">' % esc(fp))
            A('      <UniqueIdentifier>{%s}</UniqueIdentifier>' % str(gid).upper())
            A('    </Filter>')
        A('  </ItemGroup>')
        for it in self.ITEM_ORDER:
            group = [(t, p, fp) for t, p, fp, m, pc in self.items if t == it and fp]
            if not group:
                continue
            A('  <ItemGroup>')
            for t, p, fp in group:
                A('    <%s Include="%s">' % (t, esc(p)))
                A('      <Filter>%s</Filter>' % esc(fp))
                A('    </%s>' % t)
            A('  </ItemGroup>')
        A('</Project>')
        return "\n".join(L) + "\n"


# --------------------------------------------------------------------- main

def write(path, text):
    with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser(description="Convert a Visual D project into a vcxproj.")
    ap.add_argument("project")
    ap.add_argument("--out")
    ap.add_argument("--name")
    ap.add_argument("--sln")
    ap.add_argument("--msbuild-dir")
    ap.add_argument("--project-refs", action="store_true")
    ap.add_argument("--keep-defaults", action="store_true")
    ap.add_argument("--no-filters", action="store_true")
    ap.add_argument("--no-native-tools", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--report")
    opts = ap.parse_args()

    project = Project(opts.project, opts.name)
    if not opts.sln:
        opts.sln = find_solution(project.dir)
    if opts.sln:
        opts.sln = os.path.abspath(opts.sln)
    if not opts.msbuild_dir:
        opts.msbuild_dir = find_msbuild_dir(project.dir)
    if opts.msbuild_dir:
        opts.msbuild_dir = os.path.abspath(opts.msbuild_dir)
    if not opts.msbuild_dir or not os.path.exists(os.path.join(opts.msbuild_dir, "dmd.xml")):
        raise SystemExit("cannot find the MSBuild rules (msbuild/dmd.xml); pass --msbuild-dir")

    report = Report()
    conv = Converter(project, opts, report)
    conv.convert()

    print("project : %s" % project.path)
    if opts.sln:
        print("solution: %s" % opts.sln)
    print("rules   : %s" % opts.msbuild_dir)
    print("configs : %d, items: %d" % (len(project.configs), len(conv.items)))
    for cfg in project.configs:
        print("  %-24s %-6s %-5s %s" % (cfg.name, cfg.platform, cfg.compiler(),
                                        CONFIGURATION_TYPE.get(cfg.output_type())))
    print()
    report.dump()

    if opts.dry_run:
        return 0
    outdir = opts.out or project.dir
    os.makedirs(outdir, exist_ok=True)
    text = conv.emit()
    proj_path = os.path.join(outdir, project.name + ".vcxproj")
    write(proj_path, text)
    print("wrote   : %s (%d bytes)" % (proj_path, len(text)))
    if not opts.no_filters:
        ftext = conv.emit_filters()
        write(proj_path + ".filters", ftext)
        print("wrote   : %s (%d bytes)" % (proj_path + ".filters", len(ftext)))
    if opts.report:
        write(opts.report, report.text())
        print("report  : %s" % opts.report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
