(*********************************************************************************)
(*                Stog                                                           *)
(*                                                                               *)
(*    Copyright (C) 2012-2013 Maxence Guesdon. All rights reserved.              *)
(*                                                                               *)
(*    This program is free software; you can redistribute it and/or modify       *)
(*    it under the terms of the GNU General Public License as                    *)
(*    published by the Free Software Foundation, version 3 of the License.       *)
(*                                                                               *)
(*    This program is distributed in the hope that it will be useful,            *)
(*    but WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the               *)
(*    GNU Library General Public License for more details.                       *)
(*                                                                               *)
(*    You should have received a copy of the GNU General Public                  *)
(*    License along with this program; if not, write to the Free Software        *)
(*    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA                   *)
(*    02111-1307  USA                                                            *)
(*                                                                               *)
(*    As a special exception, you have permission to link this program           *)
(*    with the OCaml compiler and distribute executables, as long as you         *)
(*    follow the requirements of the GNU GPL in regard to all of the             *)
(*    software in the executable aside from the OCaml compiler.                  *)
(*                                                                               *)
(*    Contact: Maxence.Guesdon@inria.fr                                          *)
(*                                                                               *)
(*********************************************************************************)

(** *)

open Stog_types;;
module Smap = Stog_types.Str_map;;

type 'a level_fun =
  | Fun_stog of (stog Xtmpl.env -> stog -> elt_id list -> stog)
  | Fun_data of ('a Xtmpl.env -> stog * 'a -> elt_id list -> stog * 'a)
  | Fun_stog_data of ((stog * 'a) Xtmpl.env -> stog * 'a -> elt_id list -> stog * 'a)

type 'a engine = {
      eng_data : 'a ;
      eng_levels : 'a level_fun Stog_types.Int_map.t ;
      eng_name : string ;
    }

module type Stog_engine = sig
    type data
    val engine : data engine

    type cache_data
    val cache_load : data -> elt -> cache_data -> data
    val cache_store : data -> elt -> cache_data
  end

type stog_state =
  { st_stog : stog ;
    st_engines : (module Stog_engine) list ;
  };;


let apply_engine level env elts state engine =
  let module E = (val engine : Stog_engine) in
  match
    try Some (Int_map.find level E.engine.eng_levels)
    with Not_found -> None
  with
    None -> { state with st_engines = engine :: state.st_engines }
  | Some f ->
      let stog = state.st_stog in
      let (stog, data) =
        match f with
          Fun_stog f ->
            let stog = f env stog elts in
            (stog, E.engine.eng_data)
        | Fun_data f ->
            f (Obj.magic env) (stog, E.engine.eng_data) elts
        | Fun_stog_data f ->
            f (Obj.magic env) (stog, E.engine.eng_data) elts
      in
      let engine =
        let module E2 = struct
          type data = E.data
          let engine = { E.engine with eng_data = data }
          type cache_data = E.cache_data
          let cache_load = E.cache_load
          let cache_store = E.cache_store
          end
        in
        (module E2 : Stog_engine)
      in
      { st_stog = stog ; st_engines = engine :: state.st_engines }
;;

let (compute_level : ?elts: elt_id list -> ?cached: elt_id list -> 'a Xtmpl.env -> int -> stog_state -> stog_state) =
  fun ?elts ?cached env level state ->
  Stog_msg.verbose (Printf.sprintf "Computing level %d" level);
  let elts =
    match elts, cached with
      None, None ->
        Stog_tmap.fold (fun elt_id _ acc -> elt_id :: acc) state.st_stog.stog_elts []
    | None, Some l ->
        let pred id1 id2 = Stog_tmap.compare_key id1 id2 = 0 in
        Stog_tmap.fold
          (fun elt_id _ acc ->
             if List.exists (pred elt_id) l then acc else elt_id :: acc)
             state.st_stog.stog_elts []
    | Some l, _ -> l
  in
  (*
  let f_elt f (stog, data) (elt_id, elt) =
    let elt = f env (stog, data) elt_id elt in
    Stog_types.set_elt stog elt_id elt
  in
  *)
  let state = List.fold_left (apply_engine level env elts)
    { state with st_engines = [] } state.st_engines
  in
  state
(*
  let f_fun stog f =
    match f with
      On_elt f -> List.fold_left (f_elt f) stog elts
    | On_elt_list f ->
        let (modified, added) = f env stog elts in
        let stog = List.fold_left
          (fun stog (elt_id, elt) -> Stog_types.set_elt stog elt_id elt)
          stog modified
        in
        List.fold_left Stog_types.add_elt stog added
  in
  List.fold_left f_fun stog funs
*)
;;

(*
let load_cached_elt file =
  let ic = open_in_bin file in
  let (t : Stog_types.cached_elt) = input_value ic in
  close_in ic;
  let hid = Stog_types.string_of_human_id t.cache_elt.elt_human_id in
  blocks := Smap.add hid t.cache_blocks !blocks;
  t.cache_elt
;;
*)

let levels =
  let add level _ set = Stog_types.Int_set.add level set in
  let f set m =
    let module M = (val m : Stog_engine) in
    Stog_types.Int_map.fold add M.engine.eng_levels set
  in
  fun state ->
    List.fold_left f Stog_types.Int_set.empty state.st_engines
;;

(***** Caching *****)


let cache_info_file stog = Filename.concat stog.stog_cache_dir "info";;
let stog_cache_name = "_stog";;

let cache_file name stog elt =
  let cache_dir = Filename.concat
    stog.stog_cache_dir name
  in
  Filename.concat cache_dir
    ((String.concat "/" elt.elt_human_id.hid_path)^"._elt")
;;

let get_cached_elts stog =
  let elt_dir = Filename.concat stog.stog_cache_dir stog_cache_name in
  let files = Stog_find.find_list Stog_find.Ignore [elt_dir]
    [Stog_find.Type Unix.S_REG]
  in
  let load acc file =
    try
      let ic = open_in_bin file in
      let (elt : Stog_types.elt) = input_value ic in
      close_in ic;
      elt :: acc
    with
      Failure s | Sys_error s ->
        Stog_msg.warning s;
        acc
  in
  List.fold_left load [] files
;;
let stog_env_digest stog env =
  let md5_env =
    try Digest.string (Marshal.to_string env [Marshal.Closures])
    with Invalid_argument msg ->
        let msg = Printf.sprintf
          "%s\n  This may be due to marshalling dynamically loaded code, which is\n  \
          not supported in all ocaml releases (use the trunk development version\n  \
          to get this support)." msg
        in
        Stog_msg.warning msg;
        Digest.string ""
  in
  let md5_stog = Stog_types.stog_md5 stog in
  (Digest.to_hex md5_stog) ^ (Digest.to_hex md5_env)
;;

let set_elt_env elt stog env elt_envs =
  let hid = Stog_types.string_of_human_id elt.elt_human_id in
  let digest = stog_env_digest stog env in
  Smap.add hid digest elt_envs
;;

let apply_loaders state elt =
  let f_engine e =
    let module E = (val e : Stog_engine) in
    let cache_file = cache_file E.engine.eng_name state.st_stog elt in
    let ic = open_in_bin cache_file in
    let t = input_value ic in
    close_in ic;
    let data = E.cache_load E.engine.eng_data elt t in
    let module E2 = struct
      type data = E.data
      let engine = { E.engine with eng_data = data }
      type cache_data = E.cache_data
      let cache_load = E.cache_load
      let cache_store = E.cache_store
     end
    in
    (module E2 : Stog_engine)
  in
  let engines = List.map f_engine state.st_engines in
  let state = { state with st_engines = engines } in
  state
;;

let apply_storers state elt =
  let f_engine e =
    let module E = (val e : Stog_engine) in
    let cache_file = cache_file E.engine.eng_name state.st_stog elt in
    let cache_dir = Filename.dirname cache_file in
    Stog_misc.safe_mkdir cache_dir ;
    let oc = open_out_bin cache_file in
    let t = E.cache_store E.engine.eng_data elt in
    Marshal.to_channel oc t [Marshal.Closures];
    close_out oc
  in
  List.iter f_engine state.st_engines
;;

let get_cached_elements state env =
  Stog_misc.safe_mkdir state.st_stog.stog_cache_dir;
  let info_file = cache_info_file state.st_stog in
  let (elt_envs, stog) =
    if Sys.file_exists info_file then
      begin
        let ic = open_in_bin info_file in
        let ((elt_envs, deps, id_map) :
           (string Smap.t * Stog_types.Depset.t Smap.t *
            (human_id * string option) Smap.t Stog_types.Hid_map.t)) =
          input_value ic
        in
        close_in ic;
        let stog = { state.st_stog with
            stog_deps = deps ;
            stog_id_map = id_map ;
          }
        in
        (elt_envs, stog)
      end
    else
      (Smap.empty, state.st_stog)
  in
  let state = { state with st_stog = stog } in
  let digest = stog_env_digest state.st_stog env in

  let elts = get_cached_elts state.st_stog in
  let elt_by_hid =
    let map = List.fold_left
      (fun map elt -> Stog_types.Str_map.add
         (Stog_types.string_of_human_id elt.elt_human_id) elt map)
        Stog_types.Str_map.empty elts
    in
    fun hid -> Stog_types.Str_map.find hid map
  in
  let f (state, cached, kept_deps, kept_id_map) elt =
    let hid = Stog_types.string_of_human_id elt.elt_human_id in
    let same_elt_env =
      try
        let d = Smap.find hid elt_envs in
        d = digest
      with Not_found -> false
    in
    let use_cache =
      if same_elt_env then
        begin
          let src_cache_file = cache_file stog_cache_name state.st_stog elt in
          let src_cache_time = Stog_misc.file_mtime src_cache_file in
          let deps_time = Stog_deps.max_deps_date state.st_stog elt_by_hid
            (Stog_types.string_of_human_id elt.elt_human_id)
          in
          Stog_msg.verbose ~level: 5
           (Printf.sprintf "deps_time for %S = %s, last generated on %s" src_cache_file
             (Stog_misc.string_of_time deps_time)
             (match src_cache_time with None -> "" | Some d -> Stog_misc.string_of_time d)
            );
          match src_cache_time with
            None -> false
          | Some t_elt -> deps_time < t_elt
        end
      else
         false
    in
    if use_cache then
      begin
        let state = apply_loaders state elt in
        (* keep deps of this element, as it did not change *)
        let kept_deps =
          try Smap.add hid (Smap.find hid state.st_stog.stog_deps) kept_deps
          with Not_found -> kept_deps
        in
        let kept_id_map =
          try Stog_types.Hid_map.add elt.elt_human_id
            (Stog_types.Hid_map.find elt.elt_human_id state.st_stog.stog_id_map) kept_id_map
          with
            Not_found -> kept_id_map
        in
        (state, elt :: cached, kept_deps, kept_id_map)
      end
    else
      begin
        (* do not keep deps of this element, as it will be recomputed *)
        (state, cached, kept_deps, kept_id_map)
      end
  in
  let (state, cached, kept_deps, kept_id_map) =
    List.fold_left f
      (state, [], Smap.empty, Stog_types.Hid_map.empty) elts
  in
  let stog = {
      state.st_stog with
      stog_deps = kept_deps ;
      stog_id_map = kept_id_map ;
    }
  in
  let state = { state with st_stog = stog } in
  (state, cached)
;;

let cache_elt state elt =
  let cache_file = cache_file stog_cache_name state.st_stog elt in
  Stog_misc.safe_mkdir (Filename.dirname cache_file);
  let oc = open_out_bin cache_file in
  output_value oc elt ;
  close_out oc ;
  apply_storers state elt
;;

let output_cache_info stog elt_envs =
  let info_file = cache_info_file stog in
  let v = (elt_envs, stog.stog_deps, stog.stog_id_map) in
  let oc = open_out_bin info_file in
  output_value oc v;
  close_out oc
;;



let compute_levels ?(use_cache=true) ?elts env state =
  let levels = levels state in
  if use_cache then
    begin
      let (state, cached) = get_cached_elements state env in
      Stog_msg.verbose (Printf.sprintf "%d elements read from cache" (List.length cached));
      let f_elt (stog, cached) cached_elt =
        try
          let (elt_id, _) = Stog_types.elt_by_human_id stog cached_elt.elt_human_id in
          (* replace element by cached one *)
          let stog = Stog_types.set_elt stog elt_id cached_elt in
          (stog, elt_id :: cached)
        with _ ->
            (* element not loaded but cached; keep it as it may be an
              element from a cut-elt rule *)
            let stog = Stog_types.add_elt stog cached_elt in
            let (elt_id, _) = Stog_types.elt_by_human_id stog cached_elt.elt_human_id in
            (stog, elt_id :: cached)
      in
      let (stog, cached) = List.fold_left f_elt (state.st_stog, []) cached in
      let state = { state with st_stog = stog } in
      Stog_types.Int_set.fold (compute_level ~cached env) levels state
    end
  else
    Stog_types.Int_set.fold (compute_level ?elts env) levels state
;;


let rec make_fun (name, params, body) acc =
  let f data env atts subs =
    let vars = List.map
      (fun (param,default) ->
         match Xtmpl.get_arg atts param with
           None -> (param, [], [ Xtmpl.xml_of_string default])
         | Some v -> (param, [], [ Xtmpl.xml_of_string v ])
      )
      params
    in
    let env = env_of_defs ~env vars in
    let env = Xtmpl.env_add "contents" (fun data _ _ _ -> (data, subs)) env in
    Xtmpl.apply_to_xmls data env body
  in
  (name, f) :: acc


and env_of_defs ?env defs =
  let f x acc =
    match x with
    | (key, [], body) -> (key, fun data _ _ _ -> (data, body)) :: acc
    | _ ->  make_fun x acc
  in
  (* fold_right instead of fold_left to reverse list and keep associations
     in the same order as in declarations *)
  let l = List.fold_right f defs [] in
  Xtmpl.env_of_list ?env l
;;

(** FIXME: handle module requirements and already added modules *)
(* FIXME: add dependency ? *)
let env_of_used_mod stog ?(env=Xtmpl.env_empty()) modname =
  try
    let m = Stog_types.Str_map.find modname stog.stog_modules in
    (*prerr_endline (Printf.sprintf "adding %d definitions from module %S"
      (List.length m.mod_defs) modname);*)
    env_of_defs ~env m.mod_defs
  with Not_found ->
    Stog_msg.warning (Printf.sprintf "No module %S" modname);
    env

let env_of_used_mods stog ?(env=Xtmpl.env_empty()) mods =
  Stog_types.Str_set.fold (fun name env -> env_of_used_mod stog ~env name) mods env
;;

let run ?(use_cache=true) ?only_elt state =
  let stog = state.st_stog in
  let env = env_of_defs stog.stog_defs in
  let env = env_of_used_mods stog ~env stog.stog_used_mods in
  match only_elt with
    None ->
      (* TODO: move this to HTML module:
      let stog = make_topic_indexes stog env in
      let stog = make_keyword_indexes stog env in
      let stog = make_archive_index stog env in
      let state = { state with st_stog = stog } in
      *)
      let state = compute_levels ~use_cache env state in
      (state, env)
  | Some elt_id ->
      let state = compute_levels ~use_cache ~elts: [elt_id] env state in
      (state, env)
;;


let encode_for_url s =
  let len = String.length s in
  let b = Buffer.create len in
  for i = 0 to len - 1 do
    match s.[i] with
    | 'A'..'Z' | 'a'..'z' | '0'..'9'
    | '_' | '-' | '.' | '!' | '*' | '+' | '/' ->
        Buffer.add_char b s.[i]
    | c -> Printf.bprintf b "%%%0x" (Char.code c)
  done;
  Buffer.contents b
;;

let elt_dst f_concat ?(encode=true) stog base elt =
  let path =
    match elt.elt_human_id.hid_path with
      [] -> failwith "Invalid human id: []"
    | h :: q -> List.fold_left f_concat h q
  in
  let ext = Stog_misc.filename_extension elt.elt_src in
  let path =
    if elt.elt_lang_dep then
      begin
        let ext_pref =
          match stog.stog_lang with
            None -> ""
          | Some lang -> "."^lang
        in
        Printf.sprintf "%s%s" path ext_pref
      end
    else
      path
  in
  let dst = match ext with "" -> path | _ -> path^"."^ext in
  let dst = if encode then encode_for_url dst else dst in
  f_concat base dst
;;

let elt_dst_file stog elt =
  elt_dst ~encode: false Filename.concat stog stog.stog_outdir elt;;


let elt_url stog elt =
  let url = elt_dst (fun a b -> a^"/"^b) stog
    (Stog_types.string_of_url stog.stog_base_url) elt
  in
  let len = String.length url in
  let s = "/index.html" in
  let len_s = String.length s in
  let url =
    if len >= len_s && String.sub url (len - len_s) len_s = s then
      String.sub url 0 (len-len_s)
    else
      url
  in
  url_of_string url
;;

let output_elt state env elt =
  let file = elt_dst_file state.st_stog elt in
  Stog_misc.safe_mkdir (Filename.dirname file);
  match elt.elt_out with
    None ->
      failwith
        (Printf.sprintf "Element %S not computed!"
         (Stog_types.string_of_human_id elt.elt_human_id)
        )
  | Some xmls ->
      let oc = open_out file in
      let doctype =
        match elt.elt_xml_doctype with
          None -> "HTML"
        | Some s -> s
      in
      Printf.fprintf oc "<!DOCTYPE %s>\n" doctype;
      let xmls =
        match String.lowercase doctype with
          "html" -> List.map Stog_html5.hack_self_closed xmls
        | _ -> xmls
      in
      List.iter (fun xml -> output_string oc (Xtmpl.string_of_xml xml)) xmls;
      close_out oc;
      cache_elt state elt
;;

let output_elts ?elts state env =
  let stog = state.st_stog in
  let elts =
    match elts with
      None ->
        Stog_tmap.fold
          (fun _ elt acc -> output_elt state env elt ; elt :: acc)
          stog.stog_elts []
    | Some l -> List.iter (output_elt state env) l; l
  in
  let elt_envs = List.fold_left
    (fun elt_envs elt -> set_elt_env elt stog env elt_envs)
      Smap.empty elts
  in
  output_cache_info stog elt_envs
;;

let copy_other_files stog =
  let report_error msg = Stog_msg.error ~info: "Stog_html.copy_other_files" msg in
  let copy_file src dst =
    let com = Printf.sprintf "cp -f %s %s" (Filename.quote src) (Filename.quote dst) in
    match Sys.command com with
      0 -> ()
    | n ->
        let msg = Printf.sprintf "Command failed [%d]: %s" n com in
        report_error msg
  in
  let f_file dst path name =
    let dst = Filename.concat dst name in
    let src = Filename.concat path name in
    copy_file src dst
  in
  let rec f_dir dst path name t =
    let dst = Filename.concat dst name in
    let path = Filename.concat path name in
    Stog_misc.safe_mkdir dst;
    iter dst path t
  and iter dst path t =
    Stog_types.Str_set.iter (f_file dst path) t.files ;
    Stog_types.Str_map.iter (f_dir dst path) t.dirs
  in
  iter stog.stog_outdir stog.stog_dir stog.stog_files
;;

let generate ?(use_cache=true) ?only_elt stog engines =
  begin
    match stog.stog_lang with
      None -> ()
    | Some lang -> Stog_msg.verbose (Printf.sprintf "Generating pages for language %s" lang);
  end;
  Stog_misc.safe_mkdir stog.stog_outdir;
  let only_elt =
    match only_elt with
      None -> None
    | Some s ->
        let hid = Stog_types.human_id_of_string s in
        let (elt_id, _) = Stog_types.elt_by_human_id stog hid in
        Some elt_id
  in
  let state = { st_stog = stog ; st_engines = engines } in
  let (state, env) = run ~use_cache ?only_elt state in
  match only_elt with
    None ->
      output_elts state env;
      copy_other_files stog
  | Some elt_id ->
      let elt = Stog_types.elt state.st_stog elt_id in
      output_elts ~elts: [elt] state env
;;


(*** Convenient functions to create level_fun's ***)


let get_in_env data env (prefix, s) =
  let node = [ Xtmpl.E((prefix,s),[],[]) ] in
  let (data, node2) = Xtmpl.apply_to_xmls data env node in
  if node2 = node then (data, "") else (data, Xtmpl.string_of_xmls node2)
;;

let opt_in_env data env (prefix, s) =
  let node = [ Xtmpl.E((prefix,s),[],[]) ] in
  let (data, node2) = Xtmpl.apply_to_xmls data env node in
  if node2 = node then (data, None) else (data, Some (Xtmpl.string_of_xmls node2))
;;

let get_elt_out stog elt =
  match elt.elt_out with
    None ->
      let (stog, tmpl) =
        let default =
          match elt.elt_type with
            "by-topic" -> Stog_tmpl.by_topic
          | "by-keyword" -> Stog_tmpl.by_keyword
          | "by-month" -> Stog_tmpl.by_month
          | _ -> Stog_tmpl.page
        in
        Stog_tmpl.get_template stog ~elt default (elt.elt_type^".tmpl")
      in
      (stog, [tmpl])
  | Some xmls ->
      (stog, xmls)
;;

let get_languages data env =
  match opt_in_env data env ("", "languages") with
  | (data, None) -> (data, ["fr" ; "en"])
  | (data, Some s) -> (data, Stog_misc.split_string s [','; ';' ; ' '])
;;

let env_add_lang_rules data env stog elt =
  match stog.stog_lang with
    None ->
      (data, Xtmpl.env_add Stog_tags.langswitch (fun data _ _ _ -> (data, [])) env)
  | Some lang ->
      let (data, languages) = get_languages data env in
      let map_lang lang =
         let url = elt_url { stog with stog_lang = Some lang } elt in
         let img_url = Stog_types.url_concat stog.stog_base_url (lang^".png") in
         Xtmpl.E (("", "a"), [("", "href"), (Stog_types.string_of_url url)], [
           Xtmpl.E (("", "img"),
            [ ("", "src"), (Stog_types.string_of_url img_url) ;
              ("", "title"), lang ;
              ("", "alt"), lang
            ], [])])
      in
      let f data _env args _subs =
        let languages = List.filter ((<>) lang) languages in
        (data, List.map map_lang languages)
      in
      let env = Xtmpl.env_add Stog_tags.langswitch f env in
      let to_remove = List.filter ((<>) lang) languages in
      let f_keep acc _env _args subs = (acc, subs) in
      let f_remove acc _env _args _subs = (acc, []) in
      let rules =
        (("", lang), f_keep) ::
          (List.map (fun lang -> (("", lang), f_remove)) to_remove)
      in
      (data, Xtmpl.env_of_list ~env rules)
;;

let elt_env data env stog elt =
  let env = env_of_defs ~env elt.elt_defs in
  let env = env_of_used_mods stog ~env elt.elt_used_mods in
  let rules = [
      ("", Stog_tags.elt_hid),
      (fun  acc _ _ _ ->
         (acc, [Xtmpl.D (Stog_types.string_of_human_id elt.elt_human_id)]))]
  in
  let env = Xtmpl.env_of_list ~env rules in
  let (data, env) = env_add_lang_rules data env stog elt in
  (data, env)

type 'a stog_elt_rules =
  Stog_types.stog -> Stog_types.elt_id -> (Xtmpl.name * 'a Xtmpl.callback) list

let fun_apply_stog_elt_rules f_rules =
  let f_elt env stog elt_id =
    let rules = f_rules stog elt_id in
    let env = Xtmpl.env_of_list ~env rules in
    let elt = Stog_types.elt stog elt_id in
    let (stog, env) = elt_env stog env stog elt in
    let (stog, xmls) = get_elt_out stog elt in
    (*prerr_endline (Printf.sprintf "%s = %s"
      (Stog_types.string_of_human_id elt.elt_human_id)
      (Xtmpl.string_of_xmls xmls));*)
    let (stog, xmls) = Xtmpl.apply_to_xmls stog env xmls in
    let elt = { elt with elt_out = Some xmls } in
    Stog_types.set_elt stog elt_id elt
  in
  let f env stog elts = List.fold_left (f_elt env) stog elts in
  Fun_stog f
;;

let fun_apply_stog_data_elt_rules f_rules =
  let f_elt env (stog, data) elt_id =
    let rules = f_rules stog elt_id in
    let env = Xtmpl.env_of_list ~env rules in
    let elt = Stog_types.elt stog elt_id in
    let ((stog, data), env) = elt_env (stog, data) env stog  elt in
    let (stog, xmls) = get_elt_out stog elt in
    let ((stog, data), xmls) = Xtmpl.apply_to_xmls (stog, data) env xmls in
    let elt = { elt with elt_out = Some xmls } in
    (Stog_types.set_elt stog elt_id elt, data)
  in
  let f env (stog, data) elts = List.fold_left (f_elt env) (stog, data) elts in
  Fun_stog_data f
;;

let fun_apply_data_elt_rules f_rules =
  let f_elt env (stog, data) elt_id =
    let rules = f_rules stog elt_id in
    let env = Xtmpl.env_of_list ~env rules in
    let elt = Stog_types.elt stog elt_id in
    let (data, env) = elt_env data env stog elt in
    let (stog, xmls) = get_elt_out stog elt in
    let (data, xmls) = Xtmpl.apply_to_xmls data env xmls in
    let elt = { elt with elt_out = Some xmls } in
    (Stog_types.set_elt stog elt_id elt, data)
  in
  let f env (stog, data) elts = List.fold_left (f_elt env) (stog, data) elts in
  Fun_data f
;;

(*** Engines ***)

type engine_fun = Stog_types.stog -> (module Stog_engine)

let engines = ref (Stog_types.Str_map.empty : (Stog_types.stog -> (module Stog_engine)) Stog_types.Str_map.t);;

let register_engine name f_engine =
  engines := Stog_types.Str_map.add name f_engine !engines
;;

let engine_by_name name =
  try Some (Stog_types.Str_map.find name !engines)
  with Not_found -> None
;;

let engines () = Stog_types.Str_map.fold
  (fun name f acc -> (name, f) :: acc) !engines []
;;
