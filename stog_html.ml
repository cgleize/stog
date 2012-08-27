(*********************************************************************************)
(*                Stog                                                           *)
(*                                                                               *)
(*    Copyright (C) 2012 Maxence Guesdon. All rights reserved.                   *)
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

let languages = ["fr" ; "en" ];;

let current_stog = ref None;;
let plugin_funs = ref [];;

let url_compat s =
 let s = Stog_misc.lowercase s in
 for i = 0 to String.length s - 1 do
   match s.[i] with
     'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' | '.' -> ()
    | _  -> s.[i] <- '+'
 done;
 s
;;

let escape_html s =
  let b = Buffer.create 256 in
  for i = 0 to String.length s - 1 do
    let s =
      match s.[i] with
        '<' -> "&lt;"
      | '>' -> "&gt;"
      | '&' -> "&amp;"
      | c -> String.make 1 c
    in
    Buffer.add_string b s
  done;
  Buffer.contents b
;;

let tag_sep = "sep_";;

let elt_dst f_concat stog base elt =
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
  f_concat base dst
;;

let elt_dst_file stog elt = elt_dst Filename.concat stog stog.stog_outdir elt;;
let elt_url stog elt =
  let url = elt_dst (fun a b -> a^"/"^b) stog stog.stog_base_url elt in
  let len = String.length url in
  let s = "/index.html" in
  let len_s = String.length s in
  if len >= len_s && String.sub url (len - len_s) len_s = s then
    String.sub url 0 (len-len_s)
  else
    url
;;


let url_of_hid stog ?ext hid =
  let elt = Stog_types.make_elt ~hid () in
  let src =
    Printf.sprintf "%s%s" (Stog_types.string_of_human_id hid)
      (match ext with None -> "" | Some s -> "."^s)
  in
  elt_url stog { elt with Stog_types.elt_src = src }
;;

let topic_index_hid topic = Stog_types.human_id_of_string ("/topic_"^topic);;
let keyword_index_hid kw = Stog_types.human_id_of_string ("/kw_"^ kw);;
let month_index_hid ~year ~month =
  Stog_types.human_id_of_string (Printf.sprintf "/%04d_%02d" year month);;

let make_lang_funs stog =
  match stog.stog_lang with
    None -> []
  | Some lang ->
      let to_remove = List.filter ((<>) lang) languages in
      let f_keep _env _args subs = subs in
      let f_remove _env _args _subs = [] in
      (lang, f_keep) ::
      (List.map (fun lang -> (lang, f_remove)) to_remove)
;;

let fun_include tmpl_dir _env args subs =
  match Xtmpl.get_arg args "file" with
    None -> failwith "Missing 'file' argument for include command";
  | Some file ->
      let file =
        if Filename.is_relative file then
          Filename.concat tmpl_dir file
        else
          file
      in
      let xml =
        match Xtmpl.get_arg args "raw" with
        | Some "true" -> [Xtmpl.D (Stog_misc.string_of_file file)]
        | _ -> [Xtmpl.xml_of_string (Stog_misc.string_of_file file)]
      in
      let args =
        ("contents", String.concat "" (List.map Xtmpl.string_of_xml subs)) ::
        args
      in
      [Xtmpl.T (Xtmpl.tag_env, args, xml)]
;;

let fun_image _env args legend =
  let width = Xtmpl.opt_arg args "width" in
  let src = Xtmpl.opt_arg args "src" in
  let cls = Printf.sprintf "img%s"
    (match Xtmpl.get_arg args "float" with
       Some "left" -> "-float-left"
     | Some "right" -> "-float-right"
     | Some s -> failwith (Printf.sprintf "unhandled image position: %s" s)
     | None -> ""
    )
  in
  let pred (s,_) = not (List.mem s ["width" ; "src" ; "float"]) in
  let atts = List.filter pred args in
  [
    Xtmpl.T ("div", [ "class", cls ],
     (Xtmpl.T ("img", [ "class", "img" ; "src", src; "width", width ] @ atts, [])) ::
     (match legend with
        [] -> []
      | xml -> [ Xtmpl.T ("div", ["class", "legend"], xml) ]
     )
    )
  ]
;;

let fun_elt_href ?typ href stog env args subs =
  let (elt, id, text) =
    let (hid, id) =
      try
        let p = String.index href '#' in
        let len = String.length href in
        (String.sub href 0 p, Some (String.sub href (p+1) (len - (p+1))))
      with
        Not_found -> (href, None)
    in
    let elt =
      try
        let hid = Stog_types.human_id_of_string hid in
        let (_, elt) = Stog_types.elt_by_human_id ?typ stog hid in
        Some elt
      with
        Failure s ->
          Stog_msg.error s;
          None
    in
    let text =
      match elt, subs with
        None, _ -> [Xtmpl.D "??"]
      | Some elt, [] -> [Xtmpl.D (Printf.sprintf "\"%s\"" elt.elt_title)]
      | Some _, text -> text
    in
    (elt, id, text)
  in
  match elt with
    None -> [Xtmpl.T ("span", ["class", "unknown-ref"], text)]
  | Some elt ->
      [
        Xtmpl.T ("a", ["href", (elt_url stog elt)], text)
      ]
;;

let fun_elt ?typ stog env args subs =
  let href =
    match Xtmpl.get_arg args "href" with
      None ->
        let msg = Printf.sprintf "Missing href for <%s>"
          (match typ with None -> "elt" | Some s -> s)
        in
        failwith msg
    | Some s -> s
  in
  fun_elt_href ?typ href stog env args subs
;;

let fun_post = fun_elt ~typ: "post";;
let fun_page = fun_elt ~typ: "page";;

let fun_archive_tree stog _env _ =
  let mk_months map =
    List.sort (fun (m1, _) (m2, _) -> compare m2 m1)
    (Stog_types.Int_map.fold
     (fun month data acc -> (month, data) :: acc)
     map
     []
    )
  in
  let years =
    Stog_types.Int_map.fold
      (fun year data acc -> (year, mk_months data) :: acc)
      stog.stog_archives
      []
  in
  let years = List.sort (fun (y1,_) (y2,_) -> compare y2 y1) years in

  let f_mon year (month, set) =
    let hid = month_index_hid ~year ~month in
    let href = url_of_hid stog ~ext: "html" hid in
    let month_str = Stog_intl.get_month stog.stog_lang month in
    Xtmpl.T ("li", [], [
       Xtmpl.T ("a", ["href", href], [ Xtmpl.D month_str ]) ;
       Xtmpl.D (Printf.sprintf "(%d)" (Stog_types.Elt_set.cardinal set))
     ]
    )
  in
  let f_year (year, data) =
    Xtmpl.T ("li", [], [
       Xtmpl.D (string_of_int year) ;
       Xtmpl.T ("ul", [], List.map (f_mon year) data) ;
      ]
    )
  in
  [ Xtmpl.T ("ul", [], List.map f_year years) ]
;;

let fun_rss_feed file args _env _ =
  [
    Xtmpl.T ("link",
     [ "href", file ; "type", "application/rss+xml" ; "rel", "alternate" ; "title", "RSS feed"],
     [])
  ]
;;

let highlight ~opts code =
  let code_file = Filename.temp_file "stog" "code" in
  Stog_misc.file_of_string ~file: code_file code;
  let temp_file = Filename.temp_file "stog" "highlight" in
  let com = Printf.sprintf
    "highlight -O xhtml %s -f %s > %s"
    opts (Filename.quote code_file)(Filename.quote temp_file)
  in
  match Sys.command com with
    0 ->
      let code = Stog_misc.string_of_file temp_file in
      Sys.remove code_file;
      Sys.remove temp_file;
      code
  | _ ->
      failwith (Printf.sprintf "command failed: %s" com)
;;

let fun_hcode ?(inline=false) ?lang stog _env args code =
  let language, language_options =
    match lang with
      None ->
        (
         match Xtmpl.get_arg args "lang-file" with
           None ->
             begin
               let lang = Xtmpl.opt_arg args ~def: "txt" "lang" in
               match lang with
                 "txt" -> (lang, None)
               | _ -> (lang, Some (Printf.sprintf "--syntax=%s" lang))
             end
         | Some f ->
             let lang = Xtmpl.opt_arg args ~def: "" "lang" in
             let opts = Printf.sprintf "--config-file=%s" f in
             (lang, Some opts)
        )
    | Some "ocaml" ->
        let lang_file = Filename.concat stog.stog_dir "ocaml.lang" in
        let opts = if Sys.file_exists lang_file then
            Printf.sprintf "--config-file=%s" lang_file
          else
            "--syntax=ocaml"
        in
        ("ocaml", Some opts)
    | Some lang ->
        (lang, Some (Printf.sprintf "--syntax=%s" lang))
  in
  let code =
    match code with
      [ Xtmpl.D code ] -> code
    | _ ->
       String.concat "" (List.map Xtmpl.string_of_xml code)
    (*failwith (Printf.sprintf "Invalid code: %s"
         (String.concat "" (List.map Xtmpl.string_of_xml code)))*)
  in
  let code = Stog_misc.strip_string code in
  let xml_code =
    match language_options with
      None -> Xtmpl.D code
    | Some opts ->
        let code = highlight ~opts code in
        Xtmpl.xml_of_string code
  in
  if inline then
    [ Xtmpl.T ("span", ["class","icode"], [xml_code]) ]
  else
    [ Xtmpl.T ("pre",
       ["class", Printf.sprintf "code-%s" language], [xml_code])
    ]
;;

let fun_ocaml = fun_hcode ~lang: "ocaml";;
let fun_command_line = fun_hcode ~lang: "sh";;
let fun_icode = fun_hcode ~inline: true ;;

let fun_section cls _env args body =
  let id =
    match Xtmpl.get_arg args "name" with
      None -> []
    | Some name -> ["id", name]
  in
  let title =
    match Xtmpl.get_arg args "title" with
      None -> []
    | Some t ->
        [Xtmpl.T ("div", ["class", cls^"-title"] @ id, [Xtmpl.xml_of_string t])]
  in
  [ Xtmpl.T ("div", ["class", cls], title @ body) ]
;;

let fun_subsection = fun_section "subsection";;
let fun_section = fun_section "section";;

let fun_search_form stog _env _ _ =
  let tmpl = Filename.concat stog.stog_tmpl_dir "search.tmpl" in
  [ Xtmpl.xml_of_string (Stog_misc.string_of_file tmpl) ]
;;

let fun_blog_url stog _env _ _ = [ Xtmpl.D stog.stog_base_url ];;

let fun_graph =
  let generated = ref false in
  fun stog _env _ _ ->
    let png_name = "site-graph.png" in
    let small_png_name = "small-"^png_name in
    let svg_file = (Filename.chop_extension png_name) ^ ".svg" in
    let src = Printf.sprintf "%s/%s" stog.stog_base_url svg_file in
    let small_src = Printf.sprintf "%s/%s" stog.stog_base_url small_png_name in
    begin
      match !generated with
        true -> ()
      | false ->
          generated := true;
          let dot_code = Stog_info.dot_of_graph (elt_url stog) stog in

          let tmp = Filename.temp_file "stog" "dot" in
          Stog_misc.file_of_string ~file: tmp dot_code;

          let com = Printf.sprintf "dot -Gcharset=utf-8 -Tpng -o %s %s"
            (Filename.quote (Filename.concat stog.stog_outdir png_name))
            (Filename.quote tmp)
          in
          let svg_code = Stog_misc.dot_to_svg dot_code in
          Stog_misc.file_of_string ~file: (Filename.concat stog.stog_outdir svg_file) svg_code;
          match Sys.command com with
            0 ->
              begin
                (try Sys.remove tmp with _ -> ());
                let com = Printf.sprintf "convert -scale 120x120 %s %s"
                  (Filename.quote (Filename.concat stog.stog_outdir png_name))
                  (Filename.quote (Filename.concat stog.stog_outdir small_png_name))
                in
                match Sys.command com with
                  0 -> ()
                | _ ->
                    Stog_msg.error (Printf.sprintf "Command failed: %s" com)
              end
          | _ ->
              Stog_msg.error (Printf.sprintf "Command failed: %s" com)
    end;
    [
      Xtmpl.T ("a", ["href", src], [
         Xtmpl.T ("img", ["src", small_src ; "alt", "Graph"], [])
       ])
    ]
;;

let fun_if env args subs =
  let pred (att, v) =
    let node = Printf.sprintf "<%s/>" att in
    let s = Xtmpl.apply env node in
    (*prerr_endline (Printf.sprintf "fun_if: pred: att=%s, s=%S, v=%s" att s v);*)
    let s = if s = node then "" else s in
    s = v
  in
  let cond = List.for_all pred args in
  let subs = List.filter
    (function Xtmpl.D _ -> false | _ -> true)
    subs
  in
  match cond, subs with
  | true, [] -> failwith "<if>: missing children"
  | true, h :: _
  | false, _ :: h :: _ -> [h]
  | false, []
  | false, [_] -> []
;;

let generate_page stog env contents =
  let tmpl = Filename.concat stog.stog_tmpl_dir "page.tmpl" in
  let f env args body = contents in
  let env = Xtmpl.env_of_list ~env ["contents", f] in
  Xtmpl.apply env (Stog_misc.string_of_file tmpl)
;;

let env_add_langswitch env stog elt =
  let name = "langswitch" in
  match stog.stog_lang with
    None ->
      Xtmpl.env_add name (fun _ _ _ -> []) env
  | Some lang ->
      let map_lang lang =
         let url = elt_url { stog with stog_lang = Some lang } elt in
         let img_url = Printf.sprintf "%s/%s.png" stog.stog_base_url lang in
         Xtmpl.T ("a", ["href", url], [
           Xtmpl.T ("img", ["src", img_url ; "title", lang ; "alt", lang], [])])
      in
      let f _env args _subs =
        let languages =
          match Xtmpl.get_arg args "languages" with
            Some s -> Stog_misc.split_string s [','; ';' ; ' ']
          | None -> languages
        in
        let languages = List.filter ((<>) lang) languages in
        List.map map_lang languages
      in
      Xtmpl.env_add name f env
;;

let fun_twocolumns env args subs =
  (*prerr_endline (Printf.sprintf "two-columns, length(subs)=%d" (List.length subs));*)
  let empty = [] in
  let subs = List.fold_right
    (fun xml acc ->
       match xml with
         Xtmpl.D _ -> acc
       | Xtmpl.T (_,_,subs)
       | Xtmpl.E (_, subs) -> subs :: acc
    ) subs []
  in
  let left, right =
    match subs with
      [] -> empty, empty
    | [left] -> left, empty
    | left :: right :: _ -> left, right
  in
  [ Xtmpl.T ("table", ["class", "two-columns"],
     [ Xtmpl.T ("tr", [],
        [ Xtmpl.T ("td", ["class", "two-columns-left"], left) ;
          Xtmpl.T ("td", ["class", "two-columns-right"], right) ;
        ]);
     ])
  ]
;;

let fun_exta env args subs =
  [ Xtmpl.T ("span", ["class","ext-a"],
     [ Xtmpl.T ("a",args, subs) ])
  ]
;;

type toc = Toc of string * string * string * toc list (* name, title, class, subs *)

let fun_prepare_toc env args subs =
  let depth =
    match Xtmpl.get_arg args "depth" with
      None -> max_int
    | Some s -> int_of_string s
  in
  let rec iter d acc = function
  | Xtmpl.D _ -> acc
  | Xtmpl.T ("section" as cl, atts, subs)
  | Xtmpl.T ("subsection" as cl, atts, subs) ->
      begin
        match Xtmpl.get_arg atts "name", Xtmpl.get_arg atts "title" with
          None, _ | _, None ->
            (*prerr_endline "no name nor title";*)
            acc
        | Some name, Some title ->
            if d > depth
            then acc
            else
              (
               let subs = List.rev (List.fold_left (iter (d+1)) [] subs) in
               (*prerr_endline (Printf.sprintf "depth=%d, d=%d, title=%s" depth d title);*)
               (Toc (name, title, cl, subs)) :: acc
              )
      end
  | Xtmpl.T (_,_,subs) -> List.fold_left (iter d) acc subs
  | Xtmpl.E (tag, subs) ->
      match tag with
      | (("", t), atts) ->
          iter d acc (Xtmpl.T (t, (List.map (fun ((_,a),v) -> (a, v)) atts), subs))
      | _ -> acc
  in
  let toc = List.rev (List.fold_left (iter 1) [] subs) in
  (*(
   match toc with
     [] -> prerr_endline "empty toc!"
   | _ -> prerr_endline (Printf.sprintf "toc is %d long" (List.length toc));
  );*)
  let rec xml_of_toc = function
    Toc (name, title, cl, subs) ->
      Xtmpl.T ("li", ["class", "toc-"^cl],
       [ Xtmpl.T ("a", ["href", "#"^name],
         [ Xtmpl.xml_of_string title ]) ]
       @
       ( match subs with
          [] -> []
        | _ ->
               [ Xtmpl.T ("ul", ["class", "toc"], List.map xml_of_toc subs) ]
       )
       )
  in
  let xml = Xtmpl.T ("ul", ["class", "toc"], List.map xml_of_toc toc) in
  let atts = [ "toc-contents", Xtmpl.string_of_xml xml ] in
  [ Xtmpl.T (Xtmpl.tag_env, atts, subs) ]
;;

let fun_toc env args subs =
  subs @ [Xtmpl.T ("toc-contents", [], [])]
;;

let default_commands ?rss stog =
  let l =
    !plugin_funs @
    [
      "if", fun_if ;
      "include", fun_include stog.stog_tmpl_dir ;
      "image", fun_image ;
      "archive-tree", (fun _ -> fun_archive_tree stog) ;
      "hcode", fun_hcode stog ~inline: false ?lang: None;
      "icode", fun_icode ?lang: None stog;
      "ocaml", fun_ocaml ~inline: false stog;
      "command-line", fun_command_line ~inline: false stog ;
      "post", fun_post stog;
      "section", fun_section ;
      "subsection", fun_subsection ;
      "rssfeed", (match rss with None -> fun _env _ _ -> [] | Some file -> fun_rss_feed file);
      Stog_cst.site_url, fun_blog_url stog ;
      "search-form", fun_search_form stog ;
      Stog_cst.site_title, (fun _ _ _ -> [ Xtmpl.D stog.stog_title ]) ;
      Stog_cst.site_desc, (fun _ _ _ -> stog.stog_desc) ;
      "two-columns", fun_twocolumns ;
      "ext-a", fun_exta ;
      "prepare-toc", fun_prepare_toc ;
      "toc", fun_toc ;
      "graph", fun_graph stog ;
      "page", (fun_page stog) ;
      "latex", (Stog_latex.fun_latex stog) ;
    ]
  in
  (make_lang_funs stog) @ l
;;

let intro_of_elt stog elt =
  let rec iter acc = function
    [] -> raise Not_found
  | (Xtmpl.T ("sep_",_,_)) :: _
  | (Xtmpl.E (((_,"sep_"),_),_)) :: _ -> List.rev acc
  | h :: q -> iter (h::acc) q
  in
  try
    let xml = iter [] elt.elt_body in
    xml @
    [
      Xtmpl.T ("a", ["href", elt_url stog elt],
       [ Xtmpl.T ("img", [ "src", Printf.sprintf "%s/next.png" stog.stog_base_url; "alt", "next"], [])])
    ]
  with
    Not_found -> elt.elt_body
;;

let rss_date_of_date d =
  let {year; month; day} = d in
  {
    Rss.year = year ; month ; day;
    hour = 8 ; minute = 0 ; second = 0 ;
    zone = 0 ; week_day = -1 ;
  }
;;

let elt_to_rss_item stog elt =
  let link = elt_url stog elt in
  let pubdate =
    match elt.elt_date with
      None -> assert false
    | Some d -> rss_date_of_date d
  in
  let f_word w =
    { Rss.cat_name = w ; Rss.cat_domain = None }
  in
  let cats =
    (List.map f_word elt.elt_topics) @
    (List.map f_word elt.elt_keywords)
  in
  let desc = intro_of_elt stog elt in
  let desc =
    Xtmpl.apply_to_xmls
    (Xtmpl.env_of_list (default_commands stog))
    desc
  in
  let desc = String.concat "" (List.map Xtmpl.string_of_xml desc) in
  Rss.item ~title: elt.elt_title
  ~desc
  ~link
  ~pubdate
  ~cats
  ~guid: { Rss.guid_name = link ; guid_permalink = true }
  ()
;;

let generate_rss_feed_file stog ?title link elts file =
  let elts = List.rev (Stog_types.sort_elts_by_date elts) in
  let elts = List.filter
    (fun elt -> match elt.elt_date with None -> false | _ -> true)  elts
  in
  let items = List.map (elt_to_rss_item stog) elts in
  let title = Printf.sprintf "%s%s"
    stog.stog_title
    (match title with None -> "" | Some t -> Printf.sprintf ": %s" t)
  in
  let pubdate =
    match elts with
      [] -> None
    | h :: _ ->
        Some (rss_date_of_date
         (match h.elt_date with None -> assert false | Some d -> d))
  in
  let image =
    try
      let file = List.assoc "rss-image" stog.stog_vars in
      let url = Filename.concat stog.stog_base_url file in
      let image = {
          Rss.image_url = url ;
          image_title = stog.stog_title ;
          image_link = stog.stog_base_url ;
          image_height = None ;
          image_width = None ;
          image_desc = None ;
        }
      in
      Some image
    with
      Not_found -> None
  in
  let desc = String.concat "" (List.map Xtmpl.string_of_xml stog.stog_desc) in
  let channel =
    Rss.channel ~title ~link
    ~desc ?image
    ~managing_editor: stog.stog_email
    ?pubdate ?last_build_date: pubdate
    ~generator: "Stog"
    items
  in
  let channel = Rss.keep_n_items stog.stog_rss_length channel in
  (* break tail-rec to get a better error backtrace *)
  let result = Rss.print_file ~encoding: "UTF-8" file channel in
  result
;;

let copy_file ?(ignerr=false) ?(quote_src=true) ?(quote_dst=true) src dest =
  let com = Printf.sprintf "cp -f %s %s"
    (if quote_src then Filename.quote src else src)
    (if quote_dst then Filename.quote dest else dest)
  in
  match Sys.command com with
    0 -> ()
  | _ ->
      let msg = Printf.sprintf "command failed: %s" com in
      if ignerr then Stog_msg.error msg else failwith msg
;;

let html_of_topics stog elt env args _ =
  let sep = Xtmpl.xml_of_string (Xtmpl.opt_arg args ~def: ", " "set") in
  let tmpl = Filename.concat stog.stog_tmpl_dir "topic.tmpl" in
  let f w =
    let env = Xtmpl.env_of_list ~env [ "topic", (fun _ _ _ -> [Xtmpl.D w]) ] in
    Xtmpl.xml_of_string (Xtmpl.apply_from_file env tmpl)
  in
  Stog_misc.list_concat ~sep
  (List.map (fun w ->
      let href = url_of_hid stog ~ext: "html" (topic_index_hid w) in
      Xtmpl.T ("a", ["href", href ], [ f w ]))
   elt.elt_topics
  )
;;

let html_of_keywords stog elt env args _ =
  let sep = Xtmpl.xml_of_string (Xtmpl.opt_arg args ~def: ", " "set") in
  let tmpl = Filename.concat stog.stog_tmpl_dir "keyword.tmpl" in
  let f w =
    let env = Xtmpl.env_of_list ~env [ "keyword", (fun _ _ _ -> [Xtmpl.D w]) ] in
    Xtmpl.xml_of_string (Xtmpl.apply_from_file env tmpl)
  in
  Stog_misc.list_concat ~sep
  (List.map (fun w ->
      let href = url_of_hid stog ~ext: "html" (keyword_index_hid w) in
      Xtmpl.T ("a", ["href", href], [ f w ]))
   elt.elt_keywords
  )
;;

let remove_re s =
  let re = Str.regexp "^Re:[ ]?" in
  let rec iter s =
    let p =
      try Some (Str.search_forward re s 0)
      with Not_found -> None
    in
    match p with
      None -> s
    | Some p ->
        assert (p=0);
        let matched_len = String.length (Str.matched_string s) in
        let s = String.sub s matched_len (String.length s - matched_len) in
        iter s
  in
  iter s
;;

let rec elt_commands stog =
  let f_title elt _ _ _ = [ Xtmpl.D elt.elt_title ] in
  let f_url elt _ _ _ = [ Xtmpl.D (elt_url stog elt) ] in
  let f_body elt _ _ _ = elt.elt_body in
  let f_type elt _ _ _ = [Xtmpl.D elt.elt_type] in
  let f_src elt _ _ _ = [Xtmpl.D elt.elt_src] in
  let f_date elt _ _ _ = [ Xtmpl.D (Stog_intl.string_of_date_opt stog.stog_lang elt.elt_date) ] in
  let f_intro elt _ _ _ = intro_of_elt stog elt in
  let mk f env atts subs =
    let node = Printf.sprintf "<elt-hid/>" in
    let s = Xtmpl.apply env node in
    if s = node then
      []
    else
      (
       let (_, elt) = Stog_types.elt_by_human_id stog (Stog_types.human_id_of_string s) in
       f elt env atts subs
      )
  in
  [
    Stog_cst.elt_title, mk f_title ;
    "elt-url", mk f_url ;
    "elt-body", mk f_body ;
    "elt-type", mk f_type ;
    "elt-src", mk f_src ;
    tag_sep, (fun _ _ _ -> []);
    Stog_cst.elt_date, mk f_date ;
    "elt-keywords", mk (html_of_keywords stog) ;
    "elt-topics", mk (html_of_topics stog) ;
    "elt-intro", mk f_intro ;
    "elements", elt_list stog ;
  ]

and elt_list ?rss ?set stog env args _ =
  let elts =
    match set with
      Some set ->
        let l = Stog_types.Elt_set.elements set in
        List.map (fun id -> (id, Stog_types.elt stog id)) l
    | None ->
        let set = Xtmpl.get_arg args "set" in
        Stog_types.elt_list ?set stog
  in
  let elts =
    match Xtmpl.get_arg args "type" with
      None -> elts
    | Some typ ->
        List.filter (fun (_,elt) -> elt.elt_type = typ) elts
  in
  let max = Stog_misc.map_opt int_of_string
    (Xtmpl.get_arg args "max")
  in
  let elts = List.rev (Stog_types.sort_ids_elts_by_date elts) in
  let elts =
    match max with
      None -> elts
    | Some n -> Stog_misc.list_chop n elts
  in
  let tmpl =
    let file =
      match Xtmpl.get_arg args "tmpl" with
        None -> "elt_list.tmpl"
      | Some s -> s
    in
    Filename.concat stog.stog_tmpl_dir file
  in
  let f_elt (elt_id, elt) =
    let env = Xtmpl.env_of_list ~env
      (("elt-hid", fun _ _ _ -> [Xtmpl.D (Stog_types.string_of_human_id elt.elt_human_id)])::
       (elt_commands stog)
       @ (default_commands stog)
      )
    in
    Xtmpl.xml_of_string (Xtmpl.apply_from_file env tmpl)
  in
  let xml = List.map f_elt elts in
  match rss with
    None -> xml
  | Some link ->
      (Xtmpl.T ("div", ["class", "rss-button"], [
          Xtmpl.T ("a", ["href", link], [
             Xtmpl.T ("img", ["src", "rss.png" ; "alt", "Rss feed"], [])]) ;
        ])
      ) :: xml
;;



let generate_elt stog env ?elt_id elt =
  Stog_msg.verbose
  (Printf.sprintf "Generating %S" (Stog_types.string_of_human_id elt.elt_human_id));
  let file = elt_dst_file stog elt in
  let tmpl = Filename.concat stog.stog_tmpl_dir elt.elt_type^".tmpl" in

  let env = Xtmpl.env_of_list ~env
    (List.map
     (fun (key, value) ->
        (key, fun _ _ _ -> [Xtmpl.xml_of_string value]))
     elt.elt_vars
    )
  in
  let previous, next =
    let html_link elt =
      let href = elt_url stog elt in
      [ Xtmpl.T ("a", ["href", href], [ Xtmpl.D elt.elt_title ]) ]
    in
    let try_link key search =
      let fallback () =
        match elt_id with
          None -> []
        | Some elt_id ->
            match search stog elt_id with
            | None -> []
            | Some id -> html_link (Stog_types.elt stog id)
      in
      if not (List.mem_assoc key elt.elt_vars) then fallback ()
      else
        let hid = Stog_types.human_id_of_string (List.assoc key elt.elt_vars) in
        try
          let (_, elt) = Stog_types.elt_by_human_id stog hid in
          html_link elt
        with Failure s ->
          Stog_msg.warning s;
          fallback ()
    in
    (try_link "previous" Stog_info.pred_by_date,
     try_link "next" Stog_info.succ_by_date)
  in
  let env = Xtmpl.env_of_list ~env
    ([
      "elt-hid", (fun  _ _ _ -> [Xtmpl.D (Stog_types.string_of_human_id elt.elt_human_id)]);
       "next", (fun _ _ _ -> next);
       "previous", (fun _ _ _ -> previous);
     ] @
     (elt_commands stog) @
        (*
          "elt-navbar", fun _ _ _ -> [Xtmpl.D "true"] ;
       *)
     (default_commands stog))
  in
  let env = env_add_langswitch env stog elt in
  Stog_misc.safe_mkdir (Filename.dirname file);
  Xtmpl.apply_to_file ~head: "<!DOCTYPE HTML>" env tmpl file
;;




let generate_by_word_indexes stog env f_elt_id elt_type map =
  let f word set stog =
    let hid = f_elt_id word in
    let elt =
      { Stog_types.elt_human_id = hid ;
        elt_type = elt_type ;
        elt_body = [] ;
        elt_date = None ;
        elt_title = word ;
        elt_keywords = [] ;
        elt_topics = [] ;
        elt_published = true ;
        elt_vars = [] ;
        elt_src = Printf.sprintf "%s.html" (Stog_types.string_of_human_id hid) ;
        elt_sets = [] ;
        elt_lang_dep = true ;
      }
    in
    let out_file = elt_dst_file stog elt in
    let rss_file = (Filename.chop_extension out_file)^".rss" in
    let url = elt_url stog elt in
    let rss_url = (Filename.chop_extension url)^".rss" in
    generate_rss_feed_file stog ~title: word url
      (List.map (Stog_types.elt stog) (Stog_types.Elt_set.elements set))
      rss_file;
    let elt =
      { elt with Stog_types.elt_body = elt_list ~set ~rss: rss_url stog env [] []}
    in
    let env = Xtmpl.env_of_list ~env
      ((elt_commands stog) @ (default_commands ~rss: rss_url stog))
    in
    let env = env_add_langswitch env stog elt in
    let stog = Stog_types.add_elt stog elt in
    generate_elt stog env elt;
    stog
  in
  Stog_types.Str_map.fold f map stog
;;

let generate_topic_indexes stog env =
  generate_by_word_indexes stog env topic_index_hid
  "by-topic" stog.stog_elts_by_topic

;;

let generate_keyword_indexes stog env =
  generate_by_word_indexes stog env keyword_index_hid
  "by-keyword" stog.stog_elts_by_kw
;;

let generate_archive_index stog env =
  let f_month year month set stog =
    let hid = month_index_hid ~year ~month in
    let title =
      let month_str = Stog_intl.get_month stog.stog_lang month in
      Printf.sprintf "%s %d" month_str year
    in
    let elt =
      { Stog_types.elt_human_id = hid ;
        elt_type = "month";
        elt_body = elt_list ~set stog env [] [] ;
        elt_date = None ;
        elt_title = title ;
        elt_keywords = [] ;
        elt_topics = [] ;
        elt_published = true ;
        elt_vars = [] ;
        elt_src = Printf.sprintf "%s.html" (Stog_types.string_of_human_id hid) ;
        elt_sets = [] ;
        elt_lang_dep = true ;
      }
    in
    let env = Xtmpl.env_of_list ~env
      ((elt_commands stog) @ (default_commands stog))
    in
    let env = env_add_langswitch env stog elt in
    let stog = Stog_types.add_elt stog elt in
    generate_elt stog env elt;
    stog
  in
  let f_year year mmap stog =
    Stog_types.Int_map.fold (f_month year) mmap stog
  in
  Stog_types.Int_map.fold f_year stog.stog_archives stog
;;

let copy_other_files stog =
  let copy_file src dst =
    let com = Printf.sprintf "cp -f %s %s" (Filename.quote src) (Filename.quote dst) in
    match Sys.command com with
      0 -> ()
    | n ->
        let msg = Printf.sprintf "Command failed [%d]: %s" n com in
        Stog_msg.error msg
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

(*
let generate_index_file stog env =
  let basefile = html_file stog "index" in
  let html_file = Filename.concat outdir basefile in
  let tmpl = Filename.concat stog.stog_tmpl_dir "index.tmpl" in
  let rss_basefile = "index.rss" in
  let rss_file = Filename.concat outdir rss_basefile in
  generate_rss_feed_file stog basefile
    (List.map snd (Stog_types.article_list stog)) rss_file;
  let env = Xtmpl.env_of_list ~env
    ([
       "contents", (fun _ _ _ -> [Xtmpl.xml_of_string stog.stog_body]);
       "articles", (article_list outdir ~rss: rss_basefile stog);
     ] @ (default_commands ~outdir ~from:`Index ~rss: rss_basefile stog))
  in
  let env = env_add_langswitch env stog html_file in
  Xtmpl.apply_to_file ~head: "<!DOCTYPE HTML>" env tmpl html_file
;;
let generate_index outdir stog env =
  Stog_misc.mkdir outdir;
 (*
  copy_file ~quote_src: false (Filename.concat stog.stog_tmpl_dir "*.less") outdir;
  copy_file ~quote_src: false (Filename.concat stog.stog_tmpl_dir "*.js") outdir;
  copy_file ~ignerr: true ~quote_src: false (Filename.concat stog.stog_tmpl_dir "*.png") outdir;
  copy_file ~ignerr: true ~quote_src: false (Filename.concat stog.stog_tmpl_dir "*.jpg") outdir;
  copy_file ~ignerr: true ~quote_src: false (Filename.concat stog.stog_dir "*.png") outdir;
  copy_file ~ignerr: true ~quote_src: false (Filename.concat stog.stog_dir "*.jpg") outdir;
 *)
;;
*)

let generate ?only_elt stog =
  begin
    match stog.stog_lang with
      None -> ()
    | Some lang -> Stog_msg.verbose (Printf.sprintf "Generating pages for language %s" lang);
  end;
  current_stog := Some stog;
  let env = List.fold_left
    (fun env (name, v) -> Xtmpl.env_add name (fun _ _ _ -> [Xtmpl.D v]) env)
    Xtmpl.env_empty
    stog.stog_vars
  in
  (*Stog_tmap.iter
    (fun elt_id elt ->
     prerr_endline (Stog_types.string_of_human_id elt.elt_human_id))
  stog.stog_elts;
  prerr_endline
  (Stog_types.Hid_map.to_string (fun x -> x) stog.stog_elts_by_human_id);
  *)
  match only_elt with
    None ->
      let elts = stog.stog_elts in
      let stog = generate_topic_indexes stog env in
      let stog = generate_keyword_indexes stog env in
      let stog = generate_archive_index stog env in
      Stog_tmap.iter (fun elt_id elt -> generate_elt stog env ~elt_id elt) elts;
      copy_other_files stog
  | Some s ->
      let hid = Stog_types.human_id_of_string s in
      let (elt_id, elt) = Stog_types.elt_by_human_id stog hid in
      generate_elt stog env ~elt_id elt
;;


