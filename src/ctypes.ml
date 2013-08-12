(*
 * Copyright (c) 2013 Jeremy Yallop.
 *
 * This file is distributed under the terms of the MIT License.
 * See the file LICENSE for details.
 *)

(* TODO: better array support, perhaps based on bigarrays integration *)

exception CallToExpiredClosure = Ctypes_raw.CallToExpiredClosure

include Static

module HashPhysical = Hashtbl.Make
  (struct
    type t = Obj.t
    let hash = Hashtbl.hash
    let equal = (==)
   end)

module Identify_closure :
sig
  val record : Obj.t -> Ctypes_raw.boxedfn -> int
end =
struct
  (* A single mutex guards both tables *)
  let tables_lock = Mutex.create ()

  (* Map integer identifiers to functions. *)
  let function_by_id = Hashtbl.create 10

  (* Map functions (not closures) to identifiers. *)
  let id_by_function = HashPhysical.create 10

  (* (The caller must hold tables_lock) *)
  let store_non_closure_function fn boxed_fn id =
    try
      (* Return the existing identifier, if any. *)
      HashPhysical.find id_by_function fn
    with Not_found ->
      (* Add entries to both tables *)
      HashPhysical.add id_by_function fn id;
      Hashtbl.add function_by_id id boxed_fn;
      id

  let fresh () = Oo.id (object end)

  let finalise key =
    (* GC can be triggered while the lock is already held, in which case we
       abandon the attempt and re-install the finaliser. *)
    let rec cleanup fn =
      begin
        if Mutex.try_lock tables_lock then begin
          Hashtbl.remove function_by_id key;
          Mutex.unlock tables_lock;
        end
        else Gc.finalise cleanup fn;
      end
    in cleanup

  let record closure boxed_closure : int =
    let key = fresh () in
    try
      (* For closures we add an entry to function_by_id and a finaliser that
         removes the entry. *)
      Gc.finalise (finalise key) closure;
      begin
        Mutex.lock tables_lock;
        Hashtbl.add function_by_id key boxed_closure;
        Mutex.unlock tables_lock;
      end;
      key
    with Invalid_argument "Gc.finalise" ->
      (* For non-closures we add entries to function_by_id and
         id_by_function. *)
      begin
        Mutex.lock tables_lock;
        let id = store_non_closure_function closure boxed_closure key in
        Mutex.unlock tables_lock;
        id
      end

  let retrieve id =
    begin
      Mutex.lock tables_lock;
      let f =
        try Hashtbl.find function_by_id id
        with Not_found ->
          Mutex.unlock tables_lock;
          raise Not_found
      in begin
        Mutex.unlock tables_lock;
        f
      end
    end

  (* Register the lookup function with C. *)
  let () = Raw.set_closure_callback retrieve
end

(*
  call addr callspec
   (fun buffer ->
        write arg_1 buffer v_1
        write arg_2 buffer v_2
        ...
        write arg_n buffer v_n)
   read_return_value
*)
let rec invoke : type a. string option ->
                         a ccallspec ->
                         (Raw.raw_pointer -> unit) list ->
                         Raw.bufferspec ->
                         Raw.raw_pointer ->
                      a
  = fun name -> function
    | Call (check_errno, read_return_value) ->
      let call = match check_errno, name with
        | true, Some name -> Raw.call_errno name
        | true, None      -> Raw.call_errno ""
        | false, _        -> Raw.call
      in
      fun writers callspec addr ->
        call addr callspec
          (fun buf -> List.iter (fun w -> w buf) writers)
          read_return_value
    | WriteArg (write, ccallspec) ->
      let next = invoke name ccallspec in
      fun writers callspec addr v ->
        next (write v :: writers) callspec addr

let rec prep_callspec : type a. Raw.bufferspec -> a typ -> unit
  = fun callspec ty ->
    let ArgType ctype = arg_type ty in
    Raw.prep_callspec callspec ctype

and add_argument : type a. Raw.bufferspec -> a typ -> int
  = fun callspec -> function
    | Void -> 0
    | ty   -> let ArgType ctype = arg_type ty in
              Raw.add_argument callspec ctype

and box_function : type a. a fn -> Raw.bufferspec -> a WeakRef.t -> Raw.boxedfn
  = fun fn callspec -> match fn with
    | Returns (_, ty) ->
      let _ = prep_callspec callspec ty in
      let write_rv = write ty in
      fun f -> Raw.Done (write_rv ~offset:0 (WeakRef.get f), callspec)
    | Function (p, f) ->
      let _ = add_argument callspec p in
      let box = box_function f callspec in
      let read = build p ~offset:0 in
      fun f -> Raw.Fn (fun buf ->
        try box (WeakRef.make (WeakRef.get f (read buf)))
        with WeakRef.EmptyWeakReference -> raise CallToExpiredClosure)

(* Describes how to read a value, e.g. from a return buffer *)
and build : type a. a typ -> offset:int -> Raw.raw_pointer -> a
 = function
    | Void ->
      (Raw.read RawTypes.void : offset:int -> Raw.raw_pointer -> a)
    | Primitive p ->
      Raw.read p
    | Struct { spec = Incomplete _ } ->
      raise IncompleteType
    | Struct { spec = Complete p } as reftype ->
      (fun ~offset buf ->
        let m = Raw.read p ~offset buf in
        { structured =
            { pmanaged = Some m;
              reftype;
              raw_ptr = Raw.block_address m;
              pbyte_offset = 0 } })
    | Pointer reftype ->
      (fun ~offset buf ->
        { raw_ptr = Raw.read RawTypes.pointer ~offset buf;
          pbyte_offset = 0;
          reftype;
          pmanaged = None })
    | FunctionPointer (name, f) ->
      let build_fun = build_function ?name f in
      (fun ~offset buf -> build_fun (Raw.read RawTypes.pointer ~offset buf))
    | View { read; ty } ->
      let buildty = build ty in
      (fun ~offset buf -> read (buildty ~offset buf))
    (* The following cases should never happen; non-struct aggregate
       types are excluded during type construction. *)
    | Union _ -> assert false
    | Array _ -> assert false
    | Abstract _ -> assert false

and write : type a. a typ -> offset:int -> a -> Raw.raw_pointer -> unit
  = let write_aggregate size =
      (fun ~offset { structured = { raw_ptr; pbyte_offset = src_offset } } dst ->
        Raw.memcpy ~size ~dst ~dst_offset:offset ~src:raw_ptr ~src_offset) in
    function
    | Void -> (fun ~offset _ _ -> ())
    | Primitive p -> Raw.write p
    | Pointer _ ->
      (fun ~offset { raw_ptr; pbyte_offset } ->
        Raw.write RawTypes.pointer ~offset
          (RawTypes.PtrType.(add raw_ptr (of_int pbyte_offset))))
    | FunctionPointer (_, fn) ->
      let cs' = Raw.allocate_callspec () in
      let cs = box_function fn cs' in
      (fun ~offset f ->
       let boxed = cs (WeakRef.make f) in
       let id = Identify_closure.record (Obj.repr f) boxed in
       Raw.write RawTypes.pointer ~offset
         (Raw.make_function_pointer cs' id))
    | Struct { spec = Incomplete _ } -> raise IncompleteType
    | Struct { spec = Complete _ } as s -> write_aggregate (sizeof s)
    | Union { ucomplete=false } -> raise IncompleteType
    | Union { usize } -> write_aggregate usize
    | Abstract { asize } -> write_aggregate asize
    | Array _ as a ->
      let size = sizeof a in
      (fun ~offset { astart = { raw_ptr; pbyte_offset = src_offset } } dst ->
        Raw.memcpy ~size ~dst ~dst_offset:offset ~src:raw_ptr ~src_offset)
    | View { write = w; ty } ->
      let writety = write ty in
      (fun ~offset v -> writety ~offset (w v))

(*
  callspec = allocate_callspec ()
  add_argument callspec arg1
  add_argument callspec arg2
  ...
  add_argument callspec argn
  prep_callspec callspec rettype
*)
and build_ccallspec : type a. a fn -> Raw.bufferspec -> a ccallspec
  = fun fn callspec -> match fn with
    | Returns (check_errno, t) ->
      let () = prep_callspec callspec t in
      (Call (check_errno, build t ~offset:0) : a ccallspec)
    | Function (p, f) ->
      let offset = add_argument callspec p in
      let rest = build_ccallspec f callspec in
      WriteArg (write p ~offset, rest)

and build_function : type a. ?name:string -> a fn -> RawTypes.voidp -> a
  = fun ?name fn ->
    let c = Raw.allocate_callspec () in
    let e = build_ccallspec fn c in
    invoke name e [] c

let null : unit ptr = { raw_ptr = RawTypes.null;
                        reftype = Void;
                        pbyte_offset = 0;
                        pmanaged = None }

let rec (!@) : type a. a ptr -> a
  = fun ({ raw_ptr; reftype; pbyte_offset = offset } as ptr) ->
    match reftype with
      | Void -> raise IncompleteType
      | Union { ucomplete = false } -> raise IncompleteType
      | Struct { spec = Incomplete _ } -> raise IncompleteType
      | View { read; ty = reftype } -> read (!@ { ptr with reftype })
      (* If it's a reference type then we take a reference *)
      | Union _ -> ({ structured = ptr } : a)
      | Struct _ -> { structured = ptr }
      | Array (elemtype, alength) ->
        { astart = { ptr with reftype = elemtype }; alength }
      | Abstract _ -> { structured = ptr }
      (* If it's a value type then we cons a new value. *)
      | _ -> build reftype ~offset raw_ptr

let ptr_diff { raw_ptr = lp; pbyte_offset = loff; reftype }
    { raw_ptr = rp; pbyte_offset = roff } =
    (* We assume the pointers are properly aligned, or at least that
       the difference is a multiple of sizeof reftype. *)
    let open RawTypes.PtrType in
     let l = add lp (of_int loff)
     and r = add rp (of_int roff) in
     to_int (sub r l) / sizeof reftype

let (+@) : type a. a ptr -> int -> a ptr
  = fun ({ pbyte_offset; reftype } as p) x ->
    { p with pbyte_offset = pbyte_offset + (x * sizeof reftype) }

let (-@) : type a. a ptr -> int -> a ptr
  = fun p x -> p +@ (-x)

let (<-@) : type a. a ptr -> a -> unit
  = fun { reftype; raw_ptr; pbyte_offset = offset } ->
    fun v -> write reftype ~offset v raw_ptr

let from_voidp : type a. a typ -> unit ptr -> a ptr
  = fun reftype p -> { p with reftype }

let to_voidp : type a. a ptr -> unit ptr
  = fun p -> { p with reftype = Void }

let allocate_n : type a. ?finalise:(a ptr -> unit) -> a typ -> count:int -> a ptr
  = fun ?finalise reftype ~count ->
    let package p =
      { reftype; pbyte_offset = 0; raw_ptr = Raw.block_address p;
        pmanaged = Some p } in
    let finalise = match finalise with
      | Some f -> Gc.finalise (fun p -> f (package p))
      | None -> ignore
    in
    let p = Raw.allocate (count * sizeof reftype) in begin
      finalise p;
      package p
    end

let allocate : type a. ?finalise:(a ptr -> unit) -> a typ -> a -> a ptr
  = fun ?finalise reftype v ->
    let p = allocate_n ?finalise ~count:1 reftype in begin
      p <-@ v;
      p
    end

let ptr_compare {raw_ptr = lp; pbyte_offset = loff} {raw_ptr = rp; pbyte_offset = roff}
    = RawTypes.PtrType.(compare (add lp (of_int loff)) (add rp (of_int roff)))

let reference_type { reftype } = reftype

let ptr_of_raw_address addr =
  { reftype = Void; raw_ptr = RawTypes.PtrType.of_int64 addr;
    pmanaged = None; pbyte_offset = 0 }

module Array =
struct
  type 'a t = 'a array

  let check_bound { alength } i =
    if i >= alength then
      invalid_arg "index out of bounds"

  let unsafe_get { astart } n = !@(astart +@ n)
  let unsafe_set { astart } n v = (astart +@ n) <-@ v

  let get arr n =
    check_bound arr n;
    unsafe_get arr n

  let set arr n v =
    check_bound arr n;
    unsafe_set arr n v

  let start { astart } = astart
  let length { alength } = alength
  let from_ptr astart alength = { astart; alength }

  let fill ({ alength } as arr) v =
    for i = 0 to alength - 1 do unsafe_set arr i v done

  let make : type a. ?finalise:(a t -> unit) -> a typ -> ?initial:a -> int -> a t
    = fun ?finalise reftype ?initial count ->
      let finalise = match finalise with
        | Some f -> Some (fun astart -> f { astart; alength = count } )
        | None -> None
      in
      let arr = { astart = allocate_n ?finalise ~count reftype;
                  alength = count } in
      match initial with
        | None -> arr
        | Some v -> fill arr v; arr

  let element_type { astart } = reference_type astart 

  let of_list typ list =
    let arr = make typ (List.length list) in
    List.iteri (set arr) list;
    arr

  let to_list a =
    let l = ref [] in
    for i = length a - 1 downto 0 do
      l := get a i :: !l
    done;
    !l
end

let make ?finalise s =
  let finalise = match finalise with
    | Some f -> Some (fun structured -> f { structured })
    | None -> None in
  { structured = allocate_n ?finalise s ~count:1 }
let (|->) p { ftype = reftype; foffset } =
  { p with reftype; pbyte_offset = p.pbyte_offset + foffset }
let (@.) { structured = p } f = p |-> f
let setf s field v = (s @. field) <-@ v
let getf s field = !@(s @. field)

let addr { structured } = structured

include Formatters

let rec format : type a. a typ -> Format.formatter -> a -> unit
  = fun typ fmt v -> match typ with
    Void -> Format.pp_print_string fmt (Raw.string_of RawTypes.void v)
  | Primitive p -> Format.pp_print_string fmt (Raw.string_of p v)
  | Pointer _ -> format_ptr fmt v
  | Struct _ -> format_struct fmt v
  | Union _ -> format_union fmt v
  | Array (a, n) -> format_array fmt v
  | Abstract abs -> Format.pp_print_string fmt "<abstract>"
    (* For now, just print the underlying value in a view *)
  | View {write; ty} -> format ty fmt (write v)
  | FunctionPointer (name, fn) -> Format.pp_print_string fmt "<fun>"
and format_struct : type a. Format.formatter -> a structure -> unit
  = fun fmt ({structured = {reftype = Struct {fields}}} as s) ->
    let open Format in
    fprintf fmt "{@;<1 2>@[";
    format_fields "," fields fmt s;
    fprintf fmt "@]@;<1 0>}"
and format_union : type a. Format.formatter -> a union -> unit
  = fun fmt ({structured = {reftype = Union {ufields}}} as u) ->
    let open Format in
    fprintf fmt "{@;<1 2>@[";
    format_fields " |" ufields fmt u;
    fprintf fmt "@]@;<1 0>}"
and format_array : type a. Format.formatter -> a array -> unit
  = fun fmt ({astart = {reftype}; alength} as arr) ->
    let open Format in
    fprintf fmt "{@;<1 2>@[";
    for i = 0 to alength - 1 do
      format reftype fmt (Array.get arr i);
      if i <> alength - 1 then
        fprintf fmt ",@;"
    done;
    fprintf fmt "@]@;<1 0>}"
and format_fields : type a b. string -> (a, b) structured boxed_field list ->
                              Format.formatter -> (a, b) structured -> unit
  = fun sep fields fmt s ->
    let last_field = List.length fields - 1 in
    let open Format in
    List.iteri
      (fun i (BoxedField ({ftype; foffset} as f)) ->
        fprintf fmt "@[%a@]%s@;" (format ftype) (getf s f) 
          (if i <> last_field then sep else ""))
      (List.rev fields)
and format_ptr : type a. Format.formatter -> a ptr -> unit
  = fun fmt {raw_ptr; reftype; pbyte_offset} ->
    Format.fprintf fmt "%s"
      (Raw.string_of
         RawTypes.pointer
         (RawTypes.PtrType.(add raw_ptr (of_int pbyte_offset))))

let string_of typ v = string_of (format typ) v

let strlen p =
  let i = ref 0 in
  while !@(p +@ !i) <> '\000' do incr i done;
  !i

let string_of_char_ptr {raw_ptr; pbyte_offset} =
  Raw.string_of_cstring raw_ptr pbyte_offset

let char_ptr_of_string s =
  let buf = Raw.cstring_of_string s in
  { reftype = char;
    pmanaged = Some buf;
    raw_ptr = Raw.block_address buf;
    pbyte_offset = 0 }

let string = view ~read:string_of_char_ptr ~write:char_ptr_of_string
  (ptr char)

let castp typ p = from_voidp typ (to_voidp p)

let read_nullable t p =
  if p = null then None
  else Some !@(castp t (allocate (ptr void) p))

let write_nullable t = function
  | None -> null
  | Some f -> !@(castp (ptr void) (allocate t f))

let nullable_view t =
  let read = read_nullable t
  and write = write_nullable t in
  view ~read ~write (ptr void)

let funptr_opt fn = nullable_view (funptr fn)

let ptr_opt t = nullable_view (ptr t)

let string_opt = nullable_view string
