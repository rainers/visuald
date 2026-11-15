# CTFE debugger (`dmdserver -ctfeDebug`) — state of the work

A DAP server built into the DMD front end: `dmdserver.exe -ctfeDebug` analyzes a file and lets a
DAP client set breakpoints, step, and read the values the interpreter computes while it folds
constants. The adapter is `vdc/dmdserver/ctfedebug.d`; the front end exposes four hooks. Everything
runs on the thread doing the semantic analysis — a hook blocks that thread while the client
inspects the interpreter state.

Works today: breakpoints on statements, on manifest-constant declarations, and on the static
conditions the front end answers, with breakpoint conditions of their own; step in / out / over and
pause; a call stack showing the interpreted calls, the template instantiations that generated the
code, the static condition being answered, and the constant expression being folded; locals with
the parameters, the template arguments, and the values and types an instance defines; struct and
class values expanding their fields; `$returnValue` where a call hands a value back; values and
types spelled by the compiler's own printers; an expression evaluator scoped to the selected frame;
compiler diagnostics and console output; and all of that driven from Visual Studio through the
Debug Adapter Host.

## What is committed where

| where | state |
|---|---|
| Visual D trunk | `edf1f11 add CTFE debugger`, `4533aa6 redirect stdout and stderr to the debug pane`, `b5a9ae3 add template instantiations to the call stack`, `4fd6a97 show types and compile time constants as part of the instantiation`, `cb0eb87 improve stepping through return, show return value`, `7453155 show fields of a class instance`, `2f05c67 CTFE debugger: fix breakpoint handling`, `c7c5996 add CTFE debugger tests` |
| dmd submodule, branch `dmdserver` (ahead 2 of `rainers/dmdserver`) | `76f9418577 add hooks for CTFE debugging`, `08b1d14488 move debugger helpers to ctfedebug.d`, `a090b3c8d3 add return value hook`, `05bcd531ef add onCondition hook` |
| still uncommitted | the `resolvePackage()` call in `compileWorker` ("The debugged file is one module" above); the `scenario_package_module()` test and the `ctfe_pkg/` fixture; `visuald/ctfedebug.d` (+77 lines: a `version(all)` override to the trunk build of `dmdserver.exe`, and the scratch fixture at the end of the file); `vdextensions/vdext15.csproj` (copy `ctfedebug_launch.json` to the output) |

Commit the dmd submodule first, then Visual D, with
`Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`. Keep
`vdextensions/navigateto.cs` and `vdextensions/vdext15.csproj` out of the CTFE commit.

## What is there

| File | Role |
|---|---|
| `vdc/dmdserver/ctfedebug.d` | the DAP server (3526 lines): stdio JSON, breakpoints, stack, locals, template arguments and instance definitions, instance arguments in values and types, return values, stepping out at the call site and out to the declaration of the constant, single stepping ending at either, a step off a return line ending there too, class instances expanding their fields, template constraints and `static if`/`static assert` conditions with the arguments of the instance they are written in, globals, expression evaluator |
| `vdc/dmdserver/dapio.d` | Content-Length framed JSON transport, `getField/getString/getInteger/jsonArray` helpers |
| `vdc/dmdserver/dmdinit.d` | `objc._init()` / `_dsymbols1` bootstrap the front end needs |
| `vdc/dmdserver/vdserverfactory.d` | routes `-ctfeDebug` on the command line to `CtfeDebugSession` |
| `vdc/dmdserver/dmd/compiler/src/dmd/dinterpret.d` | `CtfeDebugHooks` and the `__gshared ctfeDebugHooks` the adapter fills in |
| `…/expressionsem.d`, `…/semantic2.d`, `…/templatesem.d` | `evalStaticCondition(…, const(char)* kind)` and the three call sites that name the construct |
| `visuald/ctfedebug.d` | the Visual D extension side: `StartCtfeDebug()` builds a launch configuration and starts the Debug Adapter Host (not a copy of the adapter) |
| `ctfe_debug/*` (this folder) | build script, Python DAP harness, demo sources, this file |

## Build

```
call vdc\dmdserver\ctfe_debug\build_ctfe2.bat
```
Compiles the patched dmd front end and `dmdserver.exe` into
`bin\Debug COFF32\x64\dmdserver.exe` (~1–2 min, prints `BUILD OK`). dmd 2.114.0-beta.1, flags
`-version=MARS -version=NoBackend -version=GC -version=LanguageServer -m64 -g -gf -check=assert`.
Run it from the trunk root. Rebuild after every change to `ctfedebug.d` (one level *above* this
folder) or to a dmd file: the scenarios and VS run the built exe, and a stale one reproduces
behaviour the source no longer has — that looked like a regression in the manifest stops for a
while.

## Test

```
cd vdc\dmdserver\ctfe_debug
python -u dap_scenarios.py > ..\..\..\dap_run.log
```
(`-u` and a file redirect are required — PowerShell pipes buffer the output.) 20 scenarios, ~4 s,
exit 0, ~318 log lines:

```
global constants are no scope of their own        compiler generated locals are hidden
conditional breakpoint                            expression evaluation
breakpoint on a manifest constant declaration     the initializer at the bottom of the stack
template arguments show as locals                 template instantiations show in the call stack
values and types defined by an instance           instance values and types name their arguments
class instances expand the fields                 breaking on static conditions
arguments of the instance a condition is in       the return of a call is a step of its own
stepping out of a call ends at the call site      pause while running
compile time error reported to the client         compiler console output reaches the client
breakpoints come back as they were sent          a module of a package is analysed once
```

Scenarios, in the order `main()` runs them: `scenario_globals()`, `scenario_temps()`,
`scenario_condition()`, `scenario_evaluate()`, `scenario_manifest()`, `scenario_bottom()`,
`scenario_template_args()`, `scenario_instantiation()`, `scenario_instance_defs()`,
`scenario_instance_values()`, `scenario_class_fields()`, `scenario_conditions()`,
`scenario_condition_instances()`, `scenario_breakpoint_order()`, `scenario_package_module()`,
`scenario_return()`, `scenario_stepout()`, `scenario_pause()`, `scenario_errors()`, `scenario_output()`.

Harness API (`dap_scenarios.py`): `Client(src)` with `request(cmd, args)`, `send`,
`wait_event(names, timeout)` (takes a *set* of event names and leaves the terminal
`terminated`/`exited` events in the queue), `got_event`, `frames`, `scopes`, `outputs`, `close`;
helpers `find_line(src, marker)`, `local_values`, `local_types`, `local_tree`, `finish(c)` (resumes
past any further stops), and the `IMPORTS`/`TERMINAL`/`BASE` constants. Most scenarios end by
waiting for a stop that never comes — that used to burn the full 30 s timeout per scenario, which
is why the suite once took 3 min.

Demo sources: `ctfe_demo.d`, `ctfe_demo2.d`, `ctfe_pause.d`, `ctfe_err.d`, `ctfe_expr.d`,
`ctfe_manifest.d`, `ctfe_template.d`, `ctfe_out.d`, `ctfe_inst.d`, `ctfe_nested.d`, `ctfe_defs.d`,
`ctfe_ret.d`, `ctfe_stepout.d`, `ctfe_values.d`, `ctfe_class.d`, `ctfe_cond.d`, `ctfe_cond2.d`, and the
`ctfe_pkg/` package (`package.d` importing `leaf.d`).
`launch.json` (here) is the Visual Studio launch configuration used for the VS smoke test.

## How `ctfedebug.d` is edited

The Visual Studio edit tools fail on `ctfedebug.d` and on files in the `dmd` submodule
("unexpected error"); they work on the Python and markdown files. Changes to the D sources therefore
go through a small script that replaces exact anchors:

```
cd vdc\dmdserver\ctfe_debug     # this folder
python apply_ctfe_patch.py <spec file>
```

* The spec format is `<<<OLD` / `<<<NEW` / `<<<END` blocks; blank lines and `#` lines outside blocks
  are ignored. **4 spaces in a spec = 1 tab** in the source, and every line's indentation must be a
  multiple of 4 spaces — that is what makes a doc-comment line of dmd awkward: start such a line at
  column 0 or the driver refuses the spec.
* The file is read as bytes and decoded UTF-8; anchors match with the file's own line endings (CRLF
  here) and tabs. Exactly one match per anchor is asserted, and the file is written back only when
  all of them matched, so a spec is atomic. The last OLD line matches as a prefix.
* `apply_ctfe_patch.py` only ever patches `../ctfedebug.d`. Patching the front end needs the same
  driver with the target as an argument (`apply_patch_any.py <target.d> <spec...>` in the Copilot
  session folder). One spec patches one file — never mix two front-end files.
* **Already applied specs must not be re-run.** Spent spec files get deleted after they are applied;
  small one-off fixes used throwaway scripts with two or three anchors instead. Backups
  (`ctfedebug.d.bak2`, `ctfedebug.d.pre_r29`) live in
  `%LOCALAPPDATA%\Microsoft\VisualStudio\CopilotCli\session-state\files`.
* Warning: the file is open in the VS editor. If the editor holds an older buffer, saving it
  overwrites the patched file — reload it in the editor first.

## The front-end hooks

`dinterpret.d` declares the whole interface (29 inserted lines across four files):

```d
struct CtfeDebugHooks
{
    /// before the statement `s` is interpreted in the context `istate`
    void function(InterState* istate, Statement s) onStatement;

    /// before/after the constant expression `e` is evaluated in the global context
    void function(Expression e, bool end) onConstant;

    /// when a call is about to leave the function it was interpreting, handing `result` back
    void function(InterState* istate, Expression result) onReturn;

    /// before/after the front end answers a static condition during semantic analysis:
    /// `sc` the scope it is answered in, `e` the condition, `kind` the construct
    void function(Scope* sc, Expression e, const(char)* kind, bool end) onCondition;
}
__gshared CtfeDebugHooks ctfeDebugHooks;
```

The adapter assigns the members directly in `compileWorker`
(`ctfeDebugHooks.onStatement = &ctfeStatementHook;` …) and clears them in its `scope (exit)`, so the
COM language-server path is untouched. There are no `setCtfe…Hook` setter functions any more — the
helper functions the front end used to offer moved to `ctfedebug.d` in `08b1d14488`.

* `onStatement` fires from `interpretStatement`. It takes a lock for every interpreted statement; a
  lock-free fast path (a volatile "are we interested?" flag) would cut the overhead.
* `onConstant` fires from `ctfeInterpret`, **after** its literal-expression fast path, so
  `enum int x = 5;` and every other already-constant expression never stops. `ctfeInterpret` is the
  right hook point rather than `interpret(e, null)`: it is the single entry for global constant
  folding, and hooking `interpret` would also fire for each call argument and stop twice per line.
  The end half runs in a `scope (exit)` at function scope, so it also runs when the interpretation is
  abandoned (`CtfeDebugAbort`, a compile error) and the debugger is never left with an unbalanced
  stack. The hook carries no `Scope*` — giving it one would mean plumbing a scope through every place
  the front end interprets a constant.
* `onReturn` fires from `interpretFunction` just before `--ctfeGlobals.callDepth` and
  `ctfeGlobals.stack.endFrame()`: the leaving frame is still on the CTFE stack, so a stop taken there
  sees its locals and the value being handed back together, and the value has already gone through
  the adjustments for a `ref` result.
* `onCondition` fires from `evalStaticCondition` (`expressionsem.d`) around `return impl(e)`, which
  brackets the whole answer including the calls of its clauses. It is reached from
  `visit(StaticIfCondition)` (`"static if"`), from `semantic2.d` (`"static assert"`) and from
  `evaluateConstraint` in `templatesem.d` (`"template constraint"`). The hook gets `e`, the
  expression being evaluated, not the `original` one `evaluateConstraint` passes (`td.constraint`):
  analyzing a condition rewrites that tree, and a frame built later would print the rewritten
  expression — the static assert of `ctfe_cond.d` once read
  `combine(T)(T a, T b) if (...)(2, 3) == 5`. The adapter takes the text of a condition once, when
  the hook begins. `evalStaticCondition` short-circuits `!`, `&&` and `||` structurally and analyzes
  the leaves one by one, so a whole condition never reaches `ctfeInterpret` — only its clauses do.
     The patch also re-indents a few lines of that function; keep the diff small when re-basing onto a
     new dmd.

  ## The debugged file is one module

  `compileWorker` parses the text of the launch `program` itself (`createModuleFromText` of
  `semvisitor.d`), and a module built that way has no package until one is given to it. The compiler
  resolves a root file after parsing it: `main.d` calls `Module.resolvePackage`, which takes the name
  and the packages from the `module` declaration — or the file name where there is none — and registers
  the module under it. The adapter does the same now. Left unresolved, `visuald\ctfedebug.d`, which
  declares `module visuald.ctfedebug;`, was the module `ctfedebug`, while the `import visuald.ctfedebug;`
  of `visuald\dpackage.d` read the same file again as a second module: the front end analysed the file
  twice and interpreted every constant in it twice, so each breakpoint stopped twice and the call stack
  showed `ctfedebug.T!5` beside `visuald.ctfedebug.T!5`. The import paths do not cause this — the name of
  the parsed root module comes from the file, not from the `-I` list, so having both `trunk\` and
  `trunk\visuald\` on it is harmless.

  The scratch fixture of `visuald\ctfedebug.d` replayed with the 8 breakpoints of a VS session stopped
  40 times before and stops 21 times now: the `T!5` chain of line 382 runs once instead of twice, and the
  `T!5 t3;` of line 375 is a second instantiation that legitimately stops again. `scenario_package_module()`
  holds the rule down with `ctfe_pkg/package.d` importing `ctfe_pkg/leaf.d`; without the call that scenario
  stops three times and names one of its frames `leaf.twice`.

  ## The call stack

DAP reports frames innermost first. `buildFrames` collects the interpreted calls from the
`InterState` chain, interleaves them with the instantiation frames, and closes the stack with the
context frames: the constant expressions being folded and the static conditions being answered.

* One `contexts` stack holds both kinds of front-end-started evaluation, in the order they began.
  They nest — answering a condition means interpreting the calls its clauses contain, and those are
  constants of their own. With the two in separate stacks, the condition was reported *above* the
  call it had triggered; one stack puts `evaluating big(3)` above the `static if` that called it.
* A context frame is named by the source text of its expression (`expressionText` =
  `Expression.toChars()`, wrapped in a `try` because the front end is mid-semantic, falling back to
  `static initialization`) with an `evaluating ` prefix; a condition frame is named
  `static if (…)`, `static assert (…)` or `template constraint (…)` from the `kind` the hook
  reports. The frame sits at the expression's own location, so clicking it jumps to the declaration
  of the constant. Only the innermost context gets the CTFE value range for the locals; the
  temporaries of the outer ones are already covered by the function frames.
* An instance gets one `instantiating <qualified name>` frame, placed below the outermost call that
  runs its code, located at `ti.loc` — the site the instance was created at. `frameInstances(fr)`
  walks `istate.fd.parent` (template mixins are skipped, the enclosing template owns the trail, up to
  32 per frame); `containsInstance` keeps an instance from showing twice. The interpreter keeps no
  instantiation trail of its own (`TemplateInstance.tinst` is scoped to null while CTFE runs), but
  every symbol knows the scope it was declared in. A recursive instance gets one frame per level,
  which is the point: the step from `Chain!3` to `Chain!2` has a frame of its own between the two
  calls.
* `contextFrames` closes the stack with the constants and the conditions, innermost first, and gives
  every frame the instances of its scope: a condition takes the scope the hook reported, a constant the
  scope of the condition it is a clause of (`conditionScope`). A condition frame is therefore followed
  by the instances it is written in (`scopeInstances` walks `Scope.enclosing` and `Scope.func`) — and
  only a condition emits those instance frames, so they are not repeated under every clause evaluation.
* Such a frame has no `InterState` and no CTFE value range; its locals are the arguments of those
  instances, which is also where a watch of an instance argument at a condition resolves (`T` at the
  `static if` of `Box` reads `int`).
  Frame ids are handed to the call frames first and to the extra frames after, so they are unique but
  not contiguous. The stack is capped at 64 frames beyond the calls.
* Expandable values get their own handles; they start at `firstValueHandle` (0x10000) because the
  references of the first struct or array local used to collide with frame ids, and a `variables`
  request could be answered with the locals of a frame.
* A frame for a global expression has no return address — the reason stepping out used to run off the
  end of the evaluation, which the declaration stop below replaces.

## Locals: parameters, template arguments, definitions of the instance

* There is exactly one scope, `Locals` with `presentationHint: "locals"`. Visual Studio renders *all*
  scopes of a frame in the Locals window: the Debug Adapter Host flattens the scopes flagged as
  locals/arguments (keyed on that hint and the `localsScopeName` launch property) and shows every
  other scope as a node, and DAP has no implicit or hidden scope. A `Constants` node listing every
  manifest constant of the module was therefore wrong; the constants stay reachable by name through
  `findGlobalConstant`.
* Compiler-generated locals (`__key*`, `__limit*`, …) are filtered out (`STC.temp`).
* Template arguments are bound when the instance is created and never reach the CTFE value stack, so
  they are read from the instance: `instanceArguments(ti)` walks the *formal parameters* of the
  template and pairs each name with `ti.tdtypes[i]`, falling back to `ti.tiargs[i]`. That fallback
  matters while a constraint is being answered: `tdtypes` is already sized but its entries are null,
  the arguments as written are in `tiargs`, and for a call that deduces or defaults every argument
  `tiargs` is still empty at the `matchWithInstance` that evaluates the constraint — `templatesem.d`
  fills it with the deduced arguments only before the second of its two constraint call sites.
  Nested instances contribute together, innermost first; a variadic parameter holds a `Tuple` and
  expands to `[0]`, `[1]`, …
* `instanceNames(ti)` = `instanceArguments(ti)` ~ `instanceDefinitions(ti)`: the members of the
  instance that stand for a value or a type — a manifest constant (preferring the value the
  interpreter has already folded, `CTFE.globalValues` at `ctfeAdrOnStack`), the type or symbol of an
  alias, the type of an enum or aggregate declaration. Functions, fields and nested templates are
  neither; template parameters and the compiler's own `__` names are skipped; 16 definitions per
  instance so a template naming a great many things cannot fill the window. A template that declares
  an aggregate of its own name *is* that aggregate (`TemplateInstance.aliasdecl`), so `Stats!int`
  offers the members of the struct it generates. Names are searched innermost instance first and
  `containsName` keeps an outer instance from contributing a shadowed name — otherwise a recursive
  template would list `dim` once per level.
* The value a call hands back is reported as a pseudo-local `$returnValue` of the frame, and
  `frameLookup` resolves the name, so hover, watch, immediate and a breakpoint condition can compute
  with it (`$returnValue + 1`, `$returnValue * factor`). A `$` cannot clash with a name of the
  program, and `isIdentStart` accepts it. It is a name rather than a DAP scope with
  `presentationHint: "returnValue"` because the VS 18 Debug Adapter Host never reads that hint and
  nothing sets `DBG_ATTRIB_VALUE_RETURN_VALUE` from adapter data. `reportableValue` drops the pseudo
  expressions the interpreter uses for void, for a call it could not interpret, for unwinding, and
  the exception of a call that does not catch it. A void call ends a step without the name; a `ref`
  result reports the element it stands for.
* Struct *and class* values expand their fields. A class value is a reference, but `new Triangle` is
  interpreted into a `ClassReferenceExp` whose `value` is a `StructLiteralExp` holding the field
  values and whose `originalClass()` names the class. The elements are stored base class first —
  `AggregateDeclaration.fields` holds only the fields a class declares itself — so the names come
  from walking the base chain in that order, skipping `Object.__monitor`, which this front end leaves
  out of the elements:

  ```d
  static StructLiteralExp aggregateLiteral(Expression e)      // ctfedebug.d
  {
      if (auto sl = e.isStructLiteralExp()) return sl;
      if (auto cr = e.isClassReferenceExp()) return cr.value;
      return null;
  }

  static VarDeclaration[] aggregateFields(Expression e)
  {
      if (auto sl = e.isStructLiteralExp())
          return sl.sd ? sl.sd.fields[] : null;

      auto cr = e.isClassReferenceExp();
      ClassDeclaration cd = cr is null ? null : cr.originalClass();
      if (cd is null) return null;

      ClassDeclaration[] chain;
      for (ClassDeclaration c = cd; c; c = c.baseClass)
          chain ~= c;

      VarDeclaration[] fields;
      for (size_t i = chain.length; i-- > 0; )
          foreach (VarDeclaration v; chain[i].fields)
              if (v !is null && (v.ident is null || v.ident.toString() != "__monitor"))
                  fields ~= v;
      return fields;
  }
  ```

  `valueChildren`, `childHandle` and the member access of the expression evaluator all use them, so
  an instance expands in the locals tree, in the watch and on hover, and `nm.shape.sides` evaluates.
  The type column stays the static type (`ctfe_class.Shape`) while the children come from the
  instance it points at.

## Values and types come from the compiler's printers

The adapter used to spell instance names itself (~120 lines: `instanceOfType`, `instanceText`,
`instanceNameOf`, `argumentText`, `isSimpleArgument`, `isGeneratedOf`). That re-implementation had to
be kept in step with `hdrgen.d` by hand, so it is gone:

* `typeText(Type)` is `t.toChars()`. `toChars` sets `fullQual` for a class, so a class type carries
  its module and a struct type does not — `ctfe_values.Obj!(Box!int)` rather than `Obj!(Box!int)`.
* `visitEnum`/`visitStruct`/`visitClass` (`hdrgen.d:4536`) print the instance an aggregate was
  generated from (`t.sym.parent.isTemplateInstance()`, used when `ti.aliasdecl == t.sym`); the
  identity test says directly what `isGeneratedOf` compared names for.
* `tiargsToBuffer` (`hdrgen.d:4047`) holds the parenthesis rule: one simple argument reads
  `Box!int`, `Cell!7`, `Name!"abc"`, anything else `Wrap!(Box!int)`, `Pair!(int, string)`,
  `Node!(Leaf)`.
* Two renderings stay adapter-side, because the compiler prints *source*, where the arguments are
  written where the name is used and a debugger has no source there: `aggregateLiteralText` (a
  struct, class or union value reads `Box!int(3)`, its members recurse) and `instanceAddressText`
  (`visitSymOff` prints the function, not the instance, so `& fn!int` comes from the adapter; it
  tests `ti.aliasdecl is s` and spells the name with `ti.toChars()`).
* The instance a value or type names is spelled from `tdtypes` (as the compiler evaluated them), not
  `tiargs` (as written), so `T!(x-1)` reads as the instance that was built, `T!4`. The Call Stack
  names were spelled that way already, so values and frames now agree.

## Stepping

* A return is a step of its own (`returnIsStep`): always while stepping in, and while stepping over
  in the frame the user stepped from (`ctfeCallDepth() == stopCallDepth`; the call that is stepped
  over returns one deeper). A plain `continue` runs through returns. The stop reports the position of
  the last statement the frame ran (its `return`), or the declaration of a function that just falls
  off the end, with `$returnValue` in the locals.
* `stepOut` ends at the **call site**: the caller's frame is reported at `callSiteLoc()`, the
  statement the caller's statement hook last recorded, carrying the value as `$returnValue`. The
  frame that is leaving is still on the CTFE stack at the hook, so its values are cut off at
  `InterState.stackBase` and none of them shows as a local of the caller; `suspend` also takes the
  call depth the next step starts from, one shallower, or a `stepOut` from the call site would end at
  the very next statement.
* A step that runs off the last frame of the evaluation ends at the **declaration of the constant**:
  `declarationLoc()` is the location of the innermost context, the line the constant is declared on,
  and the frame of the declaration gets `$returnValue` (its locals are cut at
  `ctfeCurrentFrameBase()`, so it has only that name). `stopAtDeclaration` ends a `next`/`stepIn`
  there, `onReturn`'s step-out branch ends a `stepOut` there, and the stepping mode then goes to
  `none` — the evaluation of that constant is over and what the front end interprets next is code of
  its own.
* The same one step after a stepped return, one frame deeper, ends at the **call site** of the
  caller (`callSiteStop` / `stopAtCallSite`): between the return of a call and the statement the
  caller resumes at, the interpreter has no position of the program.
* A step never reports where the user already is. `lastStopLoc` records the last stop and
  `samePosition` compares positions as the user sees them (the file name of a `Loc` is a separate
  string for the same file, so names compare through `normalizedPathOf`). A return stop that would
  report the line the user stepped off is taken at the position the value goes back to instead —
  which is why a `next` over a `return` needs one step, not two. The return stop is still taken when
  it does move the marker (a `return` reached from another line, a body that ends without one).
* What the locals look like at a call-site stop: the call has returned but the assignment its
  statement performs has not run, so `base` and `v` are still empty there and filled in by the step
  on. The reported position is the statement the call sits in, not the call expression: a call
  written across several lines reports the line its statement starts on, and a call in a loop
  condition reports the line of the loop.
* A void function, a struct destructor and a `ref` result behave as expected: the void ones stop as a
  plain step with no `$returnValue`, a `ref` result reports the element it stands for (`[3, 4][0]`),
  and the return of `use` shows its value only after the destructor of the local struct has run, as
  CTFE orders it.
* `stepOut` ignores `frameId`: it always leaves the innermost frame, whatever the call stack window
  has selected.

## Breakpoints

* A breakpoint on a manifest declaration (`enum sum = test();`) stops at the declaration, named by
  its initializer expression, because of the `onConstant` hook. Every form stops exactly once at its
  own line: `enum`, `const`, `immutable`, an array-typed `enum`, a template call, `static assert`, a
  local `enum` inside a function.
* A static condition is a position for a *breakpoint* and for nothing else: `checkStop` takes a
  `condition` flag and returns after the breakpoint loop, so `stopOnEntry` and every step mode walk
  past conditions — otherwise stepping anywhere pulls the `static assert`s and `static if`s of
  druntime past the user before a line of their own program.
* The front end answers the question again for every instantiation it creates, so a breakpoint on a
  constraint hits once per instantiation, each hit carrying that instantiation on the stack below the
  condition; a `static if` in an instance body hits once, because the body is generated once. Two
  same-named templates with different constraints each answer theirs, so a breakpoint on both lines
  hits for each instantiation, the frame text and the `instantiating` frame below saying which.
* Two rules keep one position from stopping twice for the same event: `onConstant` skips a constant
  at exactly the position of the innermost condition (the condition of a `static assert` usually *is*
  the constant expression being interpreted), and the breakpoint loop skips a line once the
  innermost condition has stopped there, as the calls of its clauses are written at that position.
* Breakpoint conditions are evaluated by the adapter's own evaluator and can read globals, instance
  names and `$returnValue`. `k == 7` used to stop at every non-zero `k`: `evalOperation` handled
  `==`/`!=` by calling `evalBool` on both operands before the integer path, making `k == 7` into
  `(k != 0) == (7 != 0)`. It now takes that path only when both operands have static type `bool`
  (`isBoolExpr`, `t.toBasetype() is Type.tbool`). `evaluate` results alone would not have shown the
  bug — `k == 3` at `k = 0` was false before the fix too; the scenario assertions are the regression
  test.
* `setBreakpoints` responses must carry an `id` per breakpoint, or VS warns
  "Verified breakpoint missing 'id' field!". Nothing may be sent after a client `disconnect` —
  `clientDisconnected` suppresses `output`, `exited` and `terminated`.
* The answer has **one entry per requested breakpoint, in the order the client asked** — the DAP pairs
  them by index. The adapter used to `bps.sort` them, which is invisible to a client that happens to
  send its breakpoints sorted by line and a desynchronising one for any other: VS hands them over in
  the order they were created, pairs each answer with the wrong breakpoint, and moves or deletes the
  markers accordingly (a red dot vanishes from a line the adapter still stops at, and a line the user
  clicked never stops again). `checkStop` matches a stop to a breakpoint by line alone, so the order
  the list is kept in does not matter internally. A request without a `line` keeps its place and is
  answered `verified: false` with a message instead of being dropped.
* Set `CTFE_DAP_LOG` to a file name before starting VS to record the traffic of every session: the
  adapter appends each request as `--> {…}` and each answer and event as `<-- {…}`, in wire order.
  `DapConnection.log` takes the connection's write lock, because the client thread and the compile
  worker and console capture threads all write to it — opening the file from two of them at once used
  to fail and silently switch logging off after a few dozen messages.

## Expression evaluation

* `frameLookup(ref CtfeFrame fr, string name)` resolves a name in one frame only: the value the frame
  hands back, then the locals and parameters of that frame, then the names of its instances.
  `evalLookup` consults that frame alone and falls back to a global constant. Hovering a name in the
  source of a template instantiation used to walk outwards and answer with the locals of an outer
  function — `b` of `main` at a stop inside `Cell!7.get` — which hides that the name is not readable
  there; it now reports `'b' not found in scope`.
* `evalLookup` has an `out bool found`: a type argument *is* in scope, it just has no `Expression` to
  hand out, so that reads `'T' is not a value` rather than `'T' not found in scope`.
* The evaluator is a small recursive-descent parser over the values of the frame: `arr[2]`, `p.x`,
  `p.y + 1`, `s.length`, `s == "abc"`, `arr[0] + arr[1]`, `arr.length`, `flag ? 12 : 34`,
  `p.x > 5 && p.y < 10`, member access through a class instance. Errors come back as messages
  (`'k' not found in scope`, `unexpected end of expression`). It does not resolve function names or
  members of a type: `g` at a condition frame answers `'g' not found in scope`, `T.max` answers
  `'T' is not a value`.
* Everything is read-only — `setVariable` is not advertised, which is right for CTFE. VS warns that
  the adapter has no `value formatting`; stack formatting is unavailable, and could be advertised if
  the display needs it.

## Console output and compile-time errors

Compile-time errors reach the client through the front end's `diagnosticHandler` callback, forwarded
as DAP `output` events; the front end does not also print them to stderr, so nothing is duplicated.
`pragma(msg)` and `__ctfeWrite` write straight to the C streams, so `ConsoleCapture` redirects them:
for each of fds 0/1/2 it saves the descriptor (`_dup`), points the fd at a pipe (`_open_osfhandle` +
`_dup2`) and sets the stream unbuffered (`setvbuf(_IONBF)`); a reader thread per stream blocks in
`ReadFile` and emits each chunk as an `output` event, category `stdout` for fd 1 and `stderr` for
fd 2. `stop()` restores the saved descriptors, closes the write ends and joins the readers; it runs
first thing in `finishCompilation()` and again before `ctfeDebugRun` returns, so no reader outlives
the session. `_dup` and `_dup2` are missing from the druntime `core.stdc.stdio` bindings and are
declared `extern (C)` locally.

* Text arrives in the chunks the C library wrote, not one line per event — an unbuffered
  `fprintf(stderr, "%.*s", …)` comes out in two pieces; the client concatenates them, and a chunk
  boundary can split a multi-byte character.
* `DapConnection` duplicates the handles it gets from `GetStdHandle`: `_dup2` closes the handle a C fd
  previously referred to, and for fds 1 and 2 that is the very handle `GetStdHandle` hands out. With
  the capture installed the cached `hOut` was a closed handle, every `WriteFile` failed, and the
  client got no answer to any request — which is why every request in the harness burned its full 30 s
  timeout. Creating the connection after the capture would not help either.
* `send` takes the message object and assigns `seq` inside `synchronized (writeLock)`: output events
  come from the capture threads as well, so the sequence number must not race with the worker thread.

## Visual Studio as the DAP client — verified in VS 2022 17.14

`launch.json` (this folder) is the VS launch configuration; for the smoke test it names the adapter
inline with `$adapter`/`$adapterArgs`, so no engine registration is needed, and `$engineGuid` only
selects which AD7 engine VS starts (the Debug Adapter Host). The engine GUID is
`002a2de9-8bb6-484d-982a-7e4ad4084715` (`g_ctfeDebugEngineCLSID` in `visuald\dpackage.d`); VS 18
(2026) has the identical host, CLSID and commands. Driving it over DTE
(`GetActiveObject("VisualStudio.DTE.17.0")`):

```
DebugAdapterHost.Logging /On:<file>
DebugAdapterHost.Launch /LaunchJson:"...\ctfe_debug\launch.json" /ConfigurationName:"CTFE"
```

End to end in one session (host log): `initialize` → `launch` → `initialized` → `setBreakpoints`
(`ctfe_expr.d:22`, verified, id 1) → `setExceptionBreakpoints` → `configurationDone` →
`stopped reason=breakpoint` → `threads` → `stackTrace` (`ctfe_expr.loop`, line 22) → `scopes`
(Locals only) → `variables` (`n 20`, `total 0`, `k 0`) → `evaluate "total + k"` → 0,
`"k == 3"` → false → `Debug.StepOver` → `stopped reason=step` at line 21 → `Debug.StopDebugging` =
`disconnect` → the adapter process exits. DTE's `Debugger.CurrentMode` went Design → Run → Break, and
`Debugger.GetExpression` returned the same values as the adapter, so the Locals/Immediate windows are
fed through AD7. Three adapter bugs this exposed are fixed: the missing breakpoint `id`, sending
events after `disconnect`, and answering `setBreakpoints` with the breakpoints sorted by line.

A live VS 18 (2026) session on `visuald\ctfedebug.d` showed what the sorted answer does to a real
client: the marker of one breakpoint vanished from the editor while the adapter still stopped there,
and a line the user had clicked was never offered to the adapter again, so it never stopped there.
VS hands its breakpoints over in the order they were created, so pairing the answer by index against
a sorted array moves every marker to the line of a neighbour.  Replaying that session's
`%TEMP%\visuald-ctfe-<name>.launch.json` head-lessly, with the eight breakpoints in the order the DTE
enumerates them, answers them in that order and stops at every one of them.

The adapter also answers the `source` request with the text of the file it named, stripping a UTF-8
BOM because the client decodes the text itself; it used to reply "unsupported request: source".
Whether VS asks for one in a CTFE session is for the `CTFE_DAP_LOG` of a live session to tell.

Still open on the VS side:

* `"$adapterArgs"` in launch.json has to be a **string**; an array makes VS 17.14 throw a
  `JsonReaderException` while parsing the configuration.
* Engine registration cannot be tested by writing the registry: dropping
  `AD7Metrics\Engine\{002a2de9-…}` with `Adapter`/`AdapterArgs` into the instance hive and the root
  hive has no effect (`DebugAdapterHost.Launch` then fails with "Path to debug adapter executable not
  specified", " 'Language'/'LanguageId' not specified in engine registration"). VS 2017+ keeps the
  merged configuration in `<instance>\privateregistry.bin`, and a hand-dropped per-user extension was
  indexed into `ExtensionMetadata.mpack` but its pkgdef was not merged. So the registration can only
  be verified through a real extension install, which needs admin rights.
* Setting a breakpoint condition from DTE: `Breakpoint.ConditionType` sets, but assigning `Condition`
  from PowerShell fails ("Cannot find an overload"), so VS-side conditional breakpoints are untested
  through automation — the adapter side is covered by the suite.
* Adding a breakpoint from DTE: `Debugger.Breakpoints.Add(file, line)` fails with "Multiple locations
  specified for new breakpoint."; `Edit.GoTo 22` + `Debug.ToggleBreakpoint` works once the document
  has been `Activate()`d. `Debugger.AllBreakpoints` reports 0 while `Debugger.Breakpoints` holds it.
* Driving VS 2022 from `Start-Process` is unreliable here (it can exit after a few minutes, taking the
  DTE/ROT entry with it); an interactively started instance is stable.
* VS's DTE keeps reporting `vsDebugModeRun` after the session ends — looks like a DTE/ROT artifact
  (the shell title shows no debug mode, a freshly started VS reports mode 1 too), worth re-checking in
  the IDE UI.

## Product integration in Visual D (code complete, build verified, not yet run)

* `visuald\ctfedebug.d`: `StartCtfeDebug()` takes the active `.d`/`.di` editor file, builds a
  `CtfeLaunchConfig` from the project settings the way `ConfigureSemanticProject` does (import paths,
  string import paths, version IDs, debug IDs, `dmdFrontEndOptions()`, project dir as working
  directory; global DMD options when the file is not in a project), writes
  `%TEMP%\visuald-ctfe-<name>.launch.json` and runs the verified `DebugAdapterHost.Launch` command.
  The fallback path uses `IVsDebugger4.LaunchDebugTargets4` with the engine GUID and the
  single-configuration JSON as `bstrOptions`; that fallback is still untested. The session always
  debugs the file **on disk** — unsaved editor changes are ignored (no `IVsTextBuffer.GetAllTextLines`
  binding in the D SDK bindings). Uncommitted in that file: a `version(all)` block preferring
  `c:\s\d\visuald\trunk\bin\Debug COFF32\x64\dmdserver.exe` when it exists, and a scratch fixture at
  the end of the file.
* Command plumbing: `CmdStartCtfeDebug` (`0x128`) in `visuald\Resources\resources.h`, a button in the
  Debug command group in `pkgcmd.vsct` ("Start CTFE Debugger"), `QueryStatus`/`Exec` cases in
  `visuald\dpackage.d`, the file in `visuald\visuald.visualdproj`.
* Engine registration in `visuald\register.d` (for `ver >= 15`, so it lands in the shipped
  `visuald.pkgdef`): `AD7Metrics\Engine\{002a2de9-8bb6-484d-982a-7e4ad4084715}` with
  `CLSID={DAB324E9-7B35-454C-ACA8-F6BB0D5C8673}` (the Debug Adapter Host engine),
  `Name="D CTFE Debugger"`, `Language`/`LanguageId` = the D language service, `AlwaysLoadLocal=1`,
  `AddressBP=CallStackBP=SetNextStatement=Attach=SupportsEESearch=0`, and `Adapter=<install
  dir>\dmdserver.exe` + `AdapterArgs=-ctfeDebug` when that file exists. `SetNextStatement` and
  `Exceptions` are off because the adapter implements neither `goto`/`gotoTargets` nor exception
  filters.
* Build verification: `ctfedebug.d` and `register.d` compile clean with the project dmd
  (`-d -m64 -c -w -I.. -Jresources -J..`), `pkgcmd.vsct` compiles with VSCT.exe (0 errors, 0 warnings,
  `.cto` 2448 → 2578 bytes), and the extension links (`bin\Release COFF32\x64\VisualD.dll`).
* Not verified at runtime: the menu command in a running VS, the pkgdef registration, and the
  `LaunchDebugTargets4` fallback. That needs the new `VisualD.dll` **and** a `-ctfeDebug` capable
  `dmdserver.exe` installed into `C:\Program Files (x86)\VisualD\` (admin), plus a VS restart.
* Cosmetic: `dmdserver.exe` is a console program, so starting it as an adapter can pop up a console
  window — `FreeConsole()` in `ctfeDebugRun`, or a GUI-subsystem build of the server.

## Known issues and open ends

1. A *local* `enum` inside a function stops twice: once while the function body is analyzed (its
   initializer as its own frame) and again when the function is interpreted. Firing `onConstant` only
   for initializers not inside a `FuncDeclaration` is worth considering.
2. `enum int[3] arr = [addup(1), addup(2), addup(3)];` stops once per element, all at the declaration
   line, because each element is folded separately — VS shows three stops on one line.
3. Stepping on past the last constant of the file being debugged stops at the global constants of
   druntime (`evaluating 37 / 2` in `object.d`), because the front end goes on interpreting once the
   entered file is through. Ending the session with the semantic analysis of that file, or reporting
   other files' stops only once they are opened, would keep the user inside their own code.
4. A breakpoint on a line the interpreter never reports (the closing brace of a body, a blank line) is
   reported `verified: true` but can never be hit — the body of a function is reported at the line of
   its last statement, not at the brace. Binding it to the next statement the interpreter reports, or
   reporting it unverified, would tell the user why their breakpoint is ignored. (The `BP_CELL` and
   `BP_NODE` marks of `ctfe_values.d` sat on closing braces and were moved to the `return`s.)  A
   manifest constant inside a `static if` that is taken is another case: the `enum done = true;` of
   `visuald\ctfedebug.d:338` gets a solid marker in VS and never stops, because nothing on that line is
   ever interpreted.
5. A name the front end has not folded yet reads as its initializer (`b` → `loop(20)`), for global
   constants and for the manifest constants of an instance alike. The labelling of not-yet-interpreted
   constants is undecided.
6. The frame text of a constant is the *unqualified* source text; the declaration name (`e1 = …`) is
   not part of the `ExpInitializer`, and `toChars()` is not the exact source spelling.
7. `evaluateConstraint` declares the parameters of a *function* template in the scope of its
   constraint, so the constraint frame of `pick` could show `a` and `i` beside `N` and `T`; they have
   no interpreted value while the constraint is answered, and the adapter has nothing to report for a
   name it cannot resolve to a value. Related: the expression evaluator resolves names from the
   variables of the frame only, so a function name in the watch answers "not found in scope".
8. `onStatement` takes a lock for every interpreted statement; a volatile "interested?" fast path
   would cut the interpreter overhead.
9. Which VS window shows `$returnValue` has still to be seen in a live session: the adapter has one
    locals scope and no way to have the host mark one of its variables as the return value.
10. The end of a run is reported inconsistently: the adapter does not send `terminated` (the scenarios
    check the process exit code instead), and the completion of a run to a breakpoint is not always
    seen by the client — `scenario_temps` printed `terminated: False` although the process exited 0.
    `restart` is not implemented.
11. Commit: dmd submodule first (the `onCondition` hook), then Visual D, then the `ctfe_debug/`
     harness folder.
12. A debugged file whose name is not an identifier (`ctfe-cond.d`) is still read twice when another
     module imports it: `resolvePackage()` rejects such a name, and the debugger deliberately keeps
     reading files the compiler would refuse.
