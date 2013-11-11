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

(** Rewrite engine *)

open Stog_types;;


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

(** Generate the target files, with the following steps:
  - create the output directory,
  - build the base environment from the site global attributes,
  - compute by-topic, by-keyword and by-month elements,
  - compute elements,
  - for each level, for each element, apply level functions on the element
  - output {!Stog_types.elt.elt_out} field in the destination file.
*)
val generate :
  ?use_cache: bool -> ?only_elt:string -> Stog_types.stog ->
    (module Stog_engine) list -> unit

val elt_dst : (string -> string -> string) ->
  ?encode:bool -> Stog_types.stog -> string -> Stog_types.elt -> string

(** Build the final file where the given element will be generated. *)
val elt_dst_file : Stog_types.stog -> Stog_types.elt -> string

(** Build the final url of the given element. *)
val elt_url : Stog_types.stog -> Stog_types.elt -> Neturl.url

val env_of_defs : ?env:'a Xtmpl.env -> Stog_types.def list -> 'a Xtmpl.env
val env_of_used_mods : Stog_types.stog ->
  ?env:'a Xtmpl.env -> Stog_types.Str_set.t -> 'a Xtmpl.env

type 'a stog_elt_rules =
  Stog_types.stog -> Stog_types.elt_id -> (Xtmpl.name * 'a Xtmpl.callback) list

val get_in_env : 'a -> 'a Xtmpl.env -> Xmlm.name -> 'a * string
val opt_in_env : 'a -> 'a Xtmpl.env -> Xmlm.name -> 'a * string option

val elt_env : 'a -> 'a Xtmpl.env -> Stog_types.stog -> Stog_types.elt -> 'a * 'a Xtmpl.env

val fun_apply_stog_elt_rules : Stog_types.stog stog_elt_rules -> 'a level_fun
val fun_apply_stog_data_elt_rules : (Stog_types.stog * 'a) stog_elt_rules -> 'a level_fun
val fun_apply_data_elt_rules : 'a stog_elt_rules -> 'a level_fun

val get_languages : 'a -> 'a Xtmpl.env -> 'a * string list

(** {2 Registering engines} *)

type engine_fun = Stog_types.stog -> (module Stog_engine)

val engines : unit -> (string * engine_fun) list
val register_engine : string -> engine_fun -> unit
val engine_by_name : string -> engine_fun option