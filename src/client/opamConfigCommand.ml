(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012 OCamlPro                                          *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  OPAM is distributed in the hope that it will be useful,            *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

let log fmt = OpamGlobals.log "CONFIG" fmt

open OpamTypes
open OpamState.Types

let full_sections l =
  String.concat " " (List.map OpamVariable.Section.Full.to_string l)

let string_of_config_option t =
  Printf.sprintf "rec=%b bytecode=%b link=%b options=%s"
    t.conf_is_rec t.conf_is_byte t.conf_is_link (full_sections t.conf_options)

let string_of_config = function
  | CEnv csh    -> Printf.sprintf "env(csh=%b)" csh
  | CList       -> "list-vars"
  | CVariable v -> Printf.sprintf "var(%s)" (OpamVariable.Full.to_string v)
  | CCompil c   -> string_of_config_option c
  | CSubst l    -> String.concat "," (List.map OpamFilename.Base.to_string l)
  | CIncludes (b,l) ->
      Printf.sprintf "include(%b,%s)"
        b (String.concat "," (List.map OpamPackage.Name.to_string l))

(* List all the available variables *)
let config_list t =
  let configs =
    OpamPackage.Set.fold (fun nv l ->
      let file = OpamState.dot_config t (OpamPackage.name nv) in
      (nv, file) :: l
    ) t.installed [] in
  let variables =
    List.fold_left (fun accu (nv, c) ->
      let name = OpamPackage.name nv in
      (* add all the global variables *)
      let globals =
        List.fold_left (fun accu v ->
          (OpamVariable.Full.create_global name v, OpamFile.Dot_config.variable c v) :: accu
        ) accu (OpamFile.Dot_config.variables c) in
      (* then add the local variables *)
      List.fold_left
        (fun accu n ->
          let variables = OpamFile.Dot_config.Section.variables c n in
          List.fold_left (fun accu v ->
            (OpamVariable.Full.create_local name n v,
             OpamFile.Dot_config.Section.variable c n v) :: accu
          ) accu variables
        ) globals (OpamFile.Dot_config.Section.available c)
    ) [] configs in
  List.iter (fun (fv, contents) ->
    OpamGlobals.msg "%-20s : %s\n"
      (OpamVariable.Full.to_string fv)
      (OpamVariable.string_of_variable_contents contents)
  ) (List.rev variables)

(* Return the transitive closure of dependencies sorted in topological order *)
let get_transitive_dependencies t ?(depopts = false) names =
  let universe = OpamState.universe t Depends in
  (* Compute the transitive closure of dependencies *)
  let packages = OpamPackage.Set.of_list (List.map (OpamState.find_installed_package_by_name t) names) in
  OpamSolver.backward_dependencies ~depopts universe packages

let config_includes t is_rec names =
  let deps =
    if is_rec then
      List.map OpamPackage.name (get_transitive_dependencies t ~depopts:true ~installed:true names)
    else
      names in
  let includes =
    List.fold_left (fun accu n ->
      "-I" :: OpamFilename.Dir.to_string (OpamPath.Switch.lib t.root t.switch n) :: accu
    ) [] (List.rev deps) in
  OpamGlobals.msg "%s\n" (String.concat " " includes)

let config_compil t c =
  let comp = OpamState.compiler t t.compiler in
  let names =
    OpamMisc.filter_map
      (fun (n,_) ->
        if OpamPackage.Set.exists (fun nv -> OpamPackage.name nv = n) t.installed
        then Some n
        else None)
      (OpamFormula.atoms (OpamFile.Comp.packages comp))
    @ List.map OpamVariable.Section.Full.package c.conf_options in
  (* Compute the transitive closure of package dependencies *)
  let package_deps =
    if c.conf_is_rec then
      List.map OpamPackage.name (get_transitive_dependencies t ~depopts:true ~installed:true names)
    else
      names in
  (* Map from libraries to package *)
  (* NOTES: we check that the set of packages/libraries given on
     the command line is consistent, ie. there isn't two libraries
     with the same name in the transitive closure of
     depedencies *)
  let library_map =
    List.fold_left (fun accu n ->
      let nv = OpamState.find_installed_package_by_name t n in
      let opam = OpamState.opam t nv in
      let sections = (OpamFile.OPAM.libraries opam) @ (OpamFile.OPAM.syntax opam) in
      List.iter (fun s ->
        if OpamVariable.Section.Map.mem s accu then
          OpamGlobals.error_and_exit "Conflict: the library %s appears in %s and %s"
            (OpamVariable.Section.to_string s)
            (OpamPackage.Name.to_string n)
            (OpamPackage.Name.to_string (OpamVariable.Section.Map.find s accu))
      ) sections;
      List.fold_left (fun accu s -> OpamVariable.Section.Map.add s n accu) accu sections
    ) OpamVariable.Section.Map.empty package_deps in
  (* Compute the transitive closure of libraries dependencies *)
  let library_deps =
    let graph = OpamVariable.Section.G.create () in
    let todo = ref OpamVariable.Section.Set.empty in
    let add_todo s =
      if OpamVariable.Section.Map.mem s library_map then
        todo := OpamVariable.Section.Set.add s !todo
      else
        OpamGlobals.error_and_exit "Unbound section %S" (OpamVariable.Section.to_string s) in
    let seen = ref OpamVariable.Section.Set.empty in
    (* Init the graph with vertices from the command-line *)
    (* NOTES: we check that [todo] is initialized before the [loop] *)
    List.iter (fun s ->
      let name = OpamVariable.Section.Full.package s in
      let sections = match OpamVariable.Section.Full.section s with
        | None   ->
          let config = OpamState.dot_config t name in
          OpamFile.Dot_config.Section.available config
        | Some s -> [s] in
      List.iter (fun s ->
        OpamVariable.Section.G.add_vertex graph s;
        add_todo s;
      ) sections
    ) c.conf_options;
    (* Also add the [requires] field of the compiler description *)
    List.iter (fun s ->
      OpamVariable.Section.G.add_vertex graph s;
      add_todo s
    ) (OpamFile.Comp.requires comp);
    (* Least fix-point to add edges and missing vertices *)
    let rec loop () =
      if not (OpamVariable.Section.Set.is_empty !todo) then
        let s = OpamVariable.Section.Set.choose !todo in
        todo := OpamVariable.Section.Set.remove s !todo;
        seen := OpamVariable.Section.Set.add s !seen;
        let name = OpamVariable.Section.Map.find s library_map in
        let config = OpamState.dot_config t name in
        let childs = OpamFile.Dot_config.Section.requires config s in
        (* keep only the build reqs which are in the package dependency list
           and the ones we haven't already seen *)
        List.iter (fun child ->
          OpamVariable.Section.G.add_vertex graph child;
          OpamVariable.Section.G.add_edge graph child s;
        ) childs;
        let new_childs =
          List.filter (fun s ->
            OpamVariable.Section.Map.mem s library_map && not (OpamVariable.Section.Set.mem s !seen)
          ) childs in
        todo := OpamVariable.Section.Set.union (OpamVariable.Section.Set.of_list new_childs) !todo;
        loop ()
    in
    loop ();
    let nodes = ref [] in
    OpamVariable.Section.graph_iter (fun n -> nodes := n :: !nodes) graph;
    !nodes in
  let fn_comp = match c.conf_is_byte, c.conf_is_link with
    | true , true  -> OpamFile.Comp.bytelink
    | true , false -> OpamFile.Comp.bytecomp
    | false, true  -> OpamFile.Comp.asmlink
    | false, false -> OpamFile.Comp.asmcomp in
  let fn = match c.conf_is_byte, c.conf_is_link with
    | true , true  -> OpamFile.Dot_config.Section.bytelink
    | true , false -> OpamFile.Dot_config.Section.bytecomp
    | false, true  -> OpamFile.Dot_config.Section.asmlink
    | false, false -> OpamFile.Dot_config.Section.asmcomp in
  let strs =
    fn_comp comp ::
      List.fold_left (fun accu s ->
        let name = OpamVariable.Section.Map.find s library_map in
        let config = OpamState.dot_config t name in
        fn config s :: accu
      ) [] library_deps in
  let output = String.concat " " (List.flatten strs) in
  log "OUTPUT: %S" output;
  OpamGlobals.msg "%s\n" output

let empty_env = {
  add_to_env  = [];
  add_to_path = OpamFilename.raw_dir "";
  new_env     = []
}

let print_env env =
  if env <> empty_env then
    List.iter (fun (k,v) ->
      OpamGlobals.msg "%s=%s; export %s;\n" k v k;
    ) env.new_env

let print_csh_env env =
  if env <> empty_env then
    List.iter (fun (k,v) ->
      OpamGlobals.msg "setenv %s %S;\n" k v;
    ) env.new_env

let config request =
  log "config %s" (string_of_config request);
  let t = OpamState.load_state () in
  match request with
  | CEnv csh                  ->
    let env = OpamState.get_env t in
    if csh
    then print_csh_env env
    else print_env env
  | CList                     -> config_list t
  | CSubst fs                 -> List.iter (OpamState.substitute_file t) fs
  | CIncludes (is_rec, names) -> config_includes t is_rec names
  | CCompil c                 -> config_compil t c
  | CVariable v               ->
    let contents = OpamState.contents_of_variable t v in
    OpamGlobals.msg "%s\n" (OpamVariable.string_of_variable_contents contents)
