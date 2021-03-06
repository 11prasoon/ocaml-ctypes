(*
 * Copyright (c) 2014 Jeremy Yallop.
 *
 * This file is distributed under the terms of the MIT License.
 * See the file LICENSE for details.
 *)

(* Foreign function bindings for the macro tests. *)

open Ctypes

module Stubs (F: Cstubs.FOREIGN) =
struct
  open F

  let exp_double = foreign "exp_double" (double @-> returning double)

  let exp_float = foreign "exp_float" (float @-> returning float)
end
