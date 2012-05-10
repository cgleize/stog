(*********************************************************************************)
(*                Stog                                                           *)
(*                                                                               *)
(*    Copyright (C) 2012 Maxence Guesdon. All rights reserved.                   *)
(*                                                                               *)
(*    This program is free software; you can redistribute it and/or modify       *)
(*    it under the terms of the GNU General Public License as                    *)
(*    published by the Free Software Foundation; either version 2 of the         *)
(*    License.                                                                   *)
(*                                                                               *)
(*    This program is distributed in the hope that it will be useful,            *)
(*    but WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *)
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

let (load_files : (string list -> unit) ref) =
  ref (fun _ -> prerr_endline "Stog_dyn.load_files not initialized"; exit 1);;

let files_of_packages kind pkg_names =
  let file = Filename.temp_file "stog" "txt" in
  let com =
    Printf.sprintf "ocamlfind query %s -predicates stog,%s -format %%d/%%a > %s"
      (String.concat " " (List.map Filename.quote pkg_names))
      (match kind with `Byte -> "byte" | `Native -> "native")
      (Filename.quote file)
  in
  match Sys.command com with
    0 ->
      let s = Stog_misc.string_of_file file in
      Sys.remove file;
      Stog_misc.split_string s ['\n']
  | n ->
      let msg = Printf.sprintf "Command failed (%d): %s" n com in
      failwith msg
;;

let (load_packages : (string list -> unit) ref) =
  ref (fun _ -> prerr_endline "Stog_dyn.load_packages not initialized"; exit 1);;

let load_packages_comma kind load_file pkg_names =
  let pkg_names = Stog_misc.split_string pkg_names [','] in
  let files = files_of_packages kind pkg_names in
  List.iter load_file files
;;

let set_load_packages kind load_file =
  let f packages =
    List.iter (load_packages_comma kind load_file) packages
  in
  load_packages := f
;;


